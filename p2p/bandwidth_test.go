// Copyright 2025 The go-ethereum Authors
// This file is part of the go-ethereum library.
//
// The go-ethereum library is free software: you can redistribute it and/or modify
// it under the terms of the GNU Lesser General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// The go-ethereum library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public License
// along with the go-ethereum library. If not, see <http://www.gnu.org/licenses/>.

package p2p

import (
	"crypto/ecdsa"
	"crypto/rand"
	"io"
	"net"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/internal/testlog"
	"github.com/ethereum/go-ethereum/log"
	"golang.org/x/time/rate"
)

// newTestThrottledConn creates a throttled connection on top of a pipe, shaping
// both directions at the given rate and burst size.
func newTestThrottledConn(bytesPerSec, burst int) (*throttledConn, net.Conn) {
	local, remote := net.Pipe()
	limits := &bandwidthLimiter{
		ingress: rate.NewLimiter(rate.Limit(bytesPerSec), burst),
		egress:  rate.NewLimiter(rate.Limit(bytesPerSec), burst),
	}
	return limits.wrap(local).(*throttledConn), remote
}

// Tests that a disabled bandwidthLimiter leaves connections untouched.
func TestThrottlerDisabled(t *testing.T) {
	if bandwidthLimiter := newBandwidthLimiter(0, -1); bandwidthLimiter != nil {
		t.Fatalf("bandwidthLimiter created for unlimited rates: %+v", bandwidthLimiter)
	}
	conn, _ := net.Pipe()
	if wrapped := (*bandwidthLimiter)(nil).wrap(conn); wrapped != conn {
		t.Fatalf("nil bandwidthLimiter wrapped the connection: %T", wrapped)
	}
}

// Tests that traffic exceeding the configured rate is delayed, and that the
// burst allowance is handed out without any delay.
func TestThrottledConnShapesTraffic(t *testing.T) {
	// Drain the burst, this should be served immediately.
	conn, _ := newTestThrottledConn(1000, 100)

	start := time.Now()
	conn.charge(conn.limiter.egress, 100, egressThrottleMeter)
	if elapsed := time.Since(start); elapsed > 100*time.Millisecond {
		t.Fatalf("burst allowance delayed by %v", elapsed)
	}
	// Charge half a second worth of traffic, split into chunks larger than the
	// burst size to also cover the installment logic.
	start = time.Now()
	conn.charge(conn.limiter.egress, 250, egressThrottleMeter)
	conn.charge(conn.limiter.egress, 250, egressThrottleMeter)

	if elapsed := time.Since(start); elapsed < 400*time.Millisecond {
		t.Fatalf("500 bytes at 1000 bytes/sec took %v, want at least 400ms", elapsed)
	} else if elapsed > 2*time.Second {
		t.Fatalf("500 bytes at 1000 bytes/sec took %v, want at most 2s", elapsed)
	}
}

// Tests that closing a connection releases a peer waiting for bandwidth instead
// of holding up the shutdown.
func TestThrottledConnCloseAbortsWait(t *testing.T) {
	conn, _ := newTestThrottledConn(1000, 100)

	done := make(chan time.Duration, 1)
	go func() {
		start := time.Now()
		conn.charge(conn.limiter.ingress, 100*1000, ingressThrottleMeter) // 100s worth of traffic
		done <- time.Since(start)
	}()
	// Give the charge a moment to enter the wait, then cut the connection.
	time.Sleep(50 * time.Millisecond)
	conn.Close()

	select {
	case elapsed := <-done:
		if elapsed > 5*time.Second {
			t.Fatalf("close released the waiter after %v", elapsed)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("close did not release the waiter")
	}
	// Closing twice must not panic on the abort channel.
	conn.Close()
}

// Tests that the wrapper transfers data correctly, delays included.
func TestThrottledConnTransfer(t *testing.T) {
	conn, remote := newTestThrottledConn(16*1024, 1024)
	defer conn.Close()

	blob := make([]byte, 4096)
	for i := range blob {
		blob[i] = byte(i)
	}
	go func() {
		remote.Write(blob)
		remote.Close()
	}()
	got, err := io.ReadAll(conn)
	if err != nil {
		t.Fatalf("failed to read from throttled conn: %v", err)
	}
	if len(got) != len(blob) {
		t.Fatalf("transferred %d bytes, want %d", len(got), len(blob))
	}
	for i := range got {
		if got[i] != blob[i] {
			t.Fatalf("payload mismatch at byte %d: have %d, want %d", i, got[i], blob[i])
		}
	}
}

// Tests that data transferred over a real socket is shaped to the configured
// rate, the initial burst allowance aside.
func TestThrottledConnRate(t *testing.T) {
	const (
		limit  = 512 * 1024 // Bandwidth limit, 512KB/s
		amount = 1024 * 1024
	)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("failed to open listener: %v", err)
	}
	defer listener.Close()

	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		io.CopyN(conn, rand.Reader, amount)
	}()
	dialed, err := net.Dial("tcp", listener.Addr().String())
	if err != nil {
		t.Fatalf("failed to dial listener: %v", err)
	}
	conn := newBandwidthLimiter(limit, 0).wrap(dialed)
	defer conn.Close()

	// The token bucket starts out full, so only the traffic beyond the burst
	// allowance is expected to be delayed.
	start := time.Now()
	if _, err := io.CopyN(io.Discard, conn, amount); err != nil {
		t.Fatalf("failed to read payload: %v", err)
	}
	elapsed := time.Since(start)

	burst := int64(newTokenBucket(limit).Burst())
	want := time.Duration(float64(amount-burst) / float64(limit) * float64(time.Second))
	if elapsed < want*3/4 {
		t.Fatalf("transfer of %d bytes at %d bytes/sec took %v, want at least %v", amount, limit, elapsed, want*3/4)
	}
	if elapsed > want*5 {
		t.Fatalf("transfer of %d bytes at %d bytes/sec took %v, want at most %v", amount, limit, elapsed, want*5)
	}
}

// Tests that a server configured with bandwidth limits shapes the connections
// it hands to the transport layer.
func TestServerAppliesBandwidthLimits(t *testing.T) {
	conns := make(chan net.Conn, 1)
	srv := &Server{
		Config: Config{
			Name:           "test",
			MaxPeers:       10,
			NoDiscovery:    true,
			NoDial:         true,
			PrivateKey:     newkey(),
			MaxIngressRate: 1024 * 1024,
			Logger:         testlog.Logger(t, log.LvlTrace),
		},
		newTransport: func(fd net.Conn, dialDest *ecdsa.PublicKey) transport {
			conns <- fd
			return newTestTransport(&newkey().PublicKey, fd, dialDest)
		},
	}
	if err := srv.Start(); err != nil {
		t.Fatalf("could not start server: %v", err)
	}
	defer srv.Stop()

	if srv.bandwidth == nil {
		t.Fatal("server started without a bandwidth bandwidthLimiter")
	}
	fd, _ := net.Pipe()
	go srv.SetupConn(fd, inboundConn, nil)

	select {
	case conn := <-conns:
		if _, ok := conn.(*throttledConn); !ok {
			t.Fatalf("transport got an unshaped connection: %T", conn)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("connection setup timed out")
	}
}
