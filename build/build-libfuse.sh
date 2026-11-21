#!/bin/sh
# platform: host-agnostic
# spec: tests/libfuse-exports-test.sh -- neither autotools nor meson exists on a native 10.9 build, so each tree's
#       library sources are compiled directly: the source lists of library2/lib/Makefile.am (DARWIN, ICONV) and
#       library3/lib/meson.build (darwin, HAVE_ICONV), with the hand-written config headers of libfuse/config/.
#   usage: build-libfuse.sh SRC STAGE EXAMPLES
#          SRC holds the fetched upstream sources (build/fetch-sources.sh): SRC/library2, SRC/library3.
#          STAGE must already hold MFMount (build/build-mfmount.sh). Writes STAGE/<MACFUSE_PREFIX>/lib/
#          {libfuse.2.dylib,libfuse.dylib,libfuse.la,libfuse3.4.dylib,libfuse3.dylib,pkgconfig/{fuse,fuse3}.pc} and
#          STAGE/<MACFUSE_PREFIX>/include/{fuse.h,fuse/,fuse3/}, with upstream's install names (/usr/local/lib/...)
#          and versions, and the examples hello2, hello3 and passthrough3 into EXAMPLES. Fails on any error.
set -eu
[ $# -eq 3 ] || { echo "usage: $0 SRC STAGE EXAMPLES" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/.." && pwd)}"
export REPO_ROOT
. "$REPO_ROOT/build/lib.sh"
. "$REPO_ROOT/build/msc.sh"
SRC=$1
STAGE=$2
EX=$3
L2="$SRC/library2"
L3="$SRC/library3"
CFG="$REPO_ROOT/libfuse/config"
[ -f "$L2/lib/fuse.c" ] && [ -f "$L2/configure.ac" ] || { echo "build-libfuse: no upstream Library-2 sources under $L2" >&2; exit 1; }
[ -f "$L3/lib/fuse.c" ] && [ -f "$L3/meson.build" ] || { echo "build-libfuse: no upstream Library-3 sources under $L3" >&2; exit 1; }
FWDIR="$STAGE$MACFUSE_PREFIX/fs/Contents/Frameworks"
[ -f "$FWDIR/MFMount.framework/Versions/A/MFMount" ] || { echo "build-libfuse: no MFMount in $FWDIR (build/build-mfmount.sh first)" >&2; exit 1; }

# spec: libfuse/config/lib2/config.h and lib3/ carry the upstream versions by hand; a source bump must revisit them
v2="$(sed -n 's/^AC_INIT(fuse, *\([0-9.]*\)).*/\1/p' "$L2/configure.ac")"
v3="$(sed -n "s/^ *version: *'\([0-9.]*\)'.*/\1/p" "$L3/meson.build" | head -1)"
grep -qx "#define PACKAGE_VERSION \"$v2\"" "$CFG/lib2/config.h" || { echo "build-libfuse: Library-2 is $v2; libfuse/config/lib2/config.h is not" >&2; exit 1; }
grep -qx "#define PACKAGE_VERSION \"$v3\"" "$CFG/lib3/fuse_config.h" || { echo "build-libfuse: Library-3 is $v3; libfuse/config/lib3/fuse_config.h is not" >&2; exit 1; }
cv3="$(awk '/FUSE_MAJOR_VERSION/ { a = $3 } /FUSE_MINOR_VERSION/ { b = $3 } /FUSE_HOTFIX_VERSION/ { c = $3 } END { print a "." b "." c }' "$CFG/lib3/libfuse_config.h")"
[ "$cv3" = "$v3" ] || { echo "build-libfuse: Library-3 is $v3; libfuse/config/lib3/libfuse_config.h says $cv3" >&2; exit 1; }

macfuse_toolchain build-libfuse || exit 1
CC="$CL/bin/clang"
TREE="$STAGE$MACFUSE_PREFIX"
LIBDIR="$TREE/lib"
INCDIR="$TREE/include"
# spec: DETAILS.md "Install" -- install names and the .pc/.la paths stay upstream's, so third-party binaries and builds find them;
#       /usr/local links into the tree
UPSTREAM_PREFIX=/usr/local
W="$(mktemp -d "$BUILD/libfuse.XXXXXX")"
trap 'rm -rf "$W"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# platform: --no-default-config, because clang22's clang.cfg links its own librecaulk.a copy; the inputs are
#           exactly the 10.9 SDK, the pinned Recaulk headers and its whole librecaulk.a, last on the link
BASE="--no-default-config --target=x86_64-apple-macos10.9 -isysroot $SDK -isystem $RC/include/recaulk"
# platform: -F for <MFMount/MFMount.h>, which uses __counted_by; the 10.9 SDK has none (macOS 14 added it)
MFINC="-F$FWDIR -D__counted_by(x)="
LINK="-fuse-ld=lld -Wl,-headerpad_max_install_names"
# platform: upstream links -Wl,-delay_framework,{CoreFoundation,DiskArbitration,MFMount}, an ld-prime option that
#           neither ld64.lld nor 10.9's ld64 has, so these are plain links; iconv is libiconv.2 on 10.9, not libSystem
LIBS="-F$FWDIR -framework MFMount -framework CoreFoundation -framework DiskArbitration -licucore -liconv -lpthread"
NM="$CL/bin/llvm-nm" sh "$REPO_ROOT/build/recaulk-unexported.sh" "$RC/lib/librecaulk.a" > "$W/unexported"
# spec: tests/libfuse-exports-test.sh -- without the list, _clock_gettime and _aligned_alloc are exported; upstream exports neither
RECAULK="$RC/lib/librecaulk.a -Wl,-unexported_symbols_list,$W/unexported"

# platform: 10.9's <sys/kauth.h> uses gid_t without including <sys/types.h>, and modules/threadid.c includes it first
extra() {
  case $1 in modules/threadid.c) echo "-include sys/types.h" ;; esac
}

