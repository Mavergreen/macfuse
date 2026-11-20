#!/bin/sh
# platform: host-agnostic
# spec: 2026-11-18-macfuse-design.md decision C -- libmfosrelease.dylib (shim/osrelease.c), the sysctlbyname shim the adapted mount_macfuse
#       loads, at its real tree path $MACFUSE_OSRELEASE_SHIM (build/lib.sh), never through a /Library/Filesystems link.
#   usage: build-shim.sh STAGE
#          Writes STAGE/$MACFUSE_OSRELEASE_SHIM, replacing only that file. Fails, leaving any earlier one, on any error.
set -eu
[ $# -eq 1 ] || { echo "usage: $0 STAGE" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/.." && pwd)}"
export REPO_ROOT
. "$REPO_ROOT/build/lib.sh"
. "$REPO_ROOT/build/msc.sh"
STAGE=$1
macfuse_toolchain build-shim || exit 1
OUT="$STAGE$MACFUSE_OSRELEASE_SHIM"
W="$(mktemp -d "$BUILD/shim.XXXXXX")"
trap 'rm -rf "$W"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# platform: --no-default-config, because clang22's clang.cfg links its own librecaulk.a copy; the inputs are
#           exactly the 10.9 SDK, the pinned Recaulk headers and its whole librecaulk.a, last on the link
CFLAGS="--no-default-config --target=x86_64-apple-macos10.9 -isysroot $SDK -isystem $RC/include/recaulk -O2 -g -Wall"
NM="$CL/bin/llvm-nm" sh "$REPO_ROOT/build/recaulk-unexported.sh" "$RC/lib/librecaulk.a" > "$W/unexported"
# shellcheck disable=SC2086
"$CL/bin/clang" $CFLAGS -c "$REPO_ROOT/shim/osrelease.c" -o "$W/osrelease.o"
# shellcheck disable=SC2086
"$CL/bin/clang" $CFLAGS -fuse-ld=lld -dynamiclib \
  -install_name "$MACFUSE_OSRELEASE_SHIM" \
  -compatibility_version 1.0.0 -current_version 1.0.0 \
  -Wl,-headerpad_max_install_names \
  -Wl,-dead_strip_dylibs -Wl,-unexported_symbols_list,"$W/unexported" \
  "$W/osrelease.o" "$RC/lib/librecaulk.a" \
  -o "$W/libmfosrelease.dylib"

mkdir -p "$(dirname "$OUT")"
mv -f "$W/libmfosrelease.dylib" "$OUT"
echo "built $OUT"
