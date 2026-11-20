#!/bin/sh
# platform: host-agnostic -- stevedore and shipyard's seams build and read the pkg; cpio lists its payload
# spec: 2026-11-19-macfuse-product/task-9-brief.md Step 2 -- build/package.sh makes macfuse-V.pkg from build/stage.sh's stage:
#       in the dev.mavergreen.macfuse payload (read with stevedore expand, listed by build/list-payload.sh, and by lsbom
#       from the BOM where lsbom exists) mount_macfuse and load_macfuse are 0/0 104755, and every other entry is 0/0
#       with no group or other write; and shipyard's artifact conformance passes with INGREDIENTS.md's declared
#       deviations. Runs on fixtures, and also on the real build stage and kext when they exist.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/.." && pwd)}"
export REPO_ROOT
. "$REPO_ROOT/build/lib.sh"
. "$REPO_ROOT/build/msc.sh"
fails=0
fail() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/package-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
SOURCE_DATE_EPOCH=1763600000; export SOURCE_DATE_EPOCH
CL="$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$REPO_ROOT/components/clang22")" || { echo "FAIL: no clang22" >&2; exit 1; }
LIPO="$CL/bin/llvm-lipo"; OTOOL="$CL/bin/llvm-otool"; NM="$CL/bin/llvm-nm"; STRINGS="$CL/bin/llvm-strings"
export LIPO OTOOL NM STRINGS
STEVEDORE="$(sh "$SHIPYARD_SCRIPTS/fetch_stevedore.sh")" || { echo "FAIL: no stevedore" >&2; exit 1; }
UP="$(upstream_version)"
V="$UP-mavericks.1"
upd_id="$(sh "$SHIPYARD_SCRIPTS/product-name.sh" updater-bundle-id macfuse)" || { echo "FAIL: macfuse is not in $SHIPYARD_SCRIPTS/product-names" >&2; exit 1; }
feed="$(sh "$SHIPYARD_SCRIPTS/product-name.sh" feed macfuse)"
HELPERS=".$MACFUSE_PREFIX/fs/Contents/Resources/load_macfuse .$MACFUSE_PREFIX/fs/Contents/Resources/mount_macfuse"

