#!/bin/sh
# platform: host-agnostic
# spec: 2026-11-19-macfuse-product/task-11-brief.md -- builds the 10.9 acceptance job's own test file systems with the
#       family toolchain (build/lib.sh macfuse_toolchain: clang22, the 10.9 SDK, the pinned Recaulk), as a third-party
#       developer would build them; in the job it runs in the guest, where clang22 is fetched for 10.9.
#   usage: build-tests.sh probe-fs OUT TREE_ROOT
#          OUT/probe-fs: tests/vm/probe-fs.c against TREE_ROOT$MACFUSE_PREFIX/{include/fuse3,lib/libfuse3.4.dylib} (a
#          build/stage.sh stage, or / where the product is installed), so it loads /usr/local/lib/libfuse3.4.dylib.
#   usage: build-tests.sh old-abi OUT UPSTREAM405_ROOT
#          OUT/old-abi: tests/vm/old-abi/hello-old.c against upstream macFUSE 4.0.5's own headers and libfuse 2,
#          UPSTREAM405_ROOT/usr/local/{include/fuse,lib/libfuse.2.dylib} (/ while 4.0.5 is installed, before the takeover),
#          so it records 4.0.5's install name and versions.
#          Fails, naming the step, on any error; replaces only its own file in OUT.
set -eu
[ $# -eq 3 ] || { echo "usage: $0 probe-fs|old-abi OUT ROOT" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/../.." && pwd)}"
export REPO_ROOT
. "$REPO_ROOT/build/lib.sh"
. "$REPO_ROOT/build/msc.sh"
WHAT=$1; OUT=$2; ROOT="${3%/}"
case "$WHAT" in
  probe-fs)
    T="$ROOT$MACFUSE_PREFIX"
    [ -f "$T/include/fuse3/fuse.h" ] && [ -f "$T/lib/libfuse3.4.dylib" ] || { echo "build-tests: no libfuse 3 headers and dylib under $T" >&2; exit 1; } ;;
  old-abi)
    [ -f "$ROOT/usr/local/include/fuse/fuse.h" ] && [ -f "$ROOT/usr/local/lib/libfuse.2.dylib" ] ||
      { echo "build-tests: no 4.0.5 headers and libfuse.2.dylib under $ROOT/usr/local" >&2; exit 1; } ;;
  *) echo "usage: $0 probe-fs|old-abi OUT ROOT" >&2; exit 2 ;;
esac
macfuse_toolchain build-tests || exit 1
W="$(mktemp -d "$BUILD/vm-tests.XXXXXX")"
trap 'rm -rf "$W"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
CC="$CL/bin/clang"
# platform: --no-default-config, because clang22's clang.cfg links its own librecaulk.a copy; the inputs are
#           exactly the 10.9 SDK, the pinned Recaulk headers and its whole librecaulk.a, last on the link
BASE="--no-default-config --target=x86_64-apple-macos10.9 -isysroot $SDK -isystem $RC/include/recaulk -O2 -g -Wall -Wno-unused-parameter -D_FILE_OFFSET_BITS=64"
NM="$CL/bin/llvm-nm" sh "$REPO_ROOT/build/recaulk-unexported.sh" "$RC/lib/librecaulk.a" > "$W/unexported"
RECAULK="$RC/lib/librecaulk.a -Wl,-unexported_symbols_list,$W/unexported"
if [ "$WHAT" = probe-fs ]; then
  # spec: build/build-libfuse.sh "examples" -- libfuse 3's plain struct stat and statvfs, as a Linux-first file system uses
  # shellcheck disable=SC2086
  "$CC" $BASE -DFUSE_DARWIN_ENABLE_EXTENSIONS=0 -I"$T/include/fuse3" "$REPO_ROOT/tests/vm/probe-fs.c" \
    -fuse-ld=lld -L"$T/lib" -lfuse3.4 $RECAULK -o "$W/$WHAT" || { echo "build-tests: probe-fs failed to build" >&2; exit 1; }
else
  # shellcheck disable=SC2086
  "$CC" $BASE -I"$ROOT/usr/local/include/fuse" "$REPO_ROOT/tests/vm/old-abi/hello-old.c" \
    -fuse-ld=lld "$ROOT/usr/local/lib/libfuse.2.dylib" -o "$W/$WHAT" || { echo "build-tests: old-abi failed to build" >&2; exit 1; }
  "$CL/bin/llvm-otool" -L "$W/$WHAT" > "$W/libs" || { echo "build-tests: llvm-otool -L old-abi failed" >&2; exit 1; }
  grep -q '/usr/local/lib/libfuse.2.dylib (compatibility version 12.0.0' "$W/libs" ||
    { echo "build-tests: old-abi does not load /usr/local/lib/libfuse.2.dylib at compatibility 12.0.0" >&2; exit 1; }
fi
mkdir -p "$OUT"
mv -f "$W/$WHAT" "$OUT/$WHAT"
echo "built $OUT/$WHAT"
