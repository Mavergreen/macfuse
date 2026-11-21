#!/bin/sh
# platform: host-agnostic
# spec: DETAILS.md "macFUSE.framework is Objective-C only" -- macFUSE.framework is built from upstream's Objective-C only: it must export exactly the
#       non-Swift names of upstream's x86_64 slice, at upstream's install name, versions and bundle identity, with
#       upstream's headers and module map, link libfuse 2 as upstream's does and no /usr/lib/swift library, and pass
#       the default compat guard; the strict one (build/compat-guard.sh) is recorded and fails only outside the Drydock
#       gaps INGREDIENTS.md declares (tests/lib/strict-measure.sh). The framework-fs example links it.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/.." && pwd)}"
export REPO_ROOT
. "$REPO_ROOT/build/lib.sh"
. "$REPO_ROOT/build/msc.sh"
. "$REPO_ROOT/tests/lib/strict-measure.sh"
fails=0
fail() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }
UPFW="${MACFUSE_DMG_ROOT:-}/Library/Frameworks/macFUSE.framework"
if [ -z "${MACFUSE_DMG_ROOT:-}" ] || [ ! -f "$UPFW/Versions/A/macFUSE" ]; then
  echo "SKIP: MACFUSE_DMG_ROOT unset or lacks upstream's macFUSE.framework"; exit 77
fi
BUILD="${MAVERICKS_BUILD_ROOT:-${TMPDIR:-/tmp}/mm-build}"
SRC="${MACFUSE_SRC:-$BUILD/src}"
for d in library2 library3 mount framework; do
  [ -d "$SRC/$d" ] || { echo "FAIL: no fetched $d sources at $SRC/$d (build/fetch-sources.sh)" >&2; exit 1; }
done

T="$(mktemp -d "${TMPDIR:-/tmp}/framework-exports-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
macfuse_toolchain framework-exports-test || { echo "FAIL: no toolchain" >&2; exit 1; }
for s in "build-mfmount.sh $SRC $T/stage" "build-libfuse.sh $SRC $T/stage $T/ex" "build-framework.sh $SRC $T/stage $T/ex"; do
  set -- $s
  sh "$REPO_ROOT/build/$@" > "$T/build.log" 2>&1 || { tail -40 "$T/build.log" >&2; echo "FAIL: $1 failed" >&2; exit 1; }
done
NM="$CL/bin/llvm-nm"
OTOOL="$CL/bin/llvm-otool"
FW="$T/stage$MACFUSE_PREFIX/Frameworks/macFUSE.framework"
OURS="$FW/Versions/A/macFUSE"
[ -f "$OURS" ] || { fail "no $OURS"; exit 1; }
INSTALL=/Library/Frameworks/macFUSE.framework/Versions/A/macFUSE

# spec: build/build-framework.sh header -- upstream's Swift exports are the property descriptors of NSFileManager.swift's FileAttributeKey extension (_$s...)
"$NM" --arch=x86_64 -gUj "$UPFW/Versions/A/macFUSE" | grep -v '^_\$s' | LC_ALL=C sort > "$T/up.txt" || :
"$NM" -gUj "$OURS" | LC_ALL=C sort > "$T/ours.txt"
[ "$(wc -l < "$T/up.txt" | tr -d ' ')" -eq 46 ] || fail "upstream exports $(wc -l < "$T/up.txt" | tr -d ' ') non-Swift names, not 46"
diff "$T/up.txt" "$T/ours.txt" > "$T/diff.txt" || { cat "$T/diff.txt" >&2; fail "exports differ from upstream's non-Swift exports"; }
NM="$NM" sh "$REPO_ROOT/build/recaulk-unexported.sh" "$RC/lib/librecaulk.a" > "$T/recaulk-names.txt" || fail "recaulk-unexported.sh failed"
LC_ALL=C comm -12 "$T/recaulk-names.txt" "$T/ours.txt" > "$T/leaked.txt"
[ ! -s "$T/leaked.txt" ] || { cat "$T/leaked.txt" >&2; fail "exports Recaulk names"; }

