#!/bin/sh
# platform: host-agnostic
# spec: 2026-11-19-macfuse-product/task-8-brief.md Steps 1 and 4 -- build/retarget-kext.sh on upstream's real debug tbz with a Recaulk
#       root fixture: a thin x86_64 kext whose Mach-O is Drydock's golden output (271 undefined symbols, none _vnop_renamex_desc;
#       4 relocations to _vnop_rename_desc) and whose OSBundleLibraries is exactly the five 10.9 KPIs plus the back-fill at its
#       OSBundleCompatibleVersion. An upstream plist naming com.apple.kpi.private loses it; a second run of the recipe on the
#       output fails. SKIPs (77) without MACFUSE_DEBUG_TBZ.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/.." && pwd)}"
export REPO_ROOT
. "$REPO_ROOT/build/lib.sh"
. "$REPO_ROOT/build/msc.sh"
fails=0
fail() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }
GOLDEN=73300026cc73eeef324774c9dd2e44dee4b4799566e7b1f61d38016d6f94e836

[ "$(cat "$REPO_ROOT/kext/macfuse.drydock")" = "$(printf 'arch x86_64\nvnodeop replace _vnop_renamex_desc _vnop_rename_desc')" ] ||
  fail "kext/macfuse.drydock is not exactly 'arch x86_64' and 'vnodeop replace _vnop_renamex_desc _vnop_rename_desc'"

TBZ="${MACFUSE_DEBUG_TBZ:-}"
if [ -z "$TBZ" ] || [ ! -f "$TBZ" ]; then
  [ "$fails" -eq 0 ] || exit 1
  echo "SKIP: recipe passes; MACFUSE_DEBUG_TBZ unset or not a file"; exit 77
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/retarget-kext-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
CL="$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$REPO_ROOT/components/clang22")" || { echo "FAIL: no clang22" >&2; exit 1; }
DDP="$(sh "$SHIPYARD_SCRIPTS/fetch_drydock.sh" "$REPO_ROOT/components/drydock")" || { echo "FAIL: no Drydock" >&2; exit 1; }

RC="$T/recaulk"
mkdir -p "$RC/Library/Extensions/RecaulkTest.kext/Contents"
cat > "$RC/Library/Extensions/RecaulkTest.kext/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>dev.mavergreen.recaulk.test</string>
	<key>CFBundleVersion</key>
	<string>9.8.7</string>
	<key>OSBundleCompatibleVersion</key>
	<string>1.2.0</string>
	<key>OSBundleLibraries</key>
	<dict>
		<key>com.apple.kpi.bsd</key>
		<string>13.0.0</string>
	</dict>
</dict>
</plist>
EOF

# spec: task-8-brief.md Step 1 -- "libs PLIST" prints OSBundleLibraries as sorted id=version lines, read apart from the script's awk
libs() {
  awk '
    function inner(s, tag) { sub("^[ \t]*<" tag ">", "", s); sub("</" tag ">[ \t]*$", "", s); return s }
    in_libs && /^[ \t]*<\/dict>/ { exit }
    in_libs && /<key>/ { k = inner($0, "key"); next }
    in_libs && /<string>/ { print k "=" inner($0, "string"); next }
    /<key>OSBundleLibraries<\/key>/ { in_libs = 1 }' "$1" | sort
}
want_libs() {
  printf '%s\n' com.apple.kpi.bsd=13.0.0 com.apple.kpi.iokit=13.0.0 com.apple.kpi.libkern=13.0.0 com.apple.kpi.mach=13.0.0 \
    com.apple.kpi.unsupported=13.0.0 dev.mavergreen.recaulk.test=1.2.0 | sort
}
sha256() { if command -v shasum > /dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | awk '{ print $1 }'; }
V="$(upstream_version)"
MEMBER="macfuse-$V-debug/KernelExtension-12/macfuse.kext"
mkdir -p "$T/up"
tar -xjf "$TBZ" -C "$T/up" "$MEMBER/Contents/Info.plist" || { echo "FAIL: $TBZ holds no $MEMBER/Contents/Info.plist" >&2; exit 1; }
UP_VER="$(plist_string "$T/up/$MEMBER/Contents/Info.plist" CFBundleVersion)"

OUT="$T/out"
mkdir -p "$OUT/macfuse.kext/Contents/Resources"
echo stale > "$OUT/macfuse.kext/Contents/Resources/stale"
echo foreign > "$OUT/foreign.txt"
echo "== retarget-kext.sh"
sh "$REPO_ROOT/build/retarget-kext.sh" "$TBZ" "$RC" "$OUT" > "$T/run.log" 2>&1 || { cat "$T/run.log" >&2; echo "FAIL: retarget-kext.sh failed" >&2; exit 1; }
grep -v 'already extracted' "$T/run.log" || :
K="$OUT/macfuse.kext"
B="$K/Contents/MacOS/macfuse"
P="$K/Contents/Info.plist"
[ -f "$OUT/foreign.txt" ] || fail "retarget-kext.sh removed a file in OUTDIR that is not its own"
[ ! -e "$K/Contents/Resources" ] || fail "retarget-kext.sh kept a stale file in an earlier macfuse.kext"
(cd "$K" && find . | sort) > "$T/tree"
printf '%s\n' . ./Contents ./Contents/Info.plist ./Contents/MacOS ./Contents/MacOS/macfuse > "$T/tree.want"
diff "$T/tree.want" "$T/tree" > "$T/diff" || { cat "$T/diff" >&2; fail "macfuse.kext holds other than Contents/Info.plist and Contents/MacOS/macfuse"; }
[ -z "$(find "$OUT" -name '._*')" ] || fail "OUTDIR has ._* files"
[ -z "$(find "$OUT" -name '.macfuse.kext.*')" ] || fail "retarget-kext.sh left its scratch directory in OUTDIR"
for f in "$K" "$K/Contents" "$K/Contents/MacOS" "$B"; do [ "$(ls -ld "$f" | cut -c1-10)" = drwxr-xr-x ] || [ "$(ls -ld "$f" | cut -c1-10)" = -rwxr-xr-x ] || fail "$f is not mode 755"; done
[ "$(ls -l "$P" | cut -c1-10)" = -rw-r--r-- ] || fail "Info.plist is not mode 644"