mkdir -p "$W/lib/pkgconfig" "$W/include/fuse" "$W/include/fuse3" "$W/ex" "$W/l2/modules" "$W/l3/modules"

echo "== libfuse 2 ($v2)"
C2="$BASE $MFINC -O2 -g -Wall -W -Wno-sign-compare -Wstrict-prototypes -Wmissing-declarations -Wwrite-strings
    -fno-strict-aliasing -Wno-unused-parameter -Wno-deprecated-declarations
    -I$CFG/lib2 -I$L2/include -DHAVE_CONFIG_H -DFUSERMOUNT_DIR=\"/usr/local/bin\"
    -D_FILE_OFFSET_BITS=64 -D_REENTRANT -DFUSE_USE_VERSION=26"
O2=""
for f in fuse.c fuse_kern_chan.c fuse_loop.c fuse_loop_dispatch.c fuse_loop_mt.c fuse_lowlevel.c \
         fuse_mt.c fuse_opt.c fuse_session.c fuse_signals.c buffer.c cuse_lowlevel.c helper.c \
         modules/subdir.c modules/iconv.c \
         fuse_darwin.c fuse_darwin_chan.c modules/threadid.c modules/volicon.c mount_darwin.c; do
  o="$W/l2/${f%.c}.o"
  # shellcheck disable=SC2046,SC2086
  "$CC" $C2 $(extra "$f") -c "$L2/lib/$f" -o "$o"
  O2="$O2 $o"
done
# shellcheck disable=SC2086
"$CC" $BASE $LINK -dynamiclib -install_name "$UPSTREAM_PREFIX/lib/libfuse.2.dylib" \
  -compatibility_version 12.0.0 -current_version 12.9.0 \
  $O2 $LIBS $RECAULK -o "$W/lib/libfuse.2.dylib"
ln -s libfuse.2.dylib "$W/lib/libfuse.dylib"
cp "$L2/include/old/fuse.h" "$W/include/fuse.h"
for h in fuse.h fuse_common.h fuse_common_compat.h fuse_compat.h fuse_lowlevel.h fuse_lowlevel_compat.h fuse_opt.h; do
  cp "$L2/include/$h" "$W/include/fuse/$h"
done
sed -e "s|@prefix@|$UPSTREAM_PREFIX|" -e "s|@VERSION@|$v2|" "$CFG/lib2/fuse.pc.in" > "$W/lib/pkgconfig/fuse.pc"
sed -e "s|@libdir@|$UPSTREAM_PREFIX/lib|" "$CFG/lib2/libfuse.la.in" > "$W/lib/libfuse.la"

