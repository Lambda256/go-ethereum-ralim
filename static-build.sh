#!/usr/bin/env bash
#
# Build statically linked binaries through the repository's CI helper.
#
#   ./static-build.sh                            # host target, ./cmd/geth
#   ./static-build.sh ./cmd/geth ./cmd/evm       # pick the packages
#   ./static-build.sh --os linux --arch arm64 --cc aarch64-linux-gnu-gcc
#   ./static-build.sh --dlgo                     # build with a pinned Go toolchain
#
# The wrapped command is:
#
#   go run build/ci.go install -static <packages>
#
# Binaries land in build/bin/. Static linking is only wired up for linux
# targets in build/ci.go (buildFlags adds -extldflags -static plus the osusergo
# and netgo tags there and nowhere else), so on any other target -static is
# accepted and silently ignored. The script says so up front and inspects the
# binaries afterwards instead of trusting the flag.

set -euo pipefail

CI=build/ci.go
OUTDIR=build/bin

usage() {
	sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'
	exit "${1:-0}"
}

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }

TARGET_OS=""
TARGET_ARCH=""
TARGET_CC=""
DO_DLGO=0
DO_VERIFY=1
PACKAGES=()

while [ $# -gt 0 ]; do
	case "$1" in
		-h|--help)   usage 0 ;;
		--os)        TARGET_OS="${2:-}"; [ -n "$TARGET_OS" ] || die "--os needs a GOOS value"; shift 2 ;;
		--arch)      TARGET_ARCH="${2:-}"; [ -n "$TARGET_ARCH" ] || die "--arch needs a GOARCH value"; shift 2 ;;
		--cc)        TARGET_CC="${2:-}"; [ -n "$TARGET_CC" ] || die "--cc needs a compiler"; shift 2 ;;
		--dlgo)      DO_DLGO=1; shift ;;
		--no-verify) DO_VERIFY=0; shift ;;
		-*)          die "unknown option: $1" ;;
		*)           PACKAGES+=("$1"); shift ;;
	esac
done

[ "${#PACKAGES[@]}" -gt 0 ] || PACKAGES=(./cmd/geth)

# ---------------------------------------------------------------- preconditions

cd "$(git rev-parse --show-toplevel)" 2>/dev/null || die "not inside a git repository"

command -v go >/dev/null 2>&1 || die "no go toolchain on PATH"
[ -f "$CI" ] || die "$CI not found - is this a go-ethereum checkout?"

# build/ci.go defaults its target to the OS it is itself running on, so an
# unset --os means the host.
HOST_OS="$(go env GOHOSTOS)"
[ -n "$TARGET_OS" ] || TARGET_OS="$HOST_OS"

if [ "$TARGET_OS" != "linux" ]; then
	warn "-static only affects linux targets; a $TARGET_OS build will be dynamically linked."
	cat >&2 <<-MSG
	    Apple's and Windows' toolchains ship no static libc to link against, so
	    this is a limitation of the platform rather than of build/ci.go. For a
	    genuinely static binary, target linux:

	        ./static-build.sh --os linux --arch amd64 --cc <linux-cross-gcc>

	    or run this script inside a linux container:

	        docker run --rm -v "\$PWD":/src -w /src golang:1.26 ./static-build.sh

	MSG
fi

# ------------------------------------------------------------------------ build

step "Building ${PACKAGES[*]} (-static, target $TARGET_OS${TARGET_ARCH:+/$TARGET_ARCH})"

ARGS=(run "$CI" install -static)
[ "$DO_DLGO" -eq 0 ] || ARGS+=(-dlgo)
[ -z "$TARGET_ARCH" ] || ARGS+=(-arch "$TARGET_ARCH")
[ -z "$TARGET_CC" ] || ARGS+=(-cc "$TARGET_CC")
# Pass -os only for a cross build, so the default path stays byte for byte the
# command documented at the top of this file.
if [ "$TARGET_OS" != "$HOST_OS" ]; then
	ARGS+=(-os "$TARGET_OS")
fi
ARGS+=("${PACKAGES[@]}")

info "go ${ARGS[*]}"
go "${ARGS[@]}" || die "build failed"

# ----------------------------------------------------------------------- verify

# linkage prints how a built binary resolves libc: "static", "dynamic" or
# "unknown" when none of the available tools can tell.
linkage() {
	local bin="$1" desc magic

	desc="$(file -b "$bin" 2>/dev/null || true)"
	case "$desc" in
		*"statically linked"*|*"static-pie linked"*) echo static; return ;;
		*"dynamically linked"*)                      echo dynamic; return ;;
	esac

	# Either file(1) is absent - slim container images ship without it - or it
	# had nothing to say, as for Mach-O images. Fall back to the platform tools,
	# choosing them by the binary's own magic number rather than by host OS, so
	# that cross-built output is classified correctly too.
	magic="$(od -An -tx1 -N4 "$bin" 2>/dev/null | tr -d ' \n')"
	case "$magic" in
		7f454c46) # ELF: a dynamic executable names its interpreter in PT_INTERP
			if command -v readelf >/dev/null 2>&1; then
				if readelf -lW "$bin" 2>/dev/null | grep -q INTERP; then
					echo dynamic
				else
					echo static
				fi
				return
			fi
			if command -v ldd >/dev/null 2>&1; then
				if ldd "$bin" 2>&1 | grep -q 'not a dynamic executable'; then
					echo static
				else
					echo dynamic
				fi
				return
			fi
			;;
		cffaedfe|cefaedfe|feedface|feedfacf|cafebabe) # Mach-O, thin or universal
			if command -v otool >/dev/null 2>&1; then
				if otool -L "$bin" 2>/dev/null | tail -n +2 | grep -q .; then
					echo dynamic
				else
					echo static
				fi
				return
			fi
			;;
	esac
	echo unknown
}

if [ "$DO_VERIFY" -eq 1 ]; then
	step "Verifying"

	failed=0
	for pkg in "${PACKAGES[@]}"; do
		name="$(basename "$pkg")"
		[ "$TARGET_OS" != "windows" ] || name="$name.exe"
		bin="$OUTDIR/$name"

		[ -f "$bin" ] || { warn "$bin was not produced"; failed=1; continue; }

		case "$(linkage "$bin")" in
			static)
				info "$(printf '%-12s' "$name") statically linked  ($(du -h "$bin" | cut -f1))"
				;;
			dynamic)
				if [ "$TARGET_OS" = "linux" ]; then
					warn "$bin is dynamically linked even though -static was requested"
					failed=1
				else
					info "$(printf '%-12s' "$name") dynamically linked ($(du -h "$bin" | cut -f1)) - expected on $TARGET_OS"
				fi
				;;
			*)
				info "$(printf '%-12s' "$name") linkage undetermined ($(du -h "$bin" | cut -f1))"
				;;
		esac
	done

	[ "$failed" -eq 0 ] || die "verification failed"
fi

step "Result"
for pkg in "${PACKAGES[@]}"; do
	name="$(basename "$pkg")"
	[ "$TARGET_OS" != "windows" ] || name="$name.exe"
	[ ! -f "$OUTDIR/$name" ] || info "$OUTDIR/$name"
done
