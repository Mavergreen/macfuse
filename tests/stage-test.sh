#!/bin/sh
# platform: host-agnostic
# spec: build/stage.sh -- it lays out the product tree under $MACFUSE_PREFIX and links every upstream path (UPSTREAM_LINKS
#       below) into it: each is a symlink at its absolute path whose target, read inside the stage, is the tree file;
#       fs/Contents/Extensions/10/macfuse.kext is a real directory; nothing is group- or other-writable; and
#       stage_product.sh's manifest lists exactly those links as `outside`. Runs on fixtures, and also on the real build
#       stage when one exists.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/.." && pwd)}"
export REPO_ROOT
. "$REPO_ROOT/build/lib.sh"
. "$REPO_ROOT/build/msc.sh"
fails=0
fail() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/stage-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# spec: DETAILS.md "Install" -- each path third-party binaries and builds have built in, and the tree file it must resolve to,
#       kept apart from build/lib.sh's MACFUSE_LINKS so that drift there is caught; the last three are upstream 4.0.5's osxfuse
#       compatibility names (maintainer, 2026-11-20)
UPSTREAM_LINKS="Library/Filesystems/macfuse.fs fs
Library/Frameworks/macFUSE.framework Frameworks/macFUSE.framework
usr/local/lib/libfuse.2.dylib lib/libfuse.2.dylib
usr/local/lib/libfuse.dylib lib/libfuse.dylib
usr/local/lib/libfuse.la lib/libfuse.la
usr/local/lib/libfuse3.4.dylib lib/libfuse3.4.dylib
usr/local/lib/libfuse3.dylib lib/libfuse3.dylib
usr/local/lib/pkgconfig/fuse.pc lib/pkgconfig/fuse.pc
usr/local/lib/pkgconfig/fuse3.pc lib/pkgconfig/fuse3.pc
usr/local/include/fuse.h include/fuse.h
usr/local/include/fuse include/fuse
usr/local/include/fuse3 include/fuse3
Library/Frameworks/OSXFUSE.framework Frameworks/OSXFUSE.framework
usr/local/lib/libosxfuse.2.dylib lib/libfuse.2.dylib
usr/local/lib/libosxfuse_i64.2.dylib lib/libfuse.2.dylib"

fixture_built() {
  t="$1$MACFUSE_PREFIX"
  mkdir -p "$t/fs/Contents/Frameworks/MFMount.framework/Versions/A/Resources" "$t/fs/Contents/Resources" \
    "$t/Frameworks/macFUSE.framework/Versions/A/Resources" "$t/lib/pkgconfig" "$t/include/fuse" "$t/include/fuse3"
  for f in fs/Contents/Frameworks/MFMount.framework/Versions/A/MFMount fs/Contents/Resources/mount_macfuse \
           fs/Contents/Resources/load_macfuse Frameworks/macFUSE.framework/Versions/A/macFUSE lib/libfuse.2.dylib \
           lib/libfuse3.4.dylib lib/libmfosrelease.dylib; do
    echo "$f" > "$t/$f"; chmod 775 "$t/$f"
  done
  for f in fs/Contents/Frameworks/MFMount.framework/Versions/A/Resources/Info.plist \
           Frameworks/macFUSE.framework/Versions/A/Resources/Info.plist lib/libfuse.la lib/pkgconfig/fuse.pc \
           lib/pkgconfig/fuse3.pc include/fuse.h include/fuse/fuse_common.h include/fuse3/fuse.h; do
    echo "$f" > "$t/$f"; chmod 664 "$t/$f"
  done
  ln -s A "$t/Frameworks/macFUSE.framework/Versions/Current"
  ln -s Versions/Current/macFUSE "$t/Frameworks/macFUSE.framework/macFUSE"
  ln -s Versions/Current/Resources "$t/Frameworks/macFUSE.framework/Resources"
  ln -s A "$t/fs/Contents/Frameworks/MFMount.framework/Versions/Current"
  ln -s libfuse.2.dylib "$t/lib/libfuse.dylib"
  ln -s libfuse3.4.dylib "$t/lib/libfuse3.dylib"
  chmod 700 "$t/include/fuse"; chmod 600 "$t/include/fuse.h"
}
fixture_dmg() {
  c="$1/Library/Filesystems/macfuse.fs/Contents"
  mkdir -p "$c/_CodeSignature" "$c/Resources/macfuse.app/Contents/Resources"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n\t<key>CFBundleIdentifier</key>\n\t<string>io.macfuse.filesystems.macfuse</string>\n</dict>\n</plist>\n' > "$c/Info.plist"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n\t<key>CFBundleVersion</key>\n\t<string>5.5.0</string>\n</dict>\n</plist>\n' > "$c/version.plist"
  echo sig > "$c/_CodeSignature/CodeResources"
  echo '{\\rtf1 license}' > "$c/Resources/License.rtf"
}
fixture_kext() {
  mkdir -p "$1/macfuse.kext/Contents/MacOS"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n\t<key>CFBundleExecutable</key>\n\t<string>macfuse</string>\n\t<key>CFBundleIdentifier</key>\n\t<string>io.macfuse.filesystems.macfuse.21</string>\n</dict>\n</plist>\n' > "$1/macfuse.kext/Contents/Info.plist"
  echo kext > "$1/macfuse.kext/Contents/MacOS/macfuse"
  chmod 664 "$1/macfuse.kext/Contents/Info.plist"; chmod 775 "$1/macfuse.kext/Contents/MacOS/macfuse"
}
mode() { ls -ld "$1" | awk '{ print $1 }' | cut -c1-10; }

