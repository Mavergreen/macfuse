#!/bin/sh
# platform: host-agnostic
# spec: DETAILS.md "A mount made for you: /dev/fd/N" -- libfuse 3, built from the pinned sources with this repo's patches,
#       serves a socketpair standing in for /dev/macfuseN, given as the mountpoint /dev/fd/N, without forking to run
#       mount_macfuse (tests/libfuse/fd-mountpoint.c). It runs only on a host that executes x86_64 (the 10.9 acceptance job,
#       .github/workflows/on-mavericks.yml); this Mac, Apple silicon or not Darwin, SKIPs.
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
for f in mount/Mount/Bridge/Trampoline.c library2/lib/fuse.c library3/lib/fuse_lowlevel.c; do
  [ -f "$SRC/$f" ] || { echo "FAIL: no fetched sources at $SRC ($f; build/fetch-sources.sh)" >&2; exit 1; }
done

T="$(mktemp -d "${TMPDIR:-/tmp}/libfuse-fd-mountpoint-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

{ sh "$REPO_ROOT/build/build-mfmount.sh" "$SRC" "$T/stage" && sh "$REPO_ROOT/build/build-libfuse.sh" "$SRC" "$T/stage" "$T/ex"; } \
  > "$T/build.log" 2>&1 || { cat "$T/build.log" >&2; echo "FAIL: building MFMount and libfuse failed" >&2; exit 1; }
FWDIR="$T/stage$MACFUSE_PREFIX/fs/Contents/Frameworks"
LIBDIR="$T/stage$MACFUSE_PREFIX/lib"
CL="$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$REPO_ROOT/components/clang22")"
SDK="$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh")"
# spec: build/build-libfuse.sh "examples" -- the public headers as staged, plus the source tree's fuse_kernel.h for the
#       wire structs the test writes as the kernel
"$CL/bin/clang" --no-default-config --target=x86_64-apple-macos10.9 -isysroot "$SDK" -O2 -g -Wall -Wno-unused-parameter \
  -D_FILE_OFFSET_BITS=64 -DFUSE_DARWIN_ENABLE_EXTENSIONS=0 -I"$T/stage$MACFUSE_PREFIX/include/fuse3" -I"$SRC/library3/include" \
  -fuse-ld=lld "$REPO_ROOT/tests/libfuse/fd-mountpoint.c" -L"$LIBDIR" -lfuse3.4 -o "$T/fd-mountpoint"
# spec: tests/libfuse/interpose-wait.c -- counts and bends the single-threaded loop's waits on the adopted device
"$CL/bin/clang" --no-default-config --target=x86_64-apple-macos10.9 -isysroot "$SDK" -O2 -g -Wall -dynamiclib \
  -fuse-ld=lld "$REPO_ROOT/tests/libfuse/interpose-wait.c" -F"$FWDIR" -framework MFMount -o "$T/interpose-wait.dylib"
DYLD_INSERT_LIBRARIES="$T/interpose-wait.dylib" DYLD_LIBRARY_PATH="$LIBDIR" DYLD_FRAMEWORK_PATH="$FWDIR" "$T/fd-mountpoint" "$LIBDIR/libfuse3.4.dylib" > "$T/out.txt" 2>&1 ||
  { cat "$T/out.txt" >&2; echo "FAIL: fd-mountpoint" >&2; exit 1; }
cat "$T/out.txt"
grep -q '^PASS$' "$T/out.txt" || { echo "FAIL: no PASS line" >&2; exit 1; }
echo "libfuse-fd-mountpoint-test: PASS"
