#!/bin/sh
# platform: host-agnostic
# spec: INGREDIENTS.md "Conformance deviations" objc-measure -- tests/lib/strict-measure.sh excuses only the findings
#       tests/lib/objc-measure.tsv lists for the binary at hand, no more often than listed, and only while INGREDIENTS.md
#       declares objc-measure for that binary, and only for the upstream tests/lib/goldens-upstream names (any other says
#       "refresh for upstream X.Y.Z"); everything else fails. case_ BINARY NAME WANT RC LINE... fakes
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
cp "$REAL/tests/lib/objc-measure.tsv" "$REAL/tests/lib/goldens-upstream" "$T/tests/lib/"
cp "$REAL/UPSTREAM_VERSION" "$T/UPSTREAM_VERSION"
for b in macFUSE libfuse.2.dylib libfuse3.4.dylib MFMount mount_macfuse; do : > "$T/bin/$b"; done
case_() {
  bin=$1 name=$2 want=$3 rc=$4; shift 4
  { echo '#!/bin/sh'; for l in "$@"; do printf "echo '%s' >&2\n" "$l"; done; echo "exit $rc"; } > "$T/build/compat-guard.sh"
  got=pass
  REPO_ROOT="$T" strict_measure "$T/bin/$bin" "$T/log" > /dev/null 2> "$T/err" || got=fail
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
case_ macFUSE latent-libfuse-dependency fail 4 "$EL" "$CM"
case_ macFUSE one-gap-closed fail 4 "$LW" "$I1" "$CM"
case_ macFUSE extra-indirect-site fail 4 "$LW" "$I1" "$I2" "$I1" "$CM"
SP='objc-compat: indirect-objc-entry: objc entry point spilled to a frame slot that a frame address escaped on some path may reach'
R13='objc-compat: indirect-objc-entry: objc entry point in r13 is spilled where another path left a different value'
RBP='objc-compat: indirect-objc-entry: objc entry point spilled to [rbp-7696] is read other than by a reload into a register'
spills() { i=0; while [ "$i" -lt "$1" ]; do printf '%s\n' "$SP"; i=$((i + 1)); done; }
mm_case() {
  n=$1 name=$2 want=$3; shift 3
  old_ifs=$IFS; IFS='
'
  # shellcheck disable=SC2046
  case_ mount_macfuse "$name" "$want" 4 $(spills "$n") "$@" "$CM"
  IFS=$old_ifs
}
mm_case 155 today pass "$R13" "$RBP"
mm_case 154 one-spill-fewer fail "$R13" "$RBP"
mm_case 156 one-spill-more fail "$R13" "$RBP"
mm_case 155 r13-gap-closed fail "$RBP"
case_ macFUSE mount_macfuse-s-spill fail 4 "$LW" "$I1" "$I2" "$SP" "$CM"
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
echo 0.0.1 > "$T/UPSTREAM_VERSION"
case_ macFUSE today-for-another-upstream fail 4 "$LW" "$I1" "$I2" "$CM"
grep -q 'refresh for upstream 0.0.1' "$T/err" ||
  { echo "FAIL: a mismatched upstream does not say 'refresh for upstream 0.0.1'" >&2; fails=$((fails + 1)); }
case_ macFUSE clean-for-another-upstream pass 0 'compat guard: 1 binaries clean'
cp "$REAL/UPSTREAM_VERSION" "$T/UPSTREAM_VERSION"
grep -v '^- objc-measure:macFUSE:' "$REAL/INGREDIENTS.md" > "$T/INGREDIENTS.md"
case_ macFUSE undeclared fail 4 "$LW" "$I1" "$I2" "$CM"
case_ libfuse.2.dylib others-still-declared pass 4 "$EM" "$CM"
[ "$fails" -eq 0 ] || exit 1
echo "strict-measure-test: PASS (27 cases)"
