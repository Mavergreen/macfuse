#!/bin/sh
# platform: host-agnostic
# spec: 2026-11-19-macfuse-product/task-8-brief.md Step 2 -- build/compare-kexts.sh on fixtures linked here with clang22: two identical
#       Mach-O files pass, as kext bundles too; one byte changed in __TEXT,__text fails naming that section; a different UUID
#       (a copy with one LC_UUID byte changed) fails naming the UUID, and only it
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/.." && pwd)}"
export REPO_ROOT
. "$REPO_ROOT/build/lib.sh"
. "$REPO_ROOT/build/msc.sh"
fails=0
fail() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }
T="$(mktemp -d "${TMPDIR:-/tmp}/compare-kexts-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
CL="$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$REPO_ROOT/components/clang22")" || { echo "FAIL: no clang22" >&2; exit 1; }
printf '%s\n' 'int f(int x) { return x * 3 + 1; }' 'int g[4] = { 1, 2, 3, 4 };' > "$T/a.c"
"$CL/bin/clang" --no-default-config --target=x86_64-apple-macos10.9 -fuse-ld=lld -nostdlib -dynamiclib -o "$T/a" "$T/a.c" ||
  { echo "FAIL: cannot link the fixture" >&2; exit 1; }
cp "$T/a" "$T/same"
# spec: <mach-o/loader.h> -- load commands follow the 32-byte mach_header_64; LC_UUID's 16 bytes follow its cmd and cmdsize
uoff="$("$CL/bin/llvm-otool" -l "$T/a" | awk 'BEGIN { o = 32 } $1 == "cmd" { c = $2 } $1 == "cmdsize" { if (c == "LC_UUID") { print o + 8; exit } o += $2 }')"
[ -n "$uoff" ] || { echo "FAIL: no LC_UUID in the fixture" >&2; exit 1; }
cp "$T/a" "$T/u"
printf '\377' | dd of="$T/u" bs=1 seek="$uoff" conv=notrunc 2> /dev/null
cmp -s "$T/a" "$T/u" && { echo "FAIL: the UUID change did not take" >&2; exit 1; }

cp "$T/a" "$T/text"
off="$("$CL/bin/llvm-otool" -l "$T/text" | awk '$1 == "sectname" { s = $2 } $1 == "segname" { g = $2 } s == "__text" && g == "__TEXT" && $1 == "offset" { print $2; exit }')"
[ -n "$off" ] || { echo "FAIL: no __TEXT,__text offset in the fixture" >&2; exit 1; }
printf '\314' | dd of="$T/text" bs=1 seek="$off" conv=notrunc 2> /dev/null
cmp -s "$T/a" "$T/text" && { echo "FAIL: the byte change did not take" >&2; exit 1; }

kext() {
  mkdir -p "$2/Contents/MacOS"
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<plist version="1.0">' '<dict>' '	<key>CFBundleExecutable</key>' \
    '	<string>fx</string>' '</dict>' '</plist>' > "$2/Contents/Info.plist"
  cp "$1" "$2/Contents/MacOS/fx"
}
kext "$T/a" "$T/a.kext"
kext "$T/same" "$T/same.kext"

run() { sh "$REPO_ROOT/build/compare-kexts.sh" "$1" "$2" > "$T/out" 2>&1; }
run "$T/a" "$T/same" || { cat "$T/out" >&2; fail "identical fixtures do not compare equal"; }
grep -q 'compare-kexts: identical' "$T/out" || fail "identical fixtures: no 'identical' line"
run "$T/a.kext" "$T/same.kext" || { cat "$T/out" >&2; fail "identical kext bundles do not compare equal"; }

rc=0; run "$T/a" "$T/text" || rc=$?
[ "$rc" = 1 ] || { cat "$T/out" >&2; fail "a changed __TEXT,__text byte: exit $rc, not 1"; }
grep -q 'section __TEXT,__text differs' "$T/out" || { cat "$T/out" >&2; fail "a changed __TEXT,__text byte is not named"; }
grep -q 'UUIDs differ' "$T/out" && fail "a changed __TEXT,__text byte is reported as a UUID difference"

rc=0; run "$T/a" "$T/u" || rc=$?
[ "$rc" = 1 ] || { cat "$T/out" >&2; fail "a different UUID: exit $rc, not 1"; }
grep -q 'x86_64: the UUIDs differ' "$T/out" || { cat "$T/out" >&2; fail "a different UUID is not named"; }
grep -q 'section .* differs' "$T/out" && { cat "$T/out" >&2; fail "the other-UUID fixture differs in a section too; it must differ in its UUID only"; }

rc=0; sh "$REPO_ROOT/build/compare-kexts.sh" "$T/a" > /dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "one argument: exit $rc, not 2"

[ "$fails" -eq 0 ] || exit 1
echo "compare-kexts-test: PASS"