# spec: build/stage.sh -- every assertion on one staged OUT; DMG is the dmg root its plists came from
check_stage() {
  out="$1"; dmg="$2"; tree="$out$MACFUSE_PREFIX"
  [ -d "$tree" ] || { fail "$out holds no $MACFUSE_PREFIX"; return; }
  while read -r p t; do
    if [ ! -L "$out/$p" ]; then fail "/$p is not a symlink in the stage"; continue; fi
    got="$(readlink "$out/$p")"
    [ "$got" = "$MACFUSE_PREFIX/$t" ] || fail "/$p -> $got, not $MACFUSE_PREFIX/$t"
    [ -e "$out$got" ] || fail "/$p -> $got, which is not in the staged tree"
  done << EOF
$UPSTREAM_LINKS
EOF
  for h in pre-uninstall:-rwxr-xr-x lib-fuse-mounts.sh:-rw-r--r--; do
    f="$tree/libexec/mavergreen/${h%%:*}"
    if [ -L "$f" ] || [ ! -f "$f" ]; then fail "libexec/mavergreen/${h%%:*} is not a regular file in the stage"; continue; fi
    cmp -s "$REPO_ROOT/packaging/${h%%:*}" "$f" || fail "libexec/mavergreen/${h%%:*} is not packaging/${h%%:*}"
    [ "$(mode "$f")" = "${h#*:}" ] || fail "libexec/mavergreen/${h%%:*} is $(mode "$f"), not ${h#*:}"
  done
  o="$tree/Frameworks/OSXFUSE.framework/Versions/A/OSXFUSE"
  [ -L "$o" ] && [ "$(readlink "$o")" = ../../../macFUSE.framework/Versions/A/macFUSE ] ||
    fail "Frameworks/OSXFUSE.framework/Versions/A/OSXFUSE is not a link to ../../../macFUSE.framework/Versions/A/macFUSE"
  [ -f "$o" ] && cmp -s "$o" "$tree/Frameworks/macFUSE.framework/Versions/A/macFUSE" ||
    fail "Frameworks/OSXFUSE.framework/Versions/A/OSXFUSE does not reach macFUSE.framework's binary"
  [ "$(readlink "$tree/Frameworks/OSXFUSE.framework/Resources")" = ../macFUSE.framework/Resources ] ||
    fail "Frameworks/OSXFUSE.framework/Resources is not a link to ../macFUSE.framework/Resources"
  [ "$(cd "$tree/Frameworks/OSXFUSE.framework" && find . | sort | tr '\n' ' ')" = ". ./Resources ./Versions ./Versions/A ./Versions/A/OSXFUSE " ] ||
    fail "Frameworks/OSXFUSE.framework holds more than its binary's and its Resources' links"
  k="$tree/fs/Contents/Extensions/10/macfuse.kext"
  if [ -L "$k" ] || [ ! -d "$k" ]; then fail "fs/Contents/Extensions/10/macfuse.kext is not a real directory"; fi
  [ -f "$k/Contents/Info.plist" ] || fail "the staged kext has no Contents/Info.plist"
  for p in Info.plist version.plist Resources/License.rtf; do
    cmp -s "$dmg/Library/Filesystems/macfuse.fs/Contents/$p" "$tree/fs/Contents/$p" || fail "fs/Contents/$p is not upstream's"
  done
  [ ! -e "$tree/fs/Contents/_CodeSignature" ] || fail "upstream's _CodeSignature was staged (it seals files we replaced)"
  w="$(cd "$out" && find . \( -perm -020 -o -perm -002 \) ! -type l)"
  [ -z "$w" ] || fail "group- or other-writable in the stage: $w"
  d="$(cd "$out" && find . -type d ! -perm 755)"
  [ -z "$d" ] || fail "directories not 755 in the stage: $d"
  f="$(cd "$out" && find . -type f ! -perm 644 ! -perm 755 ! -perm 4755)"
  [ -z "$f" ] || fail "files neither 644 nor 755 (nor the helpers' 4755) in the stage: $f"
  a="$(cd "$out" && find . -name '._*')"
  [ -z "$a" ] || fail "AppleDouble files in the stage: $a"
  for h in mount_macfuse load_macfuse; do
    m="$(mode "$tree/fs/Contents/Resources/$h")"
    [ "$m" = -rwsr-xr-x ] || fail "fs/Contents/Resources/$h is $m, not -rwsr-xr-x (4755)"
  done
  s="$(cd "$out" && find . -type f -perm -4000 | sort | tr '\n' ' ')"
  [ "$s" = ".$MACFUSE_PREFIX/fs/Contents/Resources/load_macfuse .$MACFUSE_PREFIX/fs/Contents/Resources/mount_macfuse " ] ||
    fail "setuid files are '$s', not exactly the two helpers"
  ( cd "$k" && find . -type d ) > "$T/kdirs"
  ( cd "$k" && find . -type f ) > "$T/kfiles"
  while read -r d; do
    [ "$(mode "$k/$d")" = drwxr-xr-x ] || fail "kext directory $d is $(mode "$k/$d"), not 755"
  done < "$T/kdirs"
  while read -r f; do
    case "$f" in ./Contents/MacOS/*) want=-rwxr-xr-x ;; *) want=-rw-r--r-- ;; esac
    [ "$(mode "$k/$f")" = "$want" ] || fail "kext file $f is $(mode "$k/$f"), not $want"
  done < "$T/kfiles"

  rm -rf "$T/sp"; cp -pR "$out" "$T/sp"
  if sh "$SHIPYARD_SCRIPTS/stage_product.sh" --stage "$T/sp" --product macfuse --name "Mavericks macFUSE" \
       --version "$(upstream_version)-mavericks.1" --scripts-out "$T/sp-scripts" > "$T/sp.log" 2>&1; then
    awk '/<key>outside<\/key>/ { on = 1; next } on && /<\/array>/ { exit }
         on { s = $0; if (sub(/^[ \t]*<string>/, "", s) && sub(/<\/string>[ \t]*$/, "", s)) print s }' \
      "$T/sp$MACFUSE_PREFIX/mavergreen.plist" | sort > "$T/outside.got"
    printf '%s\n' "$UPSTREAM_LINKS" | awk '{ print $1 }' | sort > "$T/outside.want"
    cmp -s "$T/outside.want" "$T/outside.got" ||
      { diff "$T/outside.want" "$T/outside.got" >&2 || :; fail "the manifest's outside is not exactly the upstream links"; }
  else
    cat "$T/sp.log" >&2; fail "stage_product.sh refused the stage (is macfuse in $SHIPYARD_SCRIPTS/product-names?)"
  fi
}

fixture_built "$T/built"; fixture_dmg "$T/dmg"; fixture_kext "$T/k"
if sh "$REPO_ROOT/build/stage.sh" "$T/built" "$T/dmg" "$T/k/macfuse.kext" "$T/out" > "$T/log" 2>&1; then
  check_stage "$T/out" "$T/dmg"
  echo stale > "$T/out/stale"
  sh "$REPO_ROOT/build/stage.sh" "$T/built" "$T/dmg" "$T/k/macfuse.kext" "$T/out" > "$T/log" 2>&1 || { cat "$T/log" >&2; fail "a second stage.sh run failed"; }
  [ ! -e "$T/out/stale" ] || fail "stage.sh left a stale file in OUT"
  [ "$(mode "$T/built$MACFUSE_PREFIX/fs/Contents/Resources/mount_macfuse")" = -rwxrwxr-x ] || fail "stage.sh changed BUILT"
else
  cat "$T/log" >&2; fail "stage.sh refused the fixtures"
fi

refused() { # MESSAGE BUILT DMG KEXT -- stage.sh refuses, saying MESSAGE, and leaves OUT as it was
  m=$1; shift
  if sh "$REPO_ROOT/build/stage.sh" "$@" "$T/out" > "$T/log" 2>&1; then fail "accepted: $m"; return; fi
  grep -q "$m" "$T/log" || { cat "$T/log" >&2; fail "refused without saying: $m"; }
  [ -d "$T/out$MACFUSE_PREFIX" ] || fail "a refusal ($m) removed the earlier OUT"
}
cp -pR "$T/built" "$T/nohelper"; rm "$T/nohelper$MACFUSE_PREFIX/fs/Contents/Resources/load_macfuse"
refused "no fs/Contents/Resources/load_macfuse" "$T/nohelper" "$T/dmg" "$T/k/macfuse.kext"
cp -pR "$T/dmg" "$T/noplist"; rm "$T/noplist/Library/Filesystems/macfuse.fs/Contents/version.plist"
refused "version.plist" "$T/built" "$T/noplist" "$T/k/macfuse.kext"
cp -pR "$T/dmg" "$T/nolicense"; rm "$T/nolicense/Library/Filesystems/macfuse.fs/Contents/Resources/License.rtf"
refused "License.rtf" "$T/built" "$T/nolicense" "$T/k/macfuse.kext"
mkdir -p "$T/nokext/macfuse.kext/Contents"
refused "macfuse.kext" "$T/built" "$T/dmg" "$T/nokext/macfuse.kext"

# spec: build/stage.sh usage "on any error an earlier OUT is left as it was" -- a stub mv that refuses to move the new stage into place
mkdir -p "$T/mvbin"
printf '#!/bin/sh\ncase "$1" in */.stage.??????) echo "stub mv: refused" >&2; exit 1 ;; esac\nexec /bin/mv "$@"\n' > "$T/mvbin/mv"
chmod 755 "$T/mvbin/mv"
echo earlier > "$T/out/earlier"
if PATH="$T/mvbin:$PATH" sh "$REPO_ROOT/build/stage.sh" "$T/built" "$T/dmg" "$T/k/macfuse.kext" "$T/out" > "$T/log" 2>&1; then
  fail "stage.sh succeeded although the new stage could not be moved into place"
