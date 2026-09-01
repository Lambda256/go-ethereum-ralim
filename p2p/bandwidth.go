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
	"math"
	"net"
	"sync"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/metrics"
	"golang.org/x/time/rate"
)

// minBandwidthBurst is the smallest token bucket capacity used for bandwidth
// limiting. The bucket has to hold at least one sizable chunk of traffic,
// otherwise every single read and write gets sliced into a long sequence of
// tiny sleeps, which costs more than it saves.
const minBandwidthBurst = 64 * 1024

var (
	// Total time all connections spent waiting for bandwidth, in nanoseconds.
	ingressThrottleMeter = metrics.NewRegisteredMeter("p2p/throttle/ingress", nil)
	egressThrottleMeter  = metrics.NewRegisteredMeter("p2p/throttle/egress", nil)
)

// bandwidthLimiter enforces an upper bound on the aggregate rate at which data
// is read from and written to all peer connections of a server.
//
// Traffic is charged after the fact: a connection is allowed to complete its
// read or write, and is only then held back until the bytes it just moved fit
// into the configured budget. Charging afterwards has two useful properties.
// Idle connections never reserve bandwidth they may end up not using, and the
// delay lands outside of the read/write deadlines the transport sets around the
// actual socket operations, so throttling does not manifest as i/o timeouts and
// dropped peers.
type bandwidthLimiter struct {
	ingress *rate.Limiter // Token bucket shaping reads, nil if unlimited
	egress  *rate.Limiter // Token bucket shaping writes, nil if unlimited
}

// newBandwidthLimiter creates a bandwidth limiter for the given ingress and
// egress rates, both in bytes per second. Non-positive rates mean no limit; if both
// directions are unlimited, nil is returned to disable throttling altogether.
func newBandwidthLimiter(ingress, egress int64) *bandwidthLimiter {
	if ingress <= 0 && egress <= 0 {
		return nil
	}
	return &bandwidthLimiter{
		ingress: newTokenBucket(ingress),
		egress:  newTokenBucket(egress),
	}
}

// newTokenBucket assembles a token bucket refilling at the given number of
// bytes per second, or nil if the rate is not limited.
func newTokenBucket(bytesPerSecond int64) *rate.Limiter {
	if bytesPerSecond <= 0 {
		return nil
	}
	// Allow a second worth of traffic to be bursted, so that short spikes are
	// served at full speed and only sustained transfers are shaped.
	burst := min(bytesPerSecond, math.MaxInt32)
	return rate.NewLimiter(rate.Limit(bytesPerSecond), max(int(burst), minBandwidthBurst))
}

// wrap returns a connection which shapes its traffic to the configured limits.
// It is safe to call on a nil limiter, in which case the connection is returned
// unchanged.
func (t *bandwidthLimiter) wrap(conn net.Conn) net.Conn {
	if t == nil {
		return conn
	}
	return &throttledConn{Conn: conn, limiter: t, closed: make(chan struct{})}
}

// throttledConn is a wrapper around a net.Conn which shapes the traffic of the
// connection to the rates of a shared bandwidth limiter.
type throttledConn struct {
	net.Conn

	limiter   *bandwidthLimiter
	closeOnce sync.Once
	closed    chan struct{} // Closed on Close to abandon pending delays
}

// Read delegates a network read to the underlying connection, afterwards holding
// back the caller until the retrieved data fits into the ingress budget.
func (c *throttledConn) Read(b []byte) (int, error) {
	n, err := c.Conn.Read(b)
	c.charge(c.limiter.ingress, n, ingressThrottleMeter)
	return n, err
}

// Write delegates a network write to the underlying connection, afterwards
// holding back the caller until the sent data fits into the egress budget.
func (c *throttledConn) Write(b []byte) (int, error) {
	n, err := c.Conn.Write(b)
	c.charge(c.limiter.egress, n, egressThrottleMeter)
	return n, err
}

// Close closes the underlying connection, also releasing any reader or writer
// currently waiting for bandwidth.
func (c *throttledConn) Close() error {
	c.closeOnce.Do(func() { close(c.closed) })
	return c.Conn.Close()
}

// charge withdraws n bytes worth of tokens from the given bucket and blocks
// until the bucket has refilled them, shaping the traffic to the configured
// rate. The delay is abandoned when the connection is closed, so that a
// throttled peer cannot hold up disconnects and shutdowns.
func (c *throttledConn) charge(bucket *rate.Limiter, n int, meter *metrics.Meter) {
	if bucket == nil || n <= 0 {
		return
	}
	// The limiter rejects reservations larger than its burst size outright, so
	// oversized transfers have to be paid off in multiple installments. The
	// reservations queue up behind one another within the limiter, thus the
	// delay of the last one already covers all the preceding ones.
	var delay time.Duration
	for burst := bucket.Burst(); n > 0; {
		chunk := min(n, burst)
		n -= chunk

		if res := bucket.ReserveN(time.Now(), chunk); res.OK() {
			delay = max(delay, res.Delay())
		}
	}
	if delay <= 0 {
		return
	}
	meter.Mark(int64(delay))

	timer := time.NewTimer(delay)
	defer timer.Stop()

	select {
	case <-timer.C:
	case <-c.closed:
	}
}

// rateString formats a bytes per second bandwidth limit for logging.
func rateString(bytesPerSecond int64) string {
	if bytesPerSecond <= 0 {
		return "unlimited"
	}
	return common.StorageSize(bytesPerSecond).String() + "/s"
}
