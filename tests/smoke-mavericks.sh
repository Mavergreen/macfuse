#!/bin/sh
# platform: macOS-only -- loads the kext and mounts FUSE volumes on a real Mac OS X 10.9 box (the acceptance job's guest)
# spec: 2026-11-19-macfuse-product/task-11-brief.md Scenario A and 2026-11-18-macfuse-design.md "Proof" -- the installed
#       product on 10.9: the manifest is the run's version; /Library/Filesystems/macfuse.fs resolves into the tree; nothing is
#       preloaded, and the first mount's load_macfuse alone loads the kext and its Recaulk back-fill, whose vnode_notify
#       forwards once the mount is used; libfuse 3 and 2 hello, passthrough3 with tests/vm/ops.sh, the default-op test, the
#       Gate 0b probes (tests/vm/gate0b.sh), a macFUSE.framework file system, a binary built against upstream 4.0.5, an
#       unknown option given to libfuse and to mount_macfuse itself, mount_macfuse's failure and exit-notification path once,
#       a kill -9'd daemon's volume cleared by umount, and the MFMount device and osrelease shim tests. Any panic, hang or
#       new crash report fails it. On any exit it unmounts what it mounted and kills its daemons; on a failing one it also
#       unloads the kexts it loaded (tests/vm/lib.sh cleanup_on_exit).
#   usage: smoke-mavericks.sh VERSION BINDIR
#          VERSION is the run's version (the pkg installed). BINDIR holds hello2, hello3, passthrough3 and framework-fs
#          (build/build-libfuse.sh and build/build-framework.sh EXAMPLES), probe-fs and, when SMOKE_OLD_ABI=1, old-abi
#          (tests/vm/build-tests.sh). SMOKE_FRESH=0 skips the "nothing preloaded" check (a guest whose kexts already
#          loaded). SHIPYARD_SCRIPTS is needed for the MFMount device and osrelease shim tests. Run as the guest's user,
#          not root; passwordless sudo is used only to read system.log when it must.
#          Exits 77 where it cannot run (not 10.9, product not installed, no arguments); the job treats 77 as failure.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/.." && pwd)}"
export REPO_ROOT
case "$(sw_vers -productVersion 2>/dev/null)" in 10.9*) ;; *) echo "not Mac OS X 10.9 -- skipping"; exit 77 ;; esac
[ $# -eq 2 ] || { echo "usage: smoke-mavericks.sh VERSION BINDIR -- skipping"; exit 77; }
. "$REPO_ROOT/tests/vm/lib.sh"
cleanup_on_exit
[ -f "$MACFUSE_PREFIX/mavergreen.plist" ] || { echo "macFUSE for Mavericks is not installed -- skipping"; exit 77; }
VERSION=$1; BIN="$(cd "$2" && pwd)" || fail "no $2"
[ "$(id -u)" != 0 ] || fail "run this as the guest's user, not root: FUSE volumes are mounted by users"
W=/private/tmp/macfuse-smoke
mkdir -p "$SMOKE_LOGS" "$W/mnt" || fail "mkdir $W"
all_crashes() { for _c in mount_macfuse load_macfuse hello2 hello3 passthrough3 probe-fs framework-fs old-abi; do crash_reports "$_c"; done; }
CRASH0="$(all_crashes | wc -l | tr -d ' ')"
for e in hello2 hello3 passthrough3 framework-fs probe-fs; do [ -x "$BIN/$e" ] || fail "no $BIN/$e"; done
[ "${SMOKE_OLD_ABI:-0}" = 0 ] || [ -x "$BIN/old-abi" ] || fail "SMOKE_OLD_ABI=1 and no $BIN/old-abi"
syslog_lines() { wc -l < /var/log/system.log 2>/dev/null || sudo -n wc -l < /var/log/system.log; }
syslog_since() { { tail -n +"$(($1 + 1))" /var/log/system.log 2>/dev/null || sudo -n tail -n +"$(($1 + 1))" /var/log/system.log; } | grep -F "$2"; }
LOG0="$(syslog_lines)"
ALL_MOUNTS=""
# spec: tests/vm/lib.sh -- every daemon runs in the foreground (-f) in the background, so the test owns its pid: libfuse
#       refuses to fork once mounted, and a hang must be a bounded wait here, never a stuck job. A mount point already in
#       use, or a daemon gone once its volume appears, fails at once: a stale volume must never answer for a new daemon.
start_fs() {  # NAME MOUNTPOINT ARGS... ; sets FS_PID and FS_LOG
  _n=$1; _m=$2; shift 2
  mkdir -p "$_m" || fail "mkdir $_m"
  is_mounted "$_m" && fail "$_m is already mounted before $_n starts"
  FS_LOG="$SMOKE_LOGS/$_n.log"
  "$BIN/$_n" "$_m" -f "$@" > "$FS_LOG" 2>&1 &
  FS_PID=$!
  track_pid "$FS_PID"; track_mount "$_m"
  ALL_MOUNTS="$ALL_MOUNTS $_m"
  wait_mounted "$_m" 30 "$FS_PID"
  kill -0 "$FS_PID" 2>/dev/null || fail "$_n (pid $FS_PID) is gone, though $_m is mounted"
}
stop_fs() {  # MOUNTPOINT PID LOG
  umount_mp "$1"
  wait_exit "$2" 30 || fail "the daemon of $1 did not exit after umount"
  # spec: tests/vm/lib.sh FORK_WARNING -- one mount, so at most one: the multithreaded loop's mount fork
  [ "$(fork_warnings "$3")" -le 1 ] || fail "$3 has $(fork_warnings "$3") fork warnings for one mount"
}

echo "== the install"
v="$(manifest_version "$MACFUSE_PREFIX")"
[ "$v" = "$VERSION" ] || fail "the installed manifest says '$v', not $VERSION"
ok "manifest version $v"
[ "$(cd -P /Library/Filesystems/macfuse.fs && pwd -P)" = "$MACFUSE_PREFIX/fs" ] ||
  fail "/Library/Filesystems/macfuse.fs does not resolve to $MACFUSE_PREFIX/fs"
for h in mount_macfuse load_macfuse; do
  [ "$(stat -f '%Su:%Sg %Sp' "$MACFUSE_PREFIX/fs/Contents/Resources/$h")" = "root:wheel -rwsr-xr-x" ] || fail "$h is not root:wheel 4755"
done
ok "/Library/Filesystems/macfuse.fs resolves into the tree; the helpers are setuid root"
if [ "${SMOKE_FRESH:-1}" = 1 ]; then
  kextstat | grep -q -e recaulk -e macfuse && fail "a FUSE or Recaulk kext is loaded before any mount"
  ok "nothing preloaded"
fi

echo "== hello3 (libfuse 3) and hello2 (libfuse 2), and the cold load"
start_fs hello3 "$W/mnt/h3"; H3=$FS_PID; H3LOG=$FS_LOG
[ "$(bounded 30 cat "$W/mnt/h3/hello")" = "Hello World!" ] || fail "reading hello3's hello"
kext_loaded io.macfuse.filesystems.macfuse.21 || fail "io.macfuse.filesystems.macfuse.21 is not loaded after hello3's mount"
kext_loaded dev.mavergreen.recaulk.kpi || fail "dev.mavergreen.recaulk.kpi is not loaded after hello3's mount"
[ "$(sysctl -n vfs.generic.macfuse.version.number)" = "$(cat "$REPO_ROOT/UPSTREAM_VERSION")" ] || fail "the kext's version sysctl is not $(cat "$REPO_ROOT/UPSTREAM_VERSION")"
ok "hello3's mount alone: load_macfuse loaded the kext and its back-fill"
start_fs hello2 "$W/mnt/h2"; H2=$FS_PID; H2LOG=$FS_LOG
[ "$(bounded 30 cat "$W/mnt/h2/hello")" = "Hello World!" ] || fail "reading hello2's hello"
ok "hello3 and hello2 mount and read"
must 30 "ls -la on hello3" ls -la "$W/mnt/h3" > /dev/null
must 30 "stat on hello3" stat "$W/mnt/h3/hello" > /dev/null
n0="$(sysctl -n debug.recaulk_kpi.vnode_notify_forwarded 2>/dev/null || echo 0)"
echo "vnode_notify forwarded after hello3's (read-only) activity: $n0"
stop_fs "$W/mnt/h3" "$H3" "$H3LOG"; stop_fs "$W/mnt/h2" "$H2" "$H2LOG"
for l in "$H3LOG" "$H2LOG"; do [ "$(fork_warnings "$l")" -eq 1 ] || fail "$l: $(fork_warnings "$l") fork warnings, not the one of a multithreaded mount"; done
start_fs hello3 "$W/mnt/h3" -s; H3=$FS_PID; H3LOG=$FS_LOG
[ "$(bounded 30 cat "$W/mnt/h3/hello")" = "Hello World!" ] || fail "reading hello3 -s's hello"
stop_fs "$W/mnt/h3" "$H3" "$H3LOG"
[ "$(fork_warnings "$H3LOG")" -eq 0 ] || fail "hello3 -s (single-threaded) still warns about forking a threaded process"
ok "the fork warning: once per multithreaded mount, none with -s (FORK_WARNING in tests/vm/lib.sh)"

echo "== passthrough3 over a scratch directory"
S="$W/scratch"
safe_rm "$S"
mkdir -p "$S" || fail "mkdir $S"
start_fs passthrough3 "$W/mnt/pt"; PT=$FS_PID; PTLOG=$FS_LOG
must 600 "tests/vm/ops.sh on passthrough3" sh "$REPO_ROOT/tests/vm/ops.sh" "$W/mnt/pt$S" > "$SMOKE_LOGS/ops.log" 2>&1
cat "$SMOKE_LOGS/ops.log"
# spec: 2026-11-19-macfuse-product/task-8-report.md Deviation 1 -- Recaulk's back-fill resolves vnode_notify on first use, so
#       the forwarding is asserted once a mount has been used for something that notifies: hello3 is read-only and its reads
#       and lookups notify nothing (task-11-report.md), so it is asserted after passthrough3's writes, renames and xattrs
n="$(sysctl -n debug.recaulk_kpi.vnode_notify_forwarded 2>/dev/null || echo 0)"
[ "$n" -gt 0 ] 2>/dev/null || fail "debug.recaulk_kpi.vnode_notify_forwarded is '$n' after passthrough3's ops"
if [ "${SMOKE_FRESH:-1}" = 1 ]; then
  syslog_since "$LOG0" "vnode_notify: forwarding to kernel" > /dev/null || fail "system.log has no 'vnode_notify: forwarding to kernel' since this smoke began"
fi
ok "vnode_notify forwarded $n times; system.log says forwarding to kernel"
echo a > "$S/x"; echo b > "$S/y"
must 60 "tests/vm/default-op.py" python "$REPO_ROOT/tests/vm/default-op.py" "$W/mnt/pt$S/x" "$W/mnt/pt$S/y" "$W/mnt/pt$S" > "$SMOKE_LOGS/default-op.log" 2>&1
cat "$SMOKE_LOGS/default-op.log"
rm -f "$S/x" "$S/y"
stop_fs "$W/mnt/pt" "$PT" "$PTLOG"
# spec: task-11-rereview-1.md Important 2 -- gate0b's mount points are this script's too, should the watchdog cut its
#       own cleanup short
track_mount "$W/gate0b/mnt/pt"; track_mount "$W/gate0b/mnt/probe"
must $((${GATE0B_SECS:-60} + 900)) "tests/vm/gate0b.sh" sh "$REPO_ROOT/tests/vm/gate0b.sh" "$BIN" "$W/gate0b"

echo "== macFUSE.framework"
mkdir -p "$W/mnt/fw"
is_mounted "$W/mnt/fw" && fail "$W/mnt/fw is already mounted before framework-fs starts"
"$BIN/framework-fs" "$W/mnt/fw" > "$SMOKE_LOGS/framework-fs.log" 2>&1 &
FW=$!
track_pid "$FW"; track_mount "$W/mnt/fw"
wait_mounted "$W/mnt/fw" 30 "$FW"
[ "$(bounded 30 cat "$W/mnt/fw/hello.txt")" = "Hello from macFUSE.framework on 10.9" ] || fail "reading framework-fs's hello.txt"
umount_mp "$W/mnt/fw"
wait_exit "$FW" 30 || fail "framework-fs did not exit after umount"
[ "$(fork_warnings "$SMOKE_LOGS/framework-fs.log")" -le 1 ] || fail "framework-fs.log has more than one fork warning"
wait "$FW" || fail "framework-fs exited non-zero"
ok "framework-fs mounts, reads and exits 0"

if [ -x "$BIN/old-abi" ]; then
  echo "== a binary built against upstream 4.0.5"
  start_fs old-abi "$W/mnt/old"; OLD=$FS_PID
  [ "$(bounded 30 cat "$W/mnt/old/old-abi.txt")" = "built against macFUSE 4.0.5" ] || fail "reading old-abi.txt"
  stop_fs "$W/mnt/old" "$OLD" "$FS_LOG"
  ok "old-abi mounts and reads over this libfuse 2"
fi

echo "== an unknown option is refused, with no volume"
mkdir -p "$W/mnt/bad"
track_mount "$W/mnt/bad"
is_mounted "$W/mnt/bad" && fail "$W/mnt/bad is already mounted"
for e in hello3 hello2; do
  bounded 90 "$BIN/$e" "$W/mnt/bad" -f -o mavergreen_no_such_option > "$SMOKE_LOGS/bad-$e.log" 2>&1
  rc=$?
  [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] || fail "$e with an unknown option exited $rc"
  grep -q "unknown option.*mavergreen_no_such_option" "$SMOKE_LOGS/bad-$e.log" || fail "$e did not name the unknown option"
  is_mounted "$W/mnt/bad" && fail "$e with an unknown option left a volume mounted"
done
ok "hello3 and hello2 refuse an unknown option by name, and mount nothing"
# spec: task-11-report.md "Fix round 1" (3) -- mount_macfuse itself, as libfuse would exec it, but with no daemon behind the
#       socket: upstream's mount_macfuse has no unknown-option message (it splits -o with strtok against its own table and
#       ignores what it does not know), so the option is not refused here; what must hold is that the run ends, non-zero,
#       saying why, with no volume and no hang -- mount(2) gives up when no daemon answers INIT (EAGAIN, about 50 s)
bounded 150 python "$REPO_ROOT/tests/vm/mount-direct.py" "$W/mnt/bad" mavergreen_no_such_option "$BIN/hello3" > "$SMOKE_LOGS/bad-mount_macfuse.log" 2>&1
rc=$?
[ "$rc" -ne 124 ] || fail "mount_macfuse -o mavergreen_no_such_option hung for 150 s"
[ "$rc" -ne 0 ] && [ "$rc" -lt 128 ] || fail "mount_macfuse -o mavergreen_no_such_option exited $rc"
grep -q "^mount_macfuse: " "$SMOKE_LOGS/bad-mount_macfuse.log" || fail "mount_macfuse -o mavergreen_no_such_option said nothing"
is_mounted "$W/mnt/bad" && fail "mount_macfuse -o mavergreen_no_such_option left a volume mounted"
ok "mount_macfuse -o mavergreen_no_such_option, no daemon: exit $rc, '$(grep -m1 '^mount_macfuse: ' "$SMOKE_LOGS/bad-mount_macfuse.log")', no volume"

echo "== mount_macfuse's failure path, once"
# spec: 2026-11-18-macfuse-design.md decision D -- with libfuse's environment but a closed _FUSE_COMMFD, the adapted
#       setuid mount_macfuse passes its 10.9 gate, runs load_macfuse, opens the device, then fails to send the fd and exits
#       through its CF exit handler (a distributed notification); it must say so and exit non-zero, without crashing or
#       hanging. _FUSE_DAEMON_PATH is set as libfuse sets it: without it upstream's handler crashes (task-11-report.md).
before="$(crash_reports mount_macfuse | wc -l)"
mkdir -p "$W/mnt/alert"
track_mount "$W/mnt/alert"
bounded 120 env _FUSE_CALL_BY_LIB=1 _FUSE_COMMFD=9 _FUSE_COMMVERS=2 _FUSE_DAEMON_PATH="$BIN/hello3" \
  /Library/Filesystems/macfuse.fs/Contents/Resources/mount_macfuse "$W/mnt/alert" > "$SMOKE_LOGS/alert.log" 2>&1 9>&-
rc=$?
[ "$rc" -ne 124 ] || fail "mount_macfuse with a closed _FUSE_COMMFD hung for 120 s"
[ "$rc" -ne 0 ] && [ "$rc" -lt 128 ] || fail "mount_macfuse with a closed _FUSE_COMMFD exited $rc"
grep -q "failed to send file descriptor" "$SMOKE_LOGS/alert.log" || fail "mount_macfuse did not say why it failed"
sleep 10
[ "$(crash_reports mount_macfuse | wc -l)" -eq "$before" ] || fail "mount_macfuse left a crash report"
is_mounted "$W/mnt/alert" && fail "mount_macfuse with a closed _FUSE_COMMFD mounted a volume"
ok "mount_macfuse fails cleanly ($rc): $(tail -n 1 "$SMOKE_LOGS/alert.log")"

echo "== kill -9 a daemon; umount clears its volume"
start_fs hello3 "$W/mnt/k"; K=$FS_PID
# platform: bash-as-sh reports "Killed: 9" for a signalled job whenever it reaps it, so the block's stderr is dropped
{ kill -9 "$K"; wait_exit "$K" 10 && wait "$K"; } 2> /dev/null
kill -0 "$K" 2> /dev/null && fail "hello3 survived kill -9 for 10 s"
bounded 30 ls "$W/mnt/k" > /dev/null 2>&1
[ $? -ne 124 ] || fail "listing a dead daemon's volume hung"
bounded 60 umount "$W/mnt/k" 2>/dev/null || bounded 60 sudo -n umount "$W/mnt/k" || fail "umount of a dead daemon's volume"
wait_unmounted "$W/mnt/k" 30
ok "a killed daemon's volume answers at once and umount clears it"

echo "== nothing left mounted"
for m in $ALL_MOUNTS; do is_mounted "$m" && fail "$m is still mounted"; done
mount | grep -q -e '(macfuse' -e '(osxfuse' && fail "a FUSE volume is still mounted"
ok "all unmounted"

echo "== the MFMount device test and the osrelease shim test, on 10.9"
[ -n "${SHIPYARD_SCRIPTS:-}" ] || fail "SHIPYARD_SCRIPTS is not set; the MFMount and shim tests need it"
# spec: tests/mfmount-device-test.sh -- it builds MFMount from the pinned upstream sources, fetched here when absent
MFMOUNT_SRC="${MFMOUNT_SRC:-${MAVERICKS_BUILD_ROOT:-${TMPDIR:-/tmp}/mm-build}/src}"; export MFMOUNT_SRC
[ -f "$MFMOUNT_SRC/mount/Mount/Bridge/Trampoline.c" ] ||
  must 1800 "build/fetch-sources.sh $MFMOUNT_SRC" sh "$REPO_ROOT/build/fetch-sources.sh" "$MFMOUNT_SRC" > "$SMOKE_LOGS/fetch-sources.log" 2>&1
for t in mfmount-device-test.sh osrelease-shim-test.sh; do
  bounded 1800 sh "$REPO_ROOT/tests/$t" > "$SMOKE_LOGS/$t.log" 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "tests/$t exited $rc (77 is a skip, 124 a hang, a failure here)"
  ok "tests/$t: $(tail -n 1 "$SMOKE_LOGS/$t.log")"
done
sleep 5
[ "$(all_crashes | wc -l | tr -d ' ')" -eq "$CRASH0" ] || fail "new crash reports during this run: $(all_crashes | tr '\n' ' ')"
[ "$CRASH0" -eq 0 ] || echo "note: $CRASH0 crash report(s) from before this run: $(all_crashes | tr '\n' ' ')"
echo "ok: real-10.9 smoke ($VERSION)"