fixture_updater() { # DIR VERSION
  c="$1/macfuse-updater.app/Contents"; mkdir -p "$c/MacOS"
  printf '#!/bin/sh\n' > "$c/MacOS/macfuse-updater"; chmod 755 "$c/MacOS/macfuse-updater"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n<key>CFBundleIdentifier</key><string>%s</string><key>CFBundleExecutable</key><string>macfuse-updater</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>%s</string><key>SUFeedURL</key><string>%s</string>\n</dict>\n</plist>\n' \
    "$upd_id" "$2" "$feed" > "$c/Info.plist"
}
# spec: tests/stage-test.sh -- the same fixture shapes, as a dmg root, a kext and a build stage
fixture_inputs() {
  t="$1/built$MACFUSE_PREFIX"
  mkdir -p "$t/fs/Contents/Frameworks/MFMount.framework/Versions/A/Resources" "$t/fs/Contents/Resources" \
    "$t/Frameworks/macFUSE.framework/Versions/A/Resources" "$t/lib/pkgconfig" "$t/include/fuse" "$t/include/fuse3"
  for f in fs/Contents/Frameworks/MFMount.framework/Versions/A/MFMount fs/Contents/Resources/mount_macfuse \
           fs/Contents/Resources/load_macfuse Frameworks/macFUSE.framework/Versions/A/macFUSE lib/libfuse.2.dylib \
           lib/libfuse3.4.dylib lib/libmfosrelease.dylib; do
    echo "$f" > "$t/$f"; chmod 775 "$t/$f"
  done
  for f in lib/libfuse.la lib/pkgconfig/fuse.pc lib/pkgconfig/fuse3.pc include/fuse.h include/fuse/fuse_common.h include/fuse3/fuse.h; do
    echo "$f" > "$t/$f"; chmod 664 "$t/$f"
  done
  for b in fs/Contents/Frameworks/MFMount.framework:io.macfuse.frameworks.mount Frameworks/macFUSE.framework:io.macfuse.framework; do
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n\t<key>CFBundleIdentifier</key>\n\t<string>%s</string>\n</dict>\n</plist>\n' \
      "${b#*:}" > "$t/${b%%:*}/Versions/A/Resources/Info.plist"
    ln -s A "$t/${b%%:*}/Versions/Current"
    ln -s Versions/Current/Resources "$t/${b%%:*}/Resources"
  done
  ln -s libfuse.2.dylib "$t/lib/libfuse.dylib"
  ln -s libfuse3.4.dylib "$t/lib/libfuse3.dylib"
  c="$1/dmg/Library/Filesystems/macfuse.fs/Contents"; mkdir -p "$c/Resources"
  echo '{\\rtf1 license}' > "$c/Resources/License.rtf"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n\t<key>CFBundleIdentifier</key>\n\t<string>io.macfuse.filesystems.macfuse</string>\n</dict>\n</plist>\n' > "$c/Info.plist"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n\t<key>CFBundleVersion</key>\n\t<string>%s</string>\n</dict>\n</plist>\n' "$UP" > "$c/version.plist"
  mkdir -p "$1/k/macfuse.kext/Contents/MacOS"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n\t<key>CFBundleExecutable</key>\n\t<string>macfuse</string>\n\t<key>CFBundleIdentifier</key>\n\t<string>io.macfuse.filesystems.macfuse.21</string>\n</dict>\n</plist>\n' > "$1/k/macfuse.kext/Contents/Info.plist"
  echo kext > "$1/k/macfuse.kext/Contents/MacOS/macfuse"; chmod 755 "$1/k/macfuse.kext/Contents/MacOS/macfuse"
}

