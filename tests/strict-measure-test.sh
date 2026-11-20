#!/bin/sh
# platform: host-agnostic
# spec: INGREDIENTS.md "Conformance deviations" objc-measure -- tests/lib/strict-measure.sh excuses only the findings
#       tests/lib/objc-measure.tsv lists for the binary at hand, no more often than listed, and only while INGREDIENTS.md
#       declares objc-measure for that binary; everything else fails. case_ BINARY NAME WANT RC LINE... fakes
#       build/compat-guard.sh in a copy of the repo's INGREDIENTS.md and allowlist.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/.." && pwd)}"
. "$REPO_ROOT/build/lib.sh"
. "$REPO_ROOT/build/msc.sh"
. "$REPO_ROOT/tests/lib/strict-measure.sh"
REAL="$REPO_ROOT"
fails=0
T="$(mktemp -d "${TMPDIR:-/tmp}/strict-measure-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$T/build" "$T/tests/lib" "$T/bin"
cp "$REAL/INGREDIENTS.md" "$T/INGREDIENTS.md"
cp "$REAL/tests/lib/objc-measure.tsv" "$T/tests/lib/objc-measure.tsv"
for b in macFUSE libfuse.2.dylib libfuse3.4.dylib MFMount; do : > "$T/bin/$b"; done
case_() {
  bin=$1 name=$2 want=$3 rc=$4; shift 4
  { echo '#!/bin/sh'; for l in "$@"; do printf "echo '%s' >&2\n" "$l"; done; echo "exit $rc"; } > "$T/build/compat-guard.sh"
  got=pass
  REPO_ROOT="$T" strict_measure "$T/bin/$bin" "$T/log" > /dev/null 2>&1 || got=fail
  [ "$got" = "$want" ] || { echo "FAIL: $bin $name: $got, wanted $want" >&2; fails=$((fails + 1)); }
}
CM='compat guard CANNOT MEASURE (fail-closed): the Objective-C analyzer (objc-compat.sh) could not measure X (exit 4, said why above)'
LW='objc-compat: unclassified-objc-runtime-import: _objc_loadWeak'
I1='objc-compat: indirect-objc-entry: objc entry point in r12 is called through where another path left a different value'
I2='objc-compat: indirect-objc-entry: objc entry point in r12 is read other than to call through it (a spill, a copy or an escape)'
EL='objc-compat: escaping-dependency: /usr/local/lib/libfuse.2.dylib: a non-system path outside the shipped root'
EM='objc-compat: escaping-dependency: /Library/Filesystems/macfuse.fs/Contents/Frameworks/MFMount.framework/Versions/A/MFMount: a non-system path outside the shipped root'
case_ macFUSE clean pass 0 'compat guard: 1 binaries clean'
case_ macFUSE today pass 4 "$LW" "$I1" "$I2" "$CM"
case_ macFUSE its-libfuse pass 4 "$EL" "$CM"
case_ macFUSE extra-indirect-site fail 4 "$LW" "$I1" "$I2" "$I1" "$CM"
case_ macFUSE other-register fail 4 'objc-compat: indirect-objc-entry: objc entry point in rbx is called through where another path left a different value' "$CM"
case_ macFUSE new-absolute-dependency fail 4 "$EL" 'objc-compat: escaping-dependency: /usr/local/lib/libfoo.dylib: a non-system path outside the shipped root' "$CM"
case_ macFUSE libfuse-s-dependency fail 4 "$EM" "$CM"
case_ macFUSE other-import fail 4 "$LW" 'objc-compat: unclassified-objc-runtime-import: _objc_setAssociatedObject' "$CM"
case_ libfuse.2.dylib today pass 4 "$EM" "$CM"
case_ libfuse3.4.dylib today pass 4 "$EM" "$CM"
case_ libfuse.2.dylib macFUSE-s-loadweak fail 4 "$EM" "$LW" "$CM"
case_ libfuse.2.dylib macFUSE-s-indirect fail 4 "$I1" "$CM"
case_ libfuse.2.dylib macFUSE-s-dependency fail 4 "$EL" "$CM"
case_ MFMount any-gap fail 4 "$EM" "$CM"
case_ macFUSE no-finding fail 4 "$CM"
case_ macFUSE old-drydock fail 4 "compat-guard: shipyard at S pins Drydock 'v0.4.0'; the strict guard needs Drydock v0.5.0 or later (shipyard v1.0.736 or later)"
case_ macFUSE blocking fail 1 'compat guard: FAIL selector'
grep -v '^- objc-measure:macFUSE:' "$REAL/INGREDIENTS.md" > "$T/INGREDIENTS.md"
case_ macFUSE undeclared fail 4 "$LW" "$I1" "$I2" "$CM"
case_ libfuse.2.dylib others-still-declared pass 4 "$EM" "$CM"
[ "$fails" -eq 0 ] || exit 1
echo "strict-measure-test: PASS (19 cases)"