archs="$("$CL/bin/llvm-lipo" -info "$B" | sed -n 's/.*: //p' | xargs)"
[ "$archs" = x86_64 ] || fail "the kext's architectures are '$archs', not x86_64"
got="$(sha256 "$B")"
[ "$got" = "$GOLDEN" ] || fail "the kext's Mach-O has sha256 $got, not Drydock's golden $GOLDEN"
"$CL/bin/llvm-nm" -u "$B" > "$T/nm"
[ "$(wc -l < "$T/nm" | tr -d ' ')" = 271 ] || fail "llvm-nm -u lists $(wc -l < "$T/nm" | tr -d ' ') symbols, not 271"
! grep -qx '_vnop_renamex_desc' "$T/nm" || fail "_vnop_renamex_desc is still undefined"
"$CL/bin/llvm-objdump" --macho -r "$B" > "$T/relocs"
[ "$(grep -c '_vnop_rename_desc$' "$T/relocs")" = 4 ] || fail "$(grep -c '_vnop_rename_desc$' "$T/relocs") relocations name _vnop_rename_desc, not 4"
! grep -q '_vnop_renamex_desc' "$T/relocs" || fail "a relocation still names _vnop_renamex_desc"
if "$DDP/bin/drydock-macho-rewrite" "$B" "$T/again" < "$REPO_ROOT/kext/macfuse.drydock" > "$T/again.log" 2>&1; then
  fail "a second run of kext/macfuse.drydock on the retargeted kext passed; it must match nothing and fail"
fi

echo "== OSBundleLibraries"
libs "$P" | tee "$T/libs"
want_libs > "$T/libs.want"
diff "$T/libs.want" "$T/libs" > "$T/diff" || { cat "$T/diff" >&2; fail "OSBundleLibraries is not the five 10.9 KPIs plus dev.mavergreen.recaulk.test 1.2.0"; }
! grep -q 'com\.apple\.kpi\.private' "$P" || fail "Info.plist names com.apple.kpi.private"
[ "$(plist_string "$P" CFBundleIdentifier)" = io.macfuse.filesystems.macfuse.21 ] || fail "CFBundleIdentifier is not io.macfuse.filesystems.macfuse.21"
[ -n "$UP_VER" ] && [ "$(plist_string "$P" CFBundleVersion)" = "$UP_VER" ] || fail "CFBundleVersion is not upstream's '$UP_VER'"
# platform: guarded macOS-only call -- command -v plutil, so a host without it skips the lint
if command -v plutil > /dev/null 2>&1; then plutil -lint "$P" > /dev/null || fail "plutil -lint rejects the rewritten Info.plist"; fi

echo "== an upstream plist naming com.apple.kpi.private"
X="$T/x"
mkdir -p "$X"
tar -xjf "$TBZ" -C "$X" "$MEMBER"
awk '{ print } /<key>com.apple.kpi.mach<\/key>/ { getline; print; print "\t\t<key>com.apple.kpi.private</key>"; print "\t\t<string>21.0.0</string>" }' \
  "$X/$MEMBER/Contents/Info.plist" > "$T/plist" && mv "$T/plist" "$X/$MEMBER/Contents/Info.plist"
grep -q 'com\.apple\.kpi\.private' "$X/$MEMBER/Contents/Info.plist" || fail "the fixture plist does not name com.apple.kpi.private"
(cd "$X" && tar -cjf "$T/private.tbz" "macfuse-$V-debug")
if sh "$REPO_ROOT/build/retarget-kext.sh" "$T/private.tbz" "$RC" "$T/out2" > "$T/run2.log" 2>&1; then
  ! grep -q 'com\.apple\.kpi\.private' "$T/out2/macfuse.kext/Contents/Info.plist" || fail "the output still names com.apple.kpi.private"
  libs "$T/out2/macfuse.kext/Contents/Info.plist" > "$T/libs2"
  diff "$T/libs.want" "$T/libs2" > "$T/diff" || { cat "$T/diff" >&2; fail "with com.apple.kpi.private upstream, OSBundleLibraries is not the expected six"; }
else
  cat "$T/run2.log" >&2; fail "retarget-kext.sh failed on a plist naming com.apple.kpi.private"
fi

echo "== a Recaulk root with no back-fill kext"
mkdir -p "$T/empty/Library/Extensions"
if sh "$REPO_ROOT/build/retarget-kext.sh" "$TBZ" "$T/empty" "$T/out3" > "$T/run3.log" 2>&1; then
  fail "retarget-kext.sh passed with no back-fill kext"
fi
[ ! -e "$T/out3/macfuse.kext" ] || fail "retarget-kext.sh wrote a kext with no back-fill kext"

[ "$fails" -eq 0 ] || exit 1
echo "retarget-kext-test: PASS"
