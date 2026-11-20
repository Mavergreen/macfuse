#!/bin/sh
# platform: macOS-only -- the generated preinstall's own part reads manifests with /usr/libexec/PlistBuddy
# spec: packaging/preinstall-hook.sh -- the takeover and its uninstall hook, against a fake volume and
#       stubs for pkgutil, mount, kextstat, kextunload, launchctl and sw_vers on PATH. The preinstall stage_product.sh generates
#       with build/package.sh's hook runs on a fake volume (never the boot volume); the boot-volume steps run the same hook,
#       with its OS version and file steps answered by the test, under stubs that change nothing (rm and rmdir included). Upstream
#       4.0.5's two receipts are tests/takeover/*-4.0.5.types, read from a real install (f file, d directory, l link).
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/.." && pwd)}"
export REPO_ROOT
. "$REPO_ROOT/build/lib.sh"
. "$REPO_ROOT/build/msc.sh"
fails=0
fail() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/takeover-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
TK="$T"; export TK
CORE=io.macfuse.installer.components.core
PANE=io.macfuse.installer.components.preferencepane
SSHFS=io.macfuse.installer.components.sshfs
KEXT_ID=io.macfuse.filesystems.macfuse.21

mkdir -p "$T/bin" "$T/sandbin" "$T/receipts"
cat > "$T/bin/pkgutil" <<'EOF'
#!/bin/sh
echo "pkgutil $*" >> "$TK/calls"
[ "$1" = --volume ] || { echo "stub pkgutil: no --volume" >&2; exit 2; }
r="$TK/receipts/$4.types"
[ -f "$r" ] || { echo "No receipt for '$4' found at '$2'." >&2; exit 1; }
case "$3" in
  --pkg-info)
    if [ -f "$TK/pkgutil-fail-info" ]; then echo "pkgutil: cannot read the receipt database" >&2; exit 1; fi
    printf 'package-id: %s\nversion: 4.0.5\nvolume: %s\nlocation: /\ninstall-time: 1\n' "$4" "$2" ;;
  --files)
    if [ -f "$TK/pkgutil-fail-files" ]; then sed 's/^[dfl] //; s/ -> .*$//' "$r" | head -n 3; exit 1; fi
    sed 's/^[dfl] //; s/ -> .*$//' "$r" ;;
  --forget) /bin/rm -f "$r"; echo "Forgot package '$4' on '$2'." ;;
  *) exit 2 ;;
