#!/bin/sh
# platform: host-agnostic
# spec: 2026-11-19-macfuse-product/task-9-brief.md and global-constraints.md "Upstream's paths" -- lays out the product tree and
#       links upstream's paths into it; tests/stage-test.sh holds the contract.
#   usage: stage.sh BUILT DMG_ROOT KEXT OUT
#          BUILT is the build stage that build/build-mfmount.sh, build-libfuse.sh, build-framework.sh, build-shim.sh and
#          adapt-helpers.sh write: BUILT/$MACFUSE_PREFIX. DMG_ROOT is upstream's extracted dmg payload (build/extract-dmg.sh),
#          read for macfuse.fs's Contents/Info.plist, Contents/version.plist and Contents/Resources/License.rtf only.
#          KEXT is build/retarget-kext.sh's macfuse.kext. Writes OUT (replaced; on any error an earlier OUT is left as it was): a copy of BUILT's tree, with
#          upstream's two plists in fs/Contents, its License.rtf (the notice its binary license asks a redistribution to carry)
#          in fs/Contents/Resources, and KEXT at fs/Contents/Extensions/10/macfuse.kext; and at each of upstream's
#          paths a symlink to the absolute tree path. Directories and executables are 755, other files 644, and
#          mount_macfuse and load_macfuse 4755. BUILT, DMG_ROOT and KEXT are not changed.
set -eu
umask 022
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/.." && pwd)}"
export REPO_ROOT
. "$REPO_ROOT/build/lib.sh"
[ $# -eq 4 ] || { echo "usage: $0 BUILT DMG_ROOT KEXT OUT" >&2; exit 2; }
BUILT=$1
DMG=$2
KEXT=$3
OUT=$4
die() { echo "stage: $*" >&2; exit 1; }
SRC="$BUILT$MACFUSE_PREFIX"
UPFS="$DMG/Library/Filesystems/macfuse.fs/Contents"

for f in fs/Contents/Frameworks/MFMount.framework/Versions/A/MFMount fs/Contents/Resources/mount_macfuse \
         fs/Contents/Resources/load_macfuse Frameworks/macFUSE.framework/Versions/A/macFUSE lib/libmfosrelease.dylib; do
  [ -f "$SRC/$f" ] || die "$BUILT has no $f under $MACFUSE_PREFIX: run the build first"
done
while read -r p t; do
  [ -e "$SRC/$t" ] || [ -L "$SRC/$t" ] || die "$BUILT has no $t under $MACFUSE_PREFIX, which /$p links to: run the build first"
done << EOF
$MACFUSE_LINKS
EOF
for p in Info.plist version.plist Resources/License.rtf; do
  [ -f "$UPFS/$p" ] || die "$DMG has no Library/Filesystems/macfuse.fs/Contents/$p"
done
[ -f "$KEXT/Contents/Info.plist" ] || die "$KEXT is not a built macfuse.kext: no Contents/Info.plist"
EXE="$(plist_string "$KEXT/Contents/Info.plist" CFBundleExecutable)" || die "$KEXT is not a built macfuse.kext: no CFBundleExecutable"
[ -f "$KEXT/Contents/MacOS/$EXE" ] || die "$KEXT is not a built macfuse.kext: no Contents/MacOS/$EXE"

mkdir -p "$(dirname "$OUT")"
N="$(mktemp -d "$(dirname "$OUT")/.stage.XXXXXX")"
trap 'rm -rf "$N"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
T="$N$MACFUSE_PREFIX"
mkdir -p "$(dirname "$T")"
# platform: COPYFILE_DISABLE keeps macOS's cp from writing AppleDouble ._* files for extended attributes
COPYFILE_DISABLE=1 cp -R "$SRC" "$T"
cp "$UPFS/Info.plist" "$UPFS/version.plist" "$T/fs/Contents/"
cp "$UPFS/Resources/License.rtf" "$T/fs/Contents/Resources/"
mkdir -p "$T/fs/Contents/Extensions/10"
COPYFILE_DISABLE=1 cp -R "$KEXT" "$T/fs/Contents/Extensions/10/macfuse.kext"
while read -r p t; do
  mkdir -p "$N/$(dirname "$p")"
  ln -s "$MACFUSE_PREFIX/$t" "$N/$p"
done << EOF
$MACFUSE_LINKS
EOF

find "$N" -name '._*' -exec rm -f {} +
find "$N" -type d -exec chmod 755 {} +
find "$N" -type f -perm -100 -exec chmod 755 {} +
find "$N" -type f ! -perm -100 -exec chmod 644 {} +
# spec: global-constraints.md "mount_macfuse and load_macfuse: setuid root (root:wheel 4755) as installed" -- stevedore records the
#       staged mode and writes every owner as 0/0 (tests/package-test.sh reads both back from the pkg)
chmod 4755 "$T/fs/Contents/Resources/mount_macfuse" "$T/fs/Contents/Resources/load_macfuse"

rm -rf "$OUT"
mv "$N" "$OUT"
trap - EXIT
echo "staged $OUT"
