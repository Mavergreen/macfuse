#!/bin/sh
# platform: macOS-only -- moves kexts aside and mounts on a Mac OS X 10.9 guest (the acceptance job's Scenario A, CI only)
# spec: 2026-11-18-macfuse-design.md decision D and task-11-report.md "Fix round 1" (4) -- the adapted mount_macfuse's
#       CF alert path, reached only when load_macfuse fails: with nothing loaded,
#       (a) /Library/Extensions/RecaulkKPI.kext moved aside: kextd cannot resolve the kext's dependency, load_macfuse
#           prints "kext load failed" and exits 255, and mount_macfuse reports "the file system is not available (255)";
#       (b) the tree's Extensions/10/macfuse.kext moved aside: KextManagerLoadKextWithURL says not found, load_macfuse
#           exits 2, and mount_macfuse posts CFUserNotificationDisplayNotice before "the file system is not available (2)".
#       Each must end non-zero within the watchdog (a notice never waits for a click; a blocking alert would hang here and
#       fail), mount nothing, and leave no new crash report. Both are put back on any exit, and a mount then works again.
#   usage: MACFUSE_ALERT_PATH=1 alert-path.sh BINDIR
#          BINDIR holds hello3. MACFUSE_ALERT_PATH=1 says this guest may have its kexts moved: the job's disposable one,
#          or a hand-test box. Needs passwordless sudo. Exits 77 without MACFUSE_ALERT_PATH=1 or off 10.9.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/../.." && pwd)}"
. "$HERE/lib.sh"
case "$(sw_vers -productVersion 2>/dev/null)" in 10.9*) ;; *) echo "not Mac OS X 10.9 -- skipping"; exit 77 ;; esac
[ "${MACFUSE_ALERT_PATH:-0}" = 1 ] || { echo "alert-path: moves kexts aside; set MACFUSE_ALERT_PATH=1 on a guest where that is fine -- skipping"; exit 77; }
[ $# -eq 1 ] || { echo "usage: MACFUSE_ALERT_PATH=1 $0 BINDIR" >&2; exit 2; }
BIN="$(cd "$1" && pwd)" || { echo "alert-path: no $1" >&2; exit 2; }
[ -x "$BIN/hello3" ] || { echo "alert-path: no $BIN/hello3" >&2; exit 2; }
sudo -n true 2>/dev/null || { echo "alert-path: needs passwordless sudo" >&2; exit 1; }
cleanup_on_exit
mkdir -p "$SMOKE_LOGS"
KPI=/Library/Extensions/RecaulkKPI.kext
KEXT="$MACFUSE_PREFIX/fs/Contents/Extensions/10/macfuse.kext"
ASIDE=/private/var/tmp/macfuse-alert-path.aside
M=/private/tmp/macfuse-smoke/mnt/alert-path
mkdir -p "$M"
track_mount "$M"
[ -d "$KPI" ] && [ -d "$KEXT" ] || fail "need both $KPI and $KEXT in place"
[ ! -e "$ASIDE" ] || fail "$ASIDE exists: an earlier run did not put its kexts back; restore them by hand first"
put_back() {
  [ -d "$ASIDE/RecaulkKPI.kext" ] && sudo -n mv "$ASIDE/RecaulkKPI.kext" "$KPI"
  [ -d "$ASIDE/macfuse.kext" ] && sudo -n mv "$ASIDE/macfuse.kext" "$KEXT"
  sudo -n rmdir "$ASIDE" 2>/dev/null
  sudo -n touch /Library/Extensions
}
CLEAN_HOOK='put_back'
mount | grep -q -e '(macfuse' -e '(osxfuse' && fail "a FUSE volume is mounted; the kexts cannot be unloaded"
for id in io.macfuse.filesystems.macfuse.21 dev.mavergreen.recaulk.kpi; do
  i=0
  while kext_loaded "$id" && [ "$i" -lt 10 ]; do bounded 60 sudo -n kextunload -b "$id" > /dev/null 2>&1 || sleep 1; i=$((i + 1)); done
  kext_loaded "$id" && fail "$id would not unload"
done
sudo -n mkdir -p "$ASIDE" || fail "mkdir $ASIDE"
crashes() { for c in mount_macfuse load_macfuse hello3; do crash_reports "$c"; done | wc -l | tr -d ' '; }

try_mount() {  # LABEL EXPECTED-CODE
  before="$(crashes)"
  log="$SMOKE_LOGS/alert-path-$1.log"
  bounded 120 "$BIN/hello3" "$M" -f > "$log" 2>&1
  rc=$?
  if [ "$rc" -eq 124 ]; then
    pkill -9 -U "$(id -u)" mount_macfuse 2>/dev/null
    fail "$1: the mount hung for 120 s (an alert waiting for a click?)"
  fi
  [ "$rc" -ne 0 ] && [ "$rc" -lt 128 ] || fail "$1: hello3 exited $rc"
  grep -q "mount_macfuse: the file system is not available ($2)" "$log" || fail "$1: mount_macfuse did not say 'the file system is not available ($2)'"
  is_mounted "$M" && fail "$1: a volume was mounted"
  sleep 10
  [ "$(crashes)" -eq "$before" ] || fail "$1: a new crash report"
  kext_loaded io.macfuse.filesystems.macfuse.21 && fail "$1: the macfuse kext loaded anyway"
  ok "$1: hello3 exit $rc, $(grep -m1 '^mount_macfuse: ' "$log"), no volume, no crash report"
}

echo "== (a) RecaulkKPI.kext aside: the kext's dependency is missing"
sudo -n mv "$KPI" "$ASIDE/RecaulkKPI.kext" && sudo -n touch /Library/Extensions || fail "moving $KPI aside"
try_mount recaulk-kpi-aside 255
grep -q "kext load failed" "$SMOKE_LOGS/alert-path-recaulk-kpi-aside.log" || fail "load_macfuse did not say 'kext load failed'"
sudo -n mv "$ASIDE/RecaulkKPI.kext" "$KPI" && sudo -n touch /Library/Extensions || fail "putting $KPI back"

echo "== (b) macfuse.kext aside: load_macfuse exits 2, and mount_macfuse posts its CFUserNotification"
sudo -n mv "$KEXT" "$ASIDE/macfuse.kext" || fail "moving $KEXT aside"
try_mount macfuse-kext-aside 2
sudo -n mv "$ASIDE/macfuse.kext" "$KEXT" || fail "putting $KEXT back"
sudo -n rmdir "$ASIDE"

echo "== both back: a mount works again"
sleep 10
"$BIN/hello3" "$M" -f > "$SMOKE_LOGS/alert-path-after.log" 2>&1 &
H=$!
track_pid "$H"
wait_mounted "$M" 60 "$H"
[ "$(bounded 30 cat "$M/hello")" = "Hello World!" ] || fail "reading hello3 after the kexts were put back"
umount_mp "$M"
wait_exit "$H" 30 || fail "hello3 did not exit"
ok "alert path: both failures end cleanly, and the kexts load again once back"
