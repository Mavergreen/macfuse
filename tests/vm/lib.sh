# platform: macOS-only -- sourced by the 10.9 acceptance job's guest scripts (tests/smoke-mavericks.sh, tests/vm/*.sh)
# platform: 10.9 has no timeout(1)
# spec: tests/vm-lib-test.sh -- so every wait here is a bounded poll and every command that might hang runs in the
#       background under a kill -0 watchdog. Definitions only.
#   fail MSG...                  prints FAIL and the job's logs (SMOKE_LOGS), exits 1 (and so runs the cleanup below)
#   ok MSG...                    prints ok
#   is_mounted MP                MP (an absolute, symlink-free path) is in the mount table
#   wait_mounted MP SECS [PID]   waits up to SECS for MP to be mounted; fails otherwise, or at once if PID exits first
#   wait_unmounted MP SECS       waits up to SECS for MP to leave the mount table; fails otherwise
#   wait_exit PID SECS           waits up to SECS for PID to exit; returns 1 if it is still alive
#   bounded SECS CMD...          runs CMD in the background; kills it and returns 124 after SECS, else returns its status
#   must SECS WHAT CMD...        bounded, and fails naming WHAT when CMD hangs or exits non-zero
#   umount_mp MP                 umount MP, bounded, and waits for it to leave the mount table
#   manifest_version PREFIX      the version in PREFIX/mavergreen.plist
#   kext_loaded ID               kextstat lists exactly bundle id ID
#   crash_reports NAME           the crash and hang reports for NAME, user's and system's, one per line
#   fork_warnings LOG            how many times LOG says libfuse forked while threaded (see FORK_WARNING)
#   cleanup_on_exit              arms the EXIT trap: unmount what track_mount named, kill what track_pid named and, on a
#                                failing exit, unload the FUSE and Recaulk kexts this script loaded
#   track_mount MP / track_pid PID
#   CLEAN_HOOK                   shell text the cleanup evals after unmounting, whatever the exit status
#   safe_rm DIR                  removes DIR, refusing (fail) when DIR is a link or not a directory, or anything is
#                                mounted at or under it
. "${REPO_ROOT:?tests/vm/lib.sh: set REPO_ROOT to the repo root}/build/lib.sh"
SMOKE_LOGS="${SMOKE_LOGS:-/private/tmp/macfuse-smoke/logs}"
FUSE_KEXTS="io.macfuse.filesystems.macfuse.21 dev.mavergreen.recaulk.kpi"
# spec: DETAILS.md "Coming from macFUSE 4" -- upstream libfuse's helper.c atfork handler prints this when the process is
#       threaded at fork(2); the only fork is fuse_darwin_mount's double fork to exec mount_macfuse, made from a loop
#       worker in the multithreaded loop: once per mount with the default loop, never with -s
FORK_WARNING="fuse: forking a threaded process is unsafe, the child may crash or deadlock"
CLEAN_MPS=""; CLEAN_PIDS=""; KEXTS_BEFORE=""
# spec: tests/vm-lib-test.sh (1) -- fd 8 is the script's own stderr, saved when this file is sourced: fail and the
#       cleanup write there, so a failure inside a redirected must (a command's output sent to a log or /dev/null) still
#       shows its reason on the job's console
exec 8>&2
fail() {
  {
    echo "FAIL: $*"
    for _f in "$SMOKE_LOGS"/*.log; do
      [ -s "$_f" ] || continue
      echo "--- $_f, last 25 lines:"; tail -n 25 "$_f"
    done
    echo "--- mount:"; mount
    echo "--- kextstat (non-Apple):"; kextstat 2>&1 | grep -v com.apple
  } >&8 2>&8
  exit 1
}
ok() { echo "ok: $*"; }
is_mounted() { mount | grep -qF " on $1 ("; }
wait_mounted() {
  _i=0
  while [ "$_i" -lt "$2" ]; do
    is_mounted "$1" && return 0
    [ -n "${3:-}" ] && ! kill -0 "$3" 2>/dev/null && fail "the daemon for $1 (pid $3) exited before mounting it"
    sleep 1; _i=$((_i + 1))
  done
  fail "$1 was not mounted within $2 s"
}
wait_unmounted() {
  _i=0
  while [ "$_i" -lt "$2" ]; do is_mounted "$1" || return 0; sleep 1; _i=$((_i + 1)); done
  fail "$1 was still mounted after $2 s"
}
wait_exit() {
  _i=0
  while [ "$_i" -lt "$2" ]; do kill -0 "$1" 2>/dev/null || return 0; sleep 1; _i=$((_i + 1)); done
  kill -0 "$1" 2>/dev/null && return 1
  return 0
}
bounded() {
  _secs=$1; shift
  "$@" &
  _bp=$!
  if wait_exit "$_bp" "$_secs"; then
    wait "$_bp"; return $?
  fi
  # spec: tests/vm/lib.sh cleanup_on_exit -- TERM first, so a guest script under the watchdog runs its own cleanup
  kill -TERM "$_bp" 2>/dev/null
  wait_exit "$_bp" 15 || kill -9 "$_bp" 2>/dev/null
  # platform: a root process (sudo's child) ignores the user's kill; then it is left running rather than waited for
  wait_exit "$_bp" 5 && wait "$_bp" 2>/dev/null
  return 124
}
must() {
  _ms=$1; _mw=$2; shift 2
  bounded "$_ms" "$@"; _mrc=$?
  [ "$_mrc" -ne 124 ] || fail "$_mw: hung for $_ms s"
  [ "$_mrc" -eq 0 ] || fail "$_mw (exit $_mrc)"
}
umount_mp() {
  must 60 "umount $1" umount "$1"
  wait_unmounted "$1" 30
}
manifest_version() {
  awk '/<key>version<\/key>/ { getline; sub(/.*<string>/, ""); sub(/<\/string>.*/, ""); print; exit }' "$1/mavergreen.plist"
}
kext_loaded() { kextstat -l | awk -v id="$1" '$6 == id { found = 1 } END { exit !found }'; }
crash_reports() {
  ls -1 "$HOME/Library/Logs/DiagnosticReports/$1"_* /Library/Logs/DiagnosticReports/"$1"_* 2>/dev/null || :
}
fork_warnings() { grep -cF "$FORK_WARNING" "$1" | tr -d ' '; }
track_mount() { CLEAN_MPS="$CLEAN_MPS $1"; }
track_pid() { CLEAN_PIDS="$CLEAN_PIDS $1"; }
loaded_fuse_kexts() { for _k in $FUSE_KEXTS; do kext_loaded "$_k" && printf '%s ' "$_k"; done; }
cleanup_on_exit() {
  KEXTS_BEFORE="$(loaded_fuse_kexts)"
  trap '_cleanup' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
}
_unmount_tracked() {
  # platform: each fallback only while MP is still a mount point: given a path that is not one, diskutil would aim at the
  #           volume that holds it
  for _m in $CLEAN_MPS; do
    is_mounted "$_m" || continue
    bounded 30 umount "$_m" > /dev/null 2>&1
    is_mounted "$_m" || continue
    bounded 30 sudo -n umount -f "$_m" > /dev/null 2>&1
    is_mounted "$_m" || continue
    bounded 60 diskutil unmount force "$_m" > /dev/null 2>&1
  done
}
_cleanup() {
  _crc=$?
  # spec: tests/vm-lib-test.sh (2) -- a second signal must not cut the cleanup short (alert-path's put_back)
  trap '' INT TERM HUP
  trap - EXIT
  _cleanup_body >&8 2>&8
  exit "$_crc"
}
_cleanup_body() {
  _unmount_tracked
  for _p in $CLEAN_PIDS; do kill -0 "$_p" 2>/dev/null && kill -9 "$_p" 2>/dev/null; done
  _unmount_tracked
  for _m in $CLEAN_MPS; do is_mounted "$_m" && echo "cleanup: $_m is still mounted" >&2; done
  [ -z "${CLEAN_HOOK:-}" ] || eval "$CLEAN_HOOK"
  if [ "$_crc" -ne 0 ]; then
    if mount | grep -q -e '(macfuse' -e '(osxfuse'; then
      echo "cleanup: a FUSE volume is still mounted; the kexts stay loaded" >&2
    else
      for _k in $FUSE_KEXTS; do
        case " $KEXTS_BEFORE " in *" $_k "*) continue ;; esac
        kext_loaded "$_k" || continue
        bounded 60 sudo -n kextunload -b "$_k" > /dev/null 2>&1 || echo "cleanup: $_k would not unload" >&2
      done
    fi
  fi
}
safe_rm() {
  # spec: tests/vm-lib-test.sh (3) -- never through a link to its target
  [ ! -h "$1" ] || fail "safe_rm: refusing $1: it is a symbolic link"
  [ -e "$1" ] || return 0
  [ -d "$1" ] || fail "safe_rm: refusing $1: not a directory"
  _sr="$(cd -P "$1" 2>/dev/null && pwd -P)" || fail "safe_rm: cannot resolve $1"
  [ "$_sr" != / ] || fail "safe_rm: refusing to remove /"
  if mount | sed -n 's/^.* on \(.*\) ([^()]*)$/\1/p' |
    awk -v d="$_sr" -v u="$1" '$0 == d || index($0, d "/") == 1 || $0 == u || index($0, u "/") == 1 { f = 1 } END { exit !f }'; then
    fail "refusing to remove $1: something is mounted at or under it ($(mount | grep -F " on $_sr" | tr '\n' ' '))"
  fi
  # platform: 10.9's rm has no -x; find -x never descends into another file system, and -delete wants a relative start
  (cd "$(dirname "$_sr")" && find -x "$(basename "$_sr")" -delete) || fail "safe_rm: could not remove $1"
  [ ! -e "$_sr" ] || fail "safe_rm: $1 is still there"
}