echo "== libfuse 3 ($v3)"
C3="$BASE $MFINC -std=gnu11 -O2 -g -Wall -Wextra -Wno-sign-compare -Wstrict-prototypes -Wmissing-declarations
    -Wwrite-strings -fno-strict-aliasing -Wno-unused-parameter -Wno-deprecated-declarations
    -I$CFG/lib3 -I$L3/include -I$L3/lib
    -D_REENTRANT -DHAVE_LIBFUSE_PRIVATE_CONFIG_H -D_FILE_OFFSET_BITS=64 -DFUSE_DARWIN_ENABLE_EXTENSIONS=0
    -DFUSE_USE_VERSION=317 -DFUSERMOUNT_DIR=\"/usr/local/bin\""
O3=""
for f in fuse.c fuse_loop.c fuse_loop_mt.c fuse_lowlevel.c fuse_opt.c fuse_signals.c buffer.c helper.c \
         modules/subdir.c mount_util.c fuse_log.c compat.c util.c \
         fuse_darwin.c mount_darwin.c modules/threadid.c modules/volicon.c modules/iconv.c; do
  o="$W/l3/${f%.c}.o"
  # shellcheck disable=SC2046,SC2086
  "$CC" $C3 $(extra "$f") -c "$L3/lib/$f" -o "$o"
  O3="$O3 $o"
done
# shellcheck disable=SC2086
"$CC" $BASE $LINK -dynamiclib -install_name "$UPSTREAM_PREFIX/lib/libfuse3.4.dylib" \
  -compatibility_version 4.0.0 -current_version 4.0.0 \
  $O3 $LIBS $RECAULK -o "$W/lib/libfuse3.4.dylib"
ln -s libfuse3.4.dylib "$W/lib/libfuse3.dylib"
for h in fuse.h fuse_common.h fuse_lowlevel.h fuse_opt.h fuse_log.h; do
  cp "$L3/include/$h" "$W/include/fuse3/$h"
done
cp "$CFG/lib3/libfuse_config.h" "$W/include/fuse3/libfuse_config.h"
sed -e "s|@prefix@|$UPSTREAM_PREFIX|" -e "s|@VERSION@|$v3|" "$CFG/lib3/fuse3.pc.in" > "$W/lib/pkgconfig/fuse3.pc"

echo "== examples"
# spec: tests/smoke-mavericks.sh -- built as a third-party file system would be, against the staged public headers and
#       dylibs; libfuse 3's examples use plain struct stat, so FUSE_DARWIN_ENABLE_EXTENSIONS=0 (upstream's meson
#       skips the examples on darwin); passthrough.c also needs example-compat.h (O_DIRECT, mkfifoat, mknodat)
EXC="$BASE -O2 -g -Wall -Wno-unused-parameter -D_FILE_OFFSET_BITS=64 -D_REENTRANT"
# shellcheck disable=SC2086
"$CC" $EXC -I"$W/include/fuse" "$L2/example/hello.c" \
  $LINK -L"$W/lib" -lfuse.2 $RECAULK -o "$W/ex/hello2"
# shellcheck disable=SC2086
"$CC" $EXC -DFUSE_DARWIN_ENABLE_EXTENSIONS=0 -I"$W/include/fuse3" "$L3/example/hello.c" \
  $LINK -L"$W/lib" -lfuse3.4 $RECAULK -o "$W/ex/hello3"
# shellcheck disable=SC2086
"$CC" $EXC -DFUSE_DARWIN_ENABLE_EXTENSIONS=0 -I"$W/include/fuse3" -I"$CFG/lib3" -include "$CFG/lib3/example-compat.h" \
  "$L3/example/passthrough.c" $LINK -L"$W/lib" -lfuse3.4 $RECAULK -o "$W/ex/passthrough3"

# spec: tests/libfuse-exports-test.sh -- lib/ and include/ are shared with other build scripts (build/build-shim.sh), so only
#       libfuse's own files and directories are replaced, each whole
mkdir -p "$LIBDIR/pkgconfig" "$INCDIR" "$EX"
for f in libfuse.2.dylib libfuse.dylib libfuse.la libfuse3.4.dylib libfuse3.dylib pkgconfig/fuse.pc pkgconfig/fuse3.pc; do
  rm -rf "${LIBDIR:?}/$f"
  mv "$W/lib/$f" "$LIBDIR/$f"
done
for f in fuse.h fuse fuse3; do
  rm -rf "${INCDIR:?}/$f"
  mv "$W/include/$f" "$INCDIR/$f"
done
for e in hello2 hello3 passthrough3; do mv -f "$W/ex/$e" "$EX/$e"; done
echo "built $LIBDIR, $INCDIR and $EX"
