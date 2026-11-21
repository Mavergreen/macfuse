#!/bin/sh
# platform: host-agnostic
# spec: DETAILS.md "MFMount is a C stand-in" -- the device-channel cases (socketpair standing in for /dev/macfuseN) run only
#       on a host that executes x86_64 (the 10.9 acceptance job, .github/workflows/on-mavericks.yml); this Mac, Apple silicon
#       or not Darwin, SKIPs.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/.." && pwd)}"
export REPO_ROOT
. "$REPO_ROOT/build/lib.sh"
. "$REPO_ROOT/build/msc.sh"
BUILD="${MAVERICKS_BUILD_ROOT:-${TMPDIR:-/tmp}/mm-build}"
SRC="${MFMOUNT_SRC:-$BUILD/src}"
if [ "$(uname -s)" != Darwin ] || [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ]; then
  echo "SKIP: this host cannot execute x86_64 (not Darwin, or Apple silicon)"; exit 77
fi
[ -f "$SRC/mount/Mount/Bridge/Trampoline.c" ] || { echo "FAIL: no fetched mount sources at $SRC/mount (build/fetch-sources.sh)" >&2; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/mfmount-device-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

sh "$REPO_ROOT/build/build-mfmount.sh" "$SRC" "$T/stage" > "$T/build.log" 2>&1 || { cat "$T/build.log" >&2; echo "FAIL: build-mfmount.sh failed" >&2; exit 1; }
FWDIR="$T/stage$MACFUSE_PREFIX/fs/Contents/Frameworks"
CL="$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$REPO_ROOT/components/clang22")"
SDK="$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh")"
"$CL/bin/clang" --no-default-config --target=x86_64-apple-macos10.9 -isysroot "$SDK" -O2 -g -Wall "-D__counted_by(x)=" \
  -F "$FWDIR" -fuse-ld=lld "$REPO_ROOT/tests/mfmount/test-device.c" -framework MFMount -o "$T/test-device"
DYLD_FRAMEWORK_PATH="$FWDIR" "$T/test-device" > "$T/out.txt" 2>&1 || { cat "$T/out.txt" >&2; echo "FAIL: test-device" >&2; exit 1; }
grep -q '^PASS$' "$T/out.txt" || { cat "$T/out.txt" >&2; echo "FAIL: no PASS line" >&2; exit 1; }
echo "mfmount-device-test: PASS"