fi
[ -f "$T/out/earlier" ] && [ -d "$T/out$MACFUSE_PREFIX" ] || fail "a failed move into OUT lost the earlier OUT"
[ -z "$(ls -a "$T" | grep '^\.stage\.')" ] || fail "a failed move into OUT left $(ls -a "$T" | grep '^\.stage\.') behind"
rm -f "$T/out/earlier"

BUILD="${MAVERICKS_BUILD_ROOT:-${TMPDIR:-/tmp}/mm-build}"
REAL="${MACFUSE_STAGE:-$BUILD/stage}"
KEXT="${MACFUSE_KEXT:-$BUILD/kext-out/macfuse.kext}"
DMG="${MACFUSE_DMG_ROOT:-}"
if [ -x "$REAL$MACFUSE_PREFIX/fs/Contents/Resources/mount_macfuse" ] && [ -d "$KEXT" ] && [ -n "$DMG" ] && [ -d "$DMG" ]; then
  if sh "$REPO_ROOT/build/stage.sh" "$REAL" "$DMG" "$KEXT" "$T/real" > "$T/log" 2>&1; then
    check_stage "$T/real" "$DMG"
  else
    cat "$T/log" >&2; fail "stage.sh refused the real build stage $REAL"
  fi
else
  echo "stage-test: no real build stage, kext and MACFUSE_DMG_ROOT; fixtures only"
fi

[ "$fails" -eq 0 ] || { echo "stage-test: $fails failure(s)" >&2; exit 1; }
echo "stage-test: OK"