# spec: task-9-brief.md Step 2 -- PKG's dev.mavergreen.macfuse payload, listed "./path<TAB>mode<TAB>uid/gid" into OUT
payload_listing() {
  rm -rf "$T/x"
  "$STEVEDORE" expand "$1" "$T/x" > /dev/null || { fail "stevedore cannot expand $1"; return 1; }
  comp=
  for d in "$T"/x/*; do
    if [ -f "$d/PackageInfo" ] && grep -q 'identifier="dev.mavergreen.macfuse"' "$d/PackageInfo"; then comp=$d; fi
  done
  [ -n "$comp" ] || { fail "$1 has no dev.mavergreen.macfuse component"; return 1; }
  gzip -dc < "$comp/Payload" > "$T/payload.cpio" || { fail "cannot decompress the payload"; return 1; }
  sh "$REPO_ROOT/build/list-payload.sh" "$T/payload.cpio" "$2" || { fail "cannot list the payload"; return 1; }
  if command -v lsbom > /dev/null 2>&1; then
    lsbom "$comp/Bom" > "$2.bom" || { fail "lsbom cannot read the BOM"; return 1; }
  fi
}
# spec: task-9-brief.md Step 2 -- the helpers 0/0 104755; every other entry 0/0, no group or other write
check_modes() {
  awk -F'\t' -v helpers="$HELPERS" '
    BEGIN { n = split(helpers, h, " "); for (i = 1; i <= n; i++) want[h[i]] = 1 }
    $1 in want { seen[$1] = 1; if ($2 != "104755" || $3 != "0/0") printf "%s is %s %s, not 104755 0/0\n", $1, $2, $3; next }
    { m = substr($2, length($2) - 1, 2)
      if ($3 != "0/0") printf "%s is owned by %s, not 0/0\n", $1, $3
      if ($2 !~ /^12/ && (m ~ /[2367]/)) printf "%s is %s: group or other may write\n", $1, $2
      if ($2 ~ /^10/ && $2 ~ /^10[4-7]/) printf "%s is %s: set-id outside the two helpers\n", $1, $2 }
    END { for (k in want) if (!(k in seen)) printf "%s is not in the payload\n", k }' "$1" > "$T/modes.bad"
  [ ! -s "$T/modes.bad" ] || { cat "$T/modes.bad" >&2; fail "$2: payload modes or owners are wrong"; }
}
conforms() { # DIST
  printf '## macFUSE %s for Mavericks (%s)\n\n### What changed\n\n- Test.\n' "$UP" "$V" > "$1/RELEASE_NOTES.md"
  sh "$SHIPYARD_SCRIPTS/stand-in-feeds.sh" "$1" "$V" > /dev/null
  facts="$(sh "$SHIPYARD_SCRIPTS/artifact-facts.sh" "$1" "$V" "$REPO_ROOT")" || { fail "artifact-facts could not read $1"; return; }
  printf '%s\n' "$facts" > "$T/facts"
  printf '%s\n' "$facts" | sh "$SHIPYARD_SCRIPTS/check-artifact-conformance.sh" > "$T/conformance" 2>&1 \
    || { cat "$T/conformance" >&2; fail "the pkg in $1 does not conform"; }
}
package() { sh "$REPO_ROOT/build/package.sh" "$@" > "$T/log" 2>&1; }
whole() { # NAME STAGE -- package STAGE and check what comes out
  rm -rf "$T/dist-$1"
  if package --stage "$2" --updater-app "$T/upd/macfuse-updater.app" --version "$V" --out "$T/dist-$1"; then
    pkg="$T/dist-$1/macfuse-$V.pkg"
    [ -f "$pkg" ] || { fail "$1: no $pkg"; return; }
    if payload_listing "$pkg" "$T/list-$1"; then
      check_modes "$T/list-$1" "$1 (payload)"
      rc="$(tr -d ' \t\r\n' < "$REPO_ROOT/components/recaulk/version")"
      grep -q "needs recaulk $rc or newer" "$comp/Scripts/preinstall" 2>/dev/null ||
        fail "$1: the preinstall does not require recaulk $rc (components/recaulk/version) or newer"
      [ ! -f "$T/list-$1.bom" ] || check_modes "$T/list-$1.bom" "$1 (BOM)"
      grep -q "^\.$MACFUSE_PREFIX/libexec/mavergreen/pre-uninstall	100755	0/0\$" "$T/list-$1" ||
        fail "$1: the payload has no 100755 libexec/mavergreen/pre-uninstall"
      for l in Library/Frameworks/OSXFUSE.framework usr/local/lib/libosxfuse.2.dylib usr/local/lib/libosxfuse_i64.2.dylib \
               "${MACFUSE_PREFIX#/}/Frameworks/OSXFUSE.framework/Versions/A/OSXFUSE"; do
        grep -q "^\./$l	120755	0/0\$" "$T/list-$1" || fail "$1: the payload has no osxfuse compatibility link $l"
      done
      pre="$comp/Scripts/preinstall"
      grep -qxF "MACFUSE_PREFIX='$MACFUSE_PREFIX'" "$pre" || fail "$1: the preinstall does not set MACFUSE_PREFIX for the takeover"
      tk="$(grep -nx 'macfuse_takeover' "$pre" | cut -d: -f1)"
      rt="$(grep -nF "rm -rf \"\$ROOT$MACFUSE_PREFIX\"" "$pre" | cut -d: -f1)"
      [ -n "$tk" ] && [ -n "$rt" ] && [ "$tk" -lt "$rt" ] ||
        fail "$1: the preinstall does not run the takeover (packaging/preinstall-hook.sh) before removing the tree"
    fi
    conforms "$T/dist-$1"
  else
    cat "$T/log" >&2; fail "$1: package.sh refused the stage"
  fi
}

fixture_updater "$T/upd" "$V"
fixture_inputs "$T/f"
sh "$REPO_ROOT/build/stage.sh" "$T/f/built" "$T/f/dmg" "$T/f/k/macfuse.kext" "$T/stage" > "$T/log" 2>&1 ||
  { cat "$T/log" >&2; echo "FAIL: stage.sh refused the fixtures" >&2; exit 1; }
whole fixture "$T/stage"
grep -q "^installs .* ${MACFUSE_PREFIX#/}/mavergreen.plist\$" "$T/facts" 2>/dev/null || fail "no manifest in the tree"

refused() { # MESSAGE ARGS...
  m=$1; shift
  rm -rf "$T/out"
  if package "$@"; then fail "accepted: $m"; return; fi
  grep -q "$m" "$T/log" || { cat "$T/log" >&2; fail "refused without saying: $m"; }
  [ -z "$(ls "$T/out" 2>/dev/null)" ] || fail "a refusal left $(ls "$T/out") behind"
}
refused "not $UP with a -mavericks.N" --stage "$T/stage" --updater-app "$T/upd/macfuse-updater.app" --version 9.9.9-mavericks.1 --out "$T/out"
mkdir -p "$T/empty"
refused "not a build/stage.sh stage" --stage "$T/empty" --updater-app "$T/upd/macfuse-updater.app" --version "$V" --out "$T/out"
cp -pR "$T/stage" "$T/nosuid"; chmod 755 "$T/nosuid$MACFUSE_PREFIX/fs/Contents/Resources/mount_macfuse"
refused "mount_macfuse is not 4755" --stage "$T/nosuid" --updater-app "$T/upd/macfuse-updater.app" --version "$V" --out "$T/out"
# spec: build/package.sh usage -- components/recaulk/version is the YYYYMMDD.N that the preinstall requires, so an empty or malformed pin is refused
mkdir -p "$T/repo"
( cd "$REPO_ROOT" && cp -pR build components UPSTREAM_VERSION INGREDIENTS.md "$T/repo/" )
[ ! -d "$REPO_ROOT/packaging" ] || cp -pR "$REPO_ROOT/packaging" "$T/repo/"
for bad in '' 'latest' '20261120' '20261120.x' '2026112.1'; do
  printf '%s\n' "$bad" > "$T/repo/components/recaulk/version"
  rm -rf "$T/out"
  if (REPO_ROOT="$T/repo"; export REPO_ROOT; package --stage "$T/stage" --updater-app "$T/upd/macfuse-updater.app" --version "$V" --out "$T/out"); then
    fail "accepted components/recaulk/version '$bad'"
  else
    grep -q "components/recaulk/version" "$T/log" || { cat "$T/log" >&2; fail "refused components/recaulk/version '$bad' without naming it"; }
  fi
done

BUILD="${MAVERICKS_BUILD_ROOT:-${TMPDIR:-/tmp}/mm-build}"
REAL="${MACFUSE_STAGE:-$BUILD/stage}"
KEXT="${MACFUSE_KEXT:-$BUILD/kext-out/macfuse.kext}"
DMG="${MACFUSE_DMG_ROOT:-}"
if [ -x "$REAL$MACFUSE_PREFIX/fs/Contents/Resources/mount_macfuse" ] && [ -d "$KEXT" ] && [ -n "$DMG" ] && [ -d "$DMG" ]; then
  if sh "$REPO_ROOT/build/stage.sh" "$REAL" "$DMG" "$KEXT" "$T/real" > "$T/log" 2>&1; then
    whole real "$T/real"
  else
    cat "$T/log" >&2; fail "stage.sh refused the real build stage $REAL"
  fi
else
  echo "package-test: no real build stage, kext and MACFUSE_DMG_ROOT; fixtures only"
fi

[ "$fails" -eq 0 ] || { echo "package-test: $fails failure(s)" >&2; exit 1; }
echo "package-test: OK"