esac
EOF
cat > "$T/bin/mount" <<'EOF'
#!/bin/sh
echo "mount $*" >> "$TK/calls"
printf '/dev/disk1s2 on / (hfs, local, journaled)\ndevfs on /dev (devfs, local, nobrowse)\n'
cat "$TK/mounts" 2>/dev/null || :
EOF
cat > "$T/bin/kextstat" <<'EOF'
#!/bin/sh
echo "kextstat $*" >> "$TK/calls"
echo 'Index Refs Address            Size       Wired      Name (Version) <Linked Against>'
echo '    1   83 0xffffff7f80736000 0x9e48     0x9e48     com.apple.kpi.bsd (13.4.0)'
cat "$TK/kextstat" 2>/dev/null || :
EOF
cat > "$T/bin/kextunload" <<'EOF'
#!/bin/sh
echo "kextunload $*" >> "$TK/calls"
exit "$(cat "$TK/kextunload.rc" 2>/dev/null || echo 0)"
EOF
for s in launchctl sw_vers; do printf '#!/bin/sh\necho "%s $*" >> "$TK/calls"\nexit 1\n' "$s" > "$T/bin/$s"; done
for s in rm rmdir; do printf '#!/bin/sh\necho "%s $*" >> "$TK/calls"\n' "$s" > "$T/sandbin/$s"; done
chmod 755 "$T"/bin/* "$T"/sandbin/*
LOADED="  130    0 0xffffff7f82b3a000 0x1a000    0x1a000    $KEXT_ID (5.5.0) <7 5 4 3 1>"

mkvol() { # VOL VERSION
  /bin/rm -rf "$1"; mkdir -p "$1/System/Library/CoreServices"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n\t<key>ProductBuildVersion</key>\n\t<string>13F1911</string>\n\t<key>ProductVersion</key>\n\t<string>%s</string>\n</dict>\n</plist>\n' \
    "$2" > "$1/System/Library/CoreServices/SystemVersion.plist"
  /bin/rm -f "$T"/receipts/* "$T/mounts" "$T/kextstat" "$T/kextunload.rc" "$T/pkgutil-fail-info" "$T/pkgutil-fail-files"
  : > "$T/calls"
}
receipt() { # VOL ID TYPES -- lays TYPES out on VOL, and records it as ID's receipt
  cp "$3" "$T/receipts/$2.types"
  while read -r k p a t; do
    case "$k" in
      d) mkdir -p "$1/$p" ;;
      f) mkdir -p "$1/$(dirname "$p")"; echo "$p" > "$1/$p" ;;
      l) mkdir -p "$1/$(dirname "$p")"; ln -s "$t" "$1/$p" ;;
    esac
  done < "$3"
}
snapshot() { (cd "$1" && find . -print | sort && find . -type l | sort | while read -r l; do echo "$l -> $(readlink "$l")"; done); }
called() { grep -q "^$1" "$T/calls"; }

macfuse_preinstall_hook "$T/hook.sh"
[ "$(tail -n 1 "$T/hook.sh")" = macfuse_takeover ] || fail "the composed hook does not end by calling macfuse_takeover"
mkdir -p "$T/st$MACFUSE_PREFIX"; echo x > "$T/st$MACFUSE_PREFIX/file"
sh "$SHIPYARD_SCRIPTS/stage_product.sh" --stage "$T/st" --product macfuse --name "Mavericks macFUSE" \
  --version "$(upstream_version)-mavericks.1" --preinstall-hook "$T/hook.sh" --scripts-out "$T/scripts" > "$T/sp.log" 2>&1 ||
  { cat "$T/sp.log" >&2; echo "FAIL: stage_product.sh refused the hook" >&2; exit 1; }
V="$T/Macintosh HD"
preinstall() { # the generated preinstall, as Installer runs it on the fake volume
  case "$V" in ''|/) echo "takeover-test: refusing to run a preinstall on '$V'" >&2; exit 1 ;; esac
  rc=0; PATH="$T/bin:$PATH" sh "$T/scripts/preinstall" "$T/x.pkg" "$V" "$V" > "$T/out" 2>&1 || rc=$?
}
refuses() { # WHAT SAYS... -- the preinstall fails, says each SAYS, and changes nothing on the volume
  w=$1; shift
  snapshot "$V" > "$T/before"
  preinstall
  [ "$rc" -ne 0 ] || fail "$w: the preinstall succeeded"
  for s in "$@"; do grep -qF -- "$s" "$T/out" || { cat "$T/out" >&2; fail "$w: does not say: $s"; }; done
  snapshot "$V" > "$T/after"
  cmp -s "$T/before" "$T/after" || { diff "$T/before" "$T/after" >&2 || :; fail "$w: the volume changed"; }
  if called "pkgutil --volume [^ ]* --forget"; then fail "$w: a receipt was forgotten"; fi
}

mkvol "$V" 10.9.5
preinstall
[ "$rc" -eq 0 ] || { cat "$T/out" >&2; fail "a clean 10.9 volume is refused"; }

mkvol "$V" 10.10.5
refuses "10.10" "installs only on Mac OS X 10.9" "10.10.5" "https://macfuse.github.io"

mkvol "$V" 10.9.5
mkdir -p "$V/usr/local/lib"; echo foreign > "$V/usr/local/lib/libfuse.2.dylib"
refuses "an unaccounted libfuse.2.dylib" "  /usr/local/lib/libfuse.2.dylib" "Move them aside"

if grep -q "osxfuse 3" "$T/out"; then fail "an unaccounted libfuse.2.dylib, with no osxfuse 3 installed, is blamed on osxfuse 3"; fi

printf '%s\n' 'd Library/Filesystems/osxfuse.fs' 'd Library/Filesystems/osxfuse.fs/Contents' 'f Library/Filesystems/osxfuse.fs/Contents/Info.plist' \
  'd Library/Frameworks/OSXFUSE.framework' 'd Library/Frameworks/OSXFUSE.framework/Versions' \
  'd Library/Frameworks/OSXFUSE.framework/Versions/A' 'f Library/Frameworks/OSXFUSE.framework/Versions/A/OSXFUSE' \
  'd usr' 'd usr/local' 'd usr/local/lib' 'f usr/local/lib/libosxfuse.2.dylib' \
  'l usr/local/lib/libosxfuse_i64.2.dylib -> libosxfuse.2.dylib' > "$T/osxfuse3.types"
OSXFUSE3_SAYS="osxfuse 3|  /Library/Frameworks/OSXFUSE.framework/Versions/A/OSXFUSE|  /usr/local/lib/libosxfuse.2.dylib|  /usr/local/lib/libosxfuse_i64.2.dylib|Uninstall osxfuse 3 first|pkgutil --only-files --files ID|sudo pkgutil --forget ID"
mkvol "$V" 10.9.5
receipt "$V" com.github.osxfuse.pkg.Core "$T/osxfuse3.types"
old_ifs=$IFS; IFS='|'
# shellcheck disable=SC2086
refuses "osxfuse 3, by its receipt" $OSXFUSE3_SAYS
IFS=$old_ifs
[ -f "$V/usr/local/lib/libosxfuse.2.dylib" ] || fail "osxfuse 3, by its receipt: its libosxfuse.2.dylib is gone"
mkvol "$V" 10.9.5
receipt "$V" com.github.osxfuse.pkg.Core "$T/osxfuse3.types"
/bin/rm -f "$T/receipts/com.github.osxfuse.pkg.Core.types"
IFS='|'
# shellcheck disable=SC2086
refuses "osxfuse 3, by its osxfuse.fs alone" $OSXFUSE3_SAYS
IFS=$old_ifs
if grep -q "files no macFUSE installer receipt accounts for" "$T/out"; then fail "the osxfuse 3 refusal also gives the generic one"; fi

mkvol "$V" 10.9.5
mkdir -p "$V/usr/local/include"; ln -s /opt/elsewhere/fuse.h "$V/usr/local/include/fuse.h"
refuses "a link that is not ours" "  /usr/local/include/fuse.h"

mkvol "$V" 10.9.5
receipt "$V" "$CORE" "$REPO_ROOT/tests/takeover/core-4.0.5.types"
echo mine > "$V/usr/local/include/fuse/extra.h"
refuses "a file no receipt lists, inside upstream's include/fuse" "  /usr/local/include/fuse/extra.h"
if grep -q "  /usr/local/include/fuse\$" "$T/out"; then fail "a receipt-listed directory is reported as unaccounted"; fi
mkdir -p "$V/usr/local/include/fuse/empty"
refuses "an empty directory no receipt lists, inside upstream's include/fuse" "  /usr/local/include/fuse/empty"

mkvol "$V" 10.9.5
while read -r p t; do mkdir -p "$V/$(dirname "$p")"; ln -s "$MACFUSE_PREFIX/$t" "$V/$p"; done <<EOF
$MACFUSE_LINKS
EOF
snapshot "$V" | grep -- ' -> ' > "$T/ours.before"
echo "$LOADED" > "$T/kextstat"
preinstall
[ "$rc" -eq 0 ] || { cat "$T/out" >&2; fail "our own previous version's links are treated as unaccounted"; }
snapshot "$V" | grep -- ' -> ' > "$T/ours.after"
cmp -s "$T/ours.before" "$T/ours.after" || fail "the takeover changed our own previous version's links"

mkvol "$V" 10.9.5
receipt "$V" "$CORE" "$REPO_ROOT/tests/takeover/core-4.0.5.types"
receipt "$V" "$PANE" "$REPO_ROOT/tests/takeover/preferencepane-4.0.5.types"
printf 'd usr\nd usr/local\nd usr/local/bin\nf usr/local/bin/sshfs\nd usr/local/share/man/man1\nf usr/local/share/man/man1/sshfs.1\n' > "$T/sshfs.types"
receipt "$V" "$SSHFS" "$T/sshfs.types"
mkdir -p "$V/Library/Frameworks/Other.framework" "$V/Library/LaunchAgents" "$V/Library/LaunchDaemons"
echo other > "$V/Library/Frameworks/Other.framework/Other"; echo other > "$V/usr/local/lib/libother.dylib"
for j in LaunchAgents/io.macfuse.updater LaunchDaemons/io.macfuse.helper LaunchAgents/com.example.agent; do echo job > "$V/Library/$j.plist"; done
echo "$LOADED" > "$T/kextstat"
echo 'u@h:/ on /Volumes/live (macfuse, nodev, nosuid, synchronous, mounted by u)' > "$T/mounts"
preinstall
[ "$rc" -eq 0 ] || { cat "$T/out" >&2; fail "4.0.5 takeover: the preinstall failed"; }
cat "$REPO_ROOT"/tests/takeover/*-4.0.5.types | while read -r k p a t; do
  case "$k" in f|l) if [ -e "$V/$p" ] || [ -L "$V/$p" ]; then echo "$p"; fi ;; esac
done > "$T/left"
[ ! -s "$T/left" ] || fail "4.0.5 takeover left receipt-listed files: $(tr '\n' ' ' < "$T/left")"
for d in Library/Filesystems/macfuse.fs Library/Frameworks/macFUSE.framework Library/Frameworks/OSXFUSE.framework \
         Library/PreferencePanes/macFUSE.prefPane usr/local/include/fuse; do
  [ ! -e "$V/$d" ] || fail "4.0.5 takeover left the directory $d"
done
while read -r p t; do
  if [ -e "$V/$p" ] && [ ! -L "$V/$p" ]; then fail "4.0.5 takeover left /$p, where the payload puts a link"; fi
done <<EOF
$MACFUSE_LINKS
EOF
for k in usr/local/bin/sshfs usr/local/share/man/man1/sshfs.1 Library/Frameworks/Other.framework/Other usr/local/lib/libother.dylib \
         Library/LaunchAgents/com.example.agent.plist; do
  [ -f "$V/$k" ] || fail "4.0.5 takeover removed $k, which is not upstream macFUSE's"
done
for d in Library/Filesystems Library/Frameworks Library/PreferencePanes usr/local/lib/pkgconfig usr/local/include; do
  [ -d "$V/$d" ] || fail "4.0.5 takeover removed the shared directory $d"
done
[ -f "$T/receipts/$SSHFS.types" ] || fail "4.0.5 takeover forgot the sshfs receipt"
for id in "$CORE" "$PANE"; do
  [ ! -f "$T/receipts/$id.types" ] || fail "4.0.5 takeover did not forget $id"
  called "pkgutil --volume $V/ --forget $id" || fail "4.0.5 takeover did not forget $id on $V/"
done
for j in LaunchAgents/io.macfuse.updater LaunchDaemons/io.macfuse.helper; do
  [ ! -e "$V/Library/$j.plist" ] || fail "4.0.5 takeover left upstream's $j.plist"
done
if called kextunload; then fail "with ROOT=$V, the takeover called kextunload"; fi
if called launchctl; then fail "with ROOT=$V, the takeover called launchctl"; fi
if called mount; then fail "with ROOT=$V, the takeover read the boot volume's mounts"; fi
[ ! -e "$V$MACFUSE_PREFIX" ] || fail "the generated preinstall did not remove the tree after the hook"

# spec: packaging/lib-fuse-mounts.sh remove_upstream_receipts -- a pkgutil that fails, or lists only part of a receipt, stops the
#       takeover before anything is removed or forgotten
for flag in pkgutil-fail-files pkgutil-fail-info; do
  mkvol "$V" 10.9.5
  receipt "$V" "$CORE" "$REPO_ROOT/tests/takeover/core-4.0.5.types"
  : > "$T/$flag"
  refuses "$flag" "cannot read upstream macFUSE's receipts"
done

# spec: packaging/lib-fuse-mounts.sh remove_upstream_receipts -- a directory the takeover could not remove where a link goes stops it before the receipts are forgotten
mkvol "$V" 10.9.5
receipt "$V" "$CORE" "$REPO_ROOT/tests/takeover/core-4.0.5.types"
mkdir -p "$T/normdir"; printf '#!/bin/sh\n' > "$T/normdir/rmdir"; chmod 755 "$T/normdir/rmdir"
rc=0; PATH="$T/normdir:$T/bin:$PATH" sh "$T/scripts/preinstall" "$T/x.pkg" "$V" "$V" > "$T/out" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "the takeover succeeded although a real directory is left where a link goes"
grep -qxF "  /usr/local/include/fuse" "$T/out" || { cat "$T/out" >&2; fail "the takeover does not name the directory it could not clear"; }
[ -f "$T/receipts/$CORE.types" ] || fail "the takeover forgot the core receipt although it could not clear a link's path"

# spec: packaging/preinstall-hook.sh -- the mount refusal and the kext unload on the boot volume: the hook as composed, with ROOT empty and its OS version
#       answered by the test and every step that reads or writes the volume (tested above, on the fake volume) recorded
#       instead of run, so nothing here reaches this Mac's files; rm, rmdir, pkgutil, kextunload and launchctl are stubs as
#       well, and the call log must show no rm, rmdir or launchctl
sed '$d' "$T/hook.sh" > "$T/sand-hook.sh"
cat >> "$T/sand-hook.sh" <<'EOF'
target_macos_version() { echo 10.9.5; }
unaccounted_paths() { :; }
remove_upstream_receipts() { echo "remove_upstream_receipts $*" >> "$TK/calls"; }
remove_upstream_launchd() { echo "remove_upstream_launchd $*" >> "$TK/calls"; }
macfuse_takeover
EOF
{ printf 'ROOT=""\n(\n:\n'; cat "$T/sand-hook.sh"; printf '\n) || exit 1\nexit 0\n'; } > "$T/sand.sh"
sandbox() {
  rc=0; PATH="$T/sandbin:$T/bin:$PATH" sh "$T/sand.sh" > "$T/out" 2>&1 || rc=$?
  if grep -q '^rm\|^rmdir\|^launchctl' "$T/calls"; then fail "the boot-volume run reached a file or launchd step: $(grep '^rm\|^rmdir\|^launchctl' "$T/calls" | tr '\n' ';')"; fi
}
for m in 'u@h:/ on /Volumes/live one (macfuse, nodev, nosuid, synchronous, mounted by u)' \
         'u@gone:/x on /Volumes/dead (osxfuse, nodev, nosuid, synchronous, mounted by u)'; do
  mkvol "$V" 10.9.5
  printf '%s\n' "$m" > "$T/mounts"; echo "$LOADED" > "$T/kextstat"
  sandbox
  mp="${m#* on }"; mp="${mp% (*}"
  [ "$rc" -ne 0 ] || fail "a mounted volume ($mp) does not refuse the takeover"
  grep -qxF "  $mp" "$T/out" || { cat "$T/out" >&2; fail "the mount refusal does not list $mp"; }
  grep -qF "Unmount them" "$T/out" || fail "the mount refusal does not say to unmount them"
  for c in kextunload rm rmdir launchctl "pkgutil --volume / --forget"; do if called "$c"; then fail "a mount refusal ($mp) still ran $c"; fi; done
done
mkvol "$V" 10.9.5
echo "$LOADED" > "$T/kextstat"
sandbox
[ "$rc" -eq 0 ] || { cat "$T/out" >&2; fail "the boot-volume takeover failed with no mounts"; }
called "kextunload -b $KEXT_ID" || fail "the boot-volume takeover did not unload $KEXT_ID"
called "remove_upstream_launchd " || fail "the boot-volume takeover did not remove upstream's launchd jobs"
[ "$(grep -n '^kextunload' "$T/calls" | cut -d: -f1)" -lt "$(grep -n '^remove_upstream_receipts' "$T/calls" | cut -d: -f1)" ] 2>/dev/null ||
  fail "the boot-volume takeover did not unload the kext before removing upstream's files"
: > "$T/calls"; echo 1 > "$T/kextunload.rc"
sandbox
[ "$rc" -ne 0 ] || fail "a failed kextunload does not fail the takeover"
grep -qF "cannot unload $KEXT_ID" "$T/out" || fail "a failed kextunload is not reported"
if called remove_upstream_receipts; then fail "a failed kextunload still went on to remove upstream's files"; fi
if grep -q '^sw_vers' "$T/calls"; then fail "the takeover asked sw_vers, which describes the running system, not the target"; fi

# spec: packaging/pre-uninstall -- as installed beside its library
mkdir -p "$T/tree/libexec/mavergreen"
cp "$REPO_ROOT/packaging/pre-uninstall" "$REPO_ROOT/packaging/lib-fuse-mounts.sh" "$T/tree/libexec/mavergreen/"
pu() { rc=0; PATH="$T/bin:$PATH" "$T/tree/libexec/mavergreen/pre-uninstall" > "$T/out" 2>&1 || rc=$?; }
mkvol "$V" 10.9.5
echo 'u@h:/ on /Volumes/live (macfuse, nodev, nosuid, synchronous, mounted by u)' > "$T/mounts"; echo "$LOADED" > "$T/kextstat"
MAVERGREEN_ROOT=/; export MAVERGREEN_ROOT
pu
[ "$rc" -ne 0 ] || fail "pre-uninstall does not refuse while a FUSE volume is mounted"
grep -qxF "  /Volumes/live" "$T/out" || { cat "$T/out" >&2; fail "pre-uninstall does not list the mount"; }
grep -qF "sudo mavergreen uninstall macfuse" "$T/out" || fail "pre-uninstall's refusal does not say what to run after"
if called kextunload; then fail "pre-uninstall unloaded the kext while mounted"; fi
/bin/rm -f "$T/mounts"; : > "$T/calls"
pu
[ "$rc" -eq 0 ] || { cat "$T/out" >&2; fail "pre-uninstall fails with nothing mounted"; }
called "kextunload -b $KEXT_ID" || fail "pre-uninstall does not call kextunload -b $KEXT_ID"
echo "$LOADED" | sed "s/$KEXT_ID (5.5.0)/io.macfuse.filesystems.macfuse (4.0.5)/" >> "$T/kextstat"; : > "$T/calls"
pu
called "kextunload -b io.macfuse.filesystems.macfuse\$" || fail "pre-uninstall does not unload upstream 4.0.5's io.macfuse.filesystems.macfuse"
called "kextunload -b $KEXT_ID" || fail "pre-uninstall unloads upstream's kext but not ours"
echo "$LOADED" > "$T/kextstat"
echo 1 > "$T/kextunload.rc"
pu
[ "$rc" -ne 0 ] || fail "pre-uninstall succeeds although the kext would not unload"
/bin/rm -f "$T/kextunload.rc"; : > "$T/calls"
unset MAVERGREEN_ROOT
pu
called "kextunload -b $KEXT_ID" || fail "pre-uninstall with no MAVERGREEN_ROOT does not treat it as /"
echo 'u@h:/ on /Volumes/live (macfuse, nodev, nosuid, synchronous, mounted by u)' > "$T/mounts"; : > "$T/calls"
MAVERGREEN_ROOT=/Volumes/X; export MAVERGREEN_ROOT
pu
[ "$rc" -eq 0 ] || fail "pre-uninstall for another volume refuses"
[ ! -s "$T/calls" ] || fail "pre-uninstall for another volume ran: $(tr '\n' ';' < "$T/calls")"
unset MAVERGREEN_ROOT

[ "$fails" -eq 0 ] || { echo "takeover-test: $fails failure(s)" >&2; exit 1; }
echo "takeover-test: OK"