"$OTOOL" -L "$OURS" | sed 1d > "$T/L.txt"
echo "== macFUSE"; cat "$T/L.txt"
grep -q '/usr/lib/swift/' "$T/L.txt" && fail "links a /usr/lib/swift library"
"$OTOOL" -l "$OURS" | grep -q LC_RPATH && fail "has an LC_RPATH (upstream's is /usr/lib/swift)"
grep -qF "/usr/local/lib/libfuse.2.dylib (compatibility version 12.0.0, current version 12.9.0)" "$T/L.txt" || fail "does not link /usr/local/lib/libfuse.2.dylib at 12.0.0/12.9.0"
"$OTOOL" -D "$OURS" | sed 1d > "$T/id.txt"
[ "$(cat "$T/id.txt")" = "$INSTALL" ] || fail "install name is $(cat "$T/id.txt"), not $INSTALL"
"$OTOOL" -l "$OURS" | awk '/cmd LC_ID_DYLIB/ { id = 1 } id && /current version/ { c = $3 } id && /compatibility version/ { k = $3; id = 0 } END { print k, c }' > "$T/ver.txt"
[ "$(cat "$T/ver.txt")" = "1.0.0 3.0.0" ] || fail "LC_ID_DYLIB compat/current are $(cat "$T/ver.txt"), not 1.0.0 3.0.0"
"$CL/bin/llvm-lipo" -info "$OURS" | sed -n 's/.*: //p' | xargs > "$T/archs.txt"
[ "$(cat "$T/archs.txt")" = x86_64 ] || fail "architectures are $(cat "$T/archs.txt"), not x86_64"

PL="$FW/Versions/A/Resources/Info.plist"
v="$(upstream_version)"
for kv in CFBundleIdentifier=io.macfuse.frameworks.macfuse CFBundleExecutable=macFUSE CFBundleName=macFUSE \
          CFBundlePackageType=FMWK CFBundleShortVersionString="$v" CFBundleVersion="$v" LSMinimumSystemVersion=10.9; do
  k=${kv%%=*}; want=${kv#*=}
  got="$(awk -v k="<key>$k</key>" 'index($0, k) { getline; gsub(/^[ \t]*<string>|<\/string>[ \t]*$/, ""); print; exit }' "$PL")"
  [ "$got" = "$want" ] || fail "Info.plist $k is '$got', not '$want'"
done
for n in Headers macFUSE Modules Resources; do
  [ "$(readlink "$FW/$n" 2> /dev/null)" = "Versions/Current/$n" ] || fail "$n is not a link to Versions/Current/$n"
done
[ "$(readlink "$FW/Versions/Current" 2> /dev/null)" = A ] || fail "Versions/Current is not a link to A"
(cd "$UPFW/Versions/A/Headers" && ls) > "$T/up-h.txt"
(cd "$FW/Versions/A/Headers" && ls) > "$T/ours-h.txt" 2> /dev/null || :
diff "$T/up-h.txt" "$T/ours-h.txt" > "$T/diff.txt" || { cat "$T/diff.txt" >&2; fail "Headers are not upstream's set"; }
while read -r h; do
  cmp -s "$UPFW/Versions/A/Headers/$h" "$FW/Versions/A/Headers/$h" || fail "Headers/$h differs from upstream's"
done < "$T/up-h.txt"
cmp -s "$UPFW/Versions/A/Modules/module.modulemap" "$FW/Versions/A/Modules/module.modulemap" || fail "Modules/module.modulemap differs from upstream's"

EX="$T/ex/framework-fs"
if [ -f "$EX" ]; then
  "$OTOOL" -L "$EX" | grep -qF "$INSTALL (compatibility version 1.0.0, current version 3.0.0)" || fail "framework-fs does not link $INSTALL at 1.0.0/3.0.0"
else
  fail "no example framework-fs"
fi

sh "$REPO_ROOT/build/compat-guard.sh" --default "$OURS" || fail "the default compat guard failed on macFUSE"
strict_measure "$OURS" "$T/strict.txt" || fail "the strict compat guard failed on macFUSE"

[ "$fails" -eq 0 ] || exit 1
echo "framework-exports-test: PASS"
