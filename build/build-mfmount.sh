#!/bin/sh
# platform: host-agnostic
# spec: the Swift MFMount cannot be built with the family toolchain, so a C stand-in (mfmount/device.c)
#       exports the 34 names of upstream MFMount; upstream Bridge/Trampoline.c is compiled unchanged.
#   usage: build-mfmount.sh SRC STAGE
#          SRC holds the fetched upstream sources (build/fetch-sources.sh): SRC/mount/Mount/. Writes
#          STAGE/<MACFUSE_PREFIX>/fs/Contents/Frameworks/MFMount.framework at the upstream install name,
#          versions and Info.plist identity. Fails, leaving no framework, on any error.
set -eu
[ $# -eq 2 ] || { echo "usage: $0 SRC STAGE" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/.." && pwd)}"
export REPO_ROOT
. "$REPO_ROOT/build/lib.sh"
. "$REPO_ROOT/build/msc.sh"
SRC=$1
STAGE=$2
MOUNT="$SRC/mount/Mount"
[ -f "$MOUNT/Bridge/Trampoline.c" ] && [ -f "$MOUNT/MFMount.h" ] || { echo "build-mfmount: no upstream mount sources under $SRC/mount" >&2; exit 1; }
BUILD="${MAVERICKS_BUILD_ROOT:-${TMPDIR:-/tmp}/mm-build}"
INSTALL_DIR=/Library/Filesystems/macfuse.fs/Contents/Frameworks
FW="$STAGE$MACFUSE_PREFIX/fs/Contents/Frameworks/MFMount.framework"
mkdir -p "$BUILD" "$(dirname "$FW")"
W="$(mktemp -d "$BUILD/mfmount.XXXXXX")"
trap 'rm -rf "$W"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

CL="$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$REPO_ROOT/components/clang22")" || { echo "build-mfmount: no clang22" >&2; exit 1; }
SDK="$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh")" || { echo "build-mfmount: no 10.9 SDK" >&2; exit 1; }
RC_VERSION="$(tr -d ' \t\r\n' < "$REPO_ROOT/components/recaulk/version")"
sh "$SHIPYARD_SCRIPTS/fetch_product_pkg.sh" recaulk "$RC_VERSION" "$BUILD/recaulk-tree" > /dev/null || { echo "build-mfmount: no Recaulk $RC_VERSION" >&2; exit 1; }
RC="$BUILD/recaulk-tree"
[ -f "$RC/lib/librecaulk.a" ] && [ -d "$RC/include/recaulk" ] || { echo "build-mfmount: Recaulk $RC_VERSION lacks lib/librecaulk.a or include/recaulk" >&2; exit 1; }

# platform: --no-default-config, because clang22's clang.cfg links its own librecaulk.a copy; the inputs are
#           exactly the 10.9 SDK, the pinned Recaulk headers and its whole librecaulk.a, last on the link
CFLAGS="--no-default-config --target=x86_64-apple-macos10.9 -isysroot $SDK -isystem $RC/include/recaulk -O2 -g -Wall"
NM="$CL/bin/llvm-nm" sh "$REPO_ROOT/build/recaulk-unexported.sh" "$RC/lib/librecaulk.a" > "$W/unexported"
# platform: the 10.9 SDK has no __counted_by (sys/cdefs.h gained it in macOS 14)
DEFS="-D__counted_by(x)="
OUT="$W/MFMount.framework"
mkdir -p "$OUT/Versions/A/Headers" "$OUT/Versions/A/Resources" "$OUT/Versions/A/Modules"
cp "$MOUNT/MFMount.h" "$OUT/Versions/A/Headers/MFMount.h"
cat > "$OUT/Versions/A/Modules/module.modulemap" <<'EOF'
framework module MFMount {
    umbrella header "MFMount.h"
    export *
}
EOF
# shellcheck disable=SC2086
"$CL/bin/clang" $CFLAGS $DEFS -I"$MOUNT" -I"$REPO_ROOT/mfmount" -c "$REPO_ROOT/mfmount/device.c" -o "$W/device.o"
# shellcheck disable=SC2086
"$CL/bin/clang" $CFLAGS $DEFS -I"$MOUNT" -I"$REPO_ROOT/mfmount" -c "$MOUNT/Bridge/Trampoline.c" -o "$W/Trampoline.o"
# shellcheck disable=SC2086
"$CL/bin/clang" $CFLAGS -fuse-ld=lld -dynamiclib \
  -install_name "$INSTALL_DIR/MFMount.framework/Versions/A/MFMount" \
  -compatibility_version 3.0.0 -current_version 4.0.0 \
  -Wl,-headerpad_max_install_names \
  -Wl,-dead_strip_dylibs -Wl,-unexported_symbols_list,"$W/unexported" \
  "$W/device.o" "$W/Trampoline.o" "$RC/lib/librecaulk.a" \
  -o "$OUT/Versions/A/MFMount"
sed 's|@MINIMUM_SYSTEM_VERSION@|10.9|' "$REPO_ROOT/mfmount/Info.plist.in" > "$OUT/Versions/A/Resources/Info.plist"
ln -sfn A "$OUT/Versions/Current"
for n in Headers MFMount Modules Resources; do ln -sfn "Versions/Current/$n" "$OUT/$n"; done

rm -rf "$FW"
mv "$OUT" "$FW"
echo "built $FW"
