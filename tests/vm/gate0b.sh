#!/bin/sh
# platform: macOS-only -- mounts passthrough3 and probe-fs on Mac OS X 10.9 (the acceptance job's guest) and measures them
# spec: 2026-11-19-macfuse-product/task-11-report.md "Gate 0b results (for anylinuxfs)" -- what a libfuse 3 file system
#       built for this product can rely on, asked by anylinuxfs: (1) the default multithreaded loop under 8 parallel
#       readers and writers for GATE0B_SECS (60) s, with no hang; (2) FUSE_THREAD_STACK=8388608 gives the workers an
#       8 MiB stack; (3) the negotiated max_write/max_read, and a 64 MiB dd write and read-back with its throughput;
#       (4) which callbacks xattr -w/-p/-d, ditto and cp -p reach, with and without noappledouble; (5) umount,
#       diskutil unmount and SIGTERM each run destroy() before the daemon exits; (6) df shows statfs's numbers.
#       Prints "gate0b:" result lines, and asserts each: no hang, a multithreaded daemon, 1 MiB max_write, an 8 MiB stack,
#       a byte-identical round trip, both xattrs kept by ditto and cp -p and no ._ names asked for, destroy() once per
#       unmount, df equal to statfs. Every wait is bounded; on any exit it unmounts and kills what it started.
#   usage: gate0b.sh BINDIR WORKDIR   (BINDIR holds passthrough3 and probe-fs; run as the guest's user)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/../.." && pwd)}"
. "$HERE/lib.sh"
cleanup_on_exit
[ $# -eq 2 ] || { echo "usage: gate0b.sh BINDIR WORKDIR" >&2; exit 2; }
BIN=$1; G=$2
SECS="${GATE0B_SECS:-60}"
safe_rm "$G"
mkdir -p "$G/mnt" "$G/src" "$SMOKE_LOGS" || fail "mkdir $G"
r() { echo "gate0b: $*"; }
mark() { echo "--- $1" >> "$PROBE_LOG"; }
start_daemon() {  # MOUNTPOINT LOG CMD... ; sets DPID
  _dm=$1; _dl=$2; shift 2
  is_mounted "$_dm" && fail "$_dm is already mounted before $1 starts"
  "$@" > "$_dl" 2>&1 &
  DPID=$!
  track_pid "$DPID"; track_mount "$_dm"
  wait_mounted "$_dm" 30 "$DPID"
  kill -0 "$DPID" 2>/dev/null || fail "$1 (pid $DPID) is gone, though $_dm is mounted"
}
stop_daemon() {  # MOUNTPOINT PID LOG
  umount_mp "$1"
  wait_exit "$2" 30 || fail "the daemon of $1 did not exit after umount"
  [ "$(fork_warnings "$3")" -le 1 ] || fail "$3 has more than one fork warning for one mount"
}
since() { sed -n "/^--- $1\$/,\$p" "$PROBE_LOG" | sed 1d | awk '{ print $1 }' | sort | uniq -c | awk '{ printf "%s%s=%s", sep, $2, $1; sep = " " } END { print "" }'; }

echo "== (1)+(3) passthrough3, default multithreaded loop, -d for INIT"
M="$G/mnt/pt"; S="$G/src"
mkdir -p "$M"
start_daemon "$M" "$SMOKE_LOGS/gate0b-pt.log" "$BIN/passthrough3" "$M" -f -d
PT=$DPID
init="$(grep -E '^ *(max_write|max_read|max_readahead|max_background|congestion_threshold|time_gran)' "$SMOKE_LOGS/gate0b-pt.log" | sed 's/^ *//' | tr '\n' ' ')"
r "passthrough3 -d INIT reply: ${init:-none found}"
grep -E 'INIT: |unique: 1,|init' "$SMOKE_LOGS/gate0b-pt.log" | head -n 3 | sed 's/^/gate0b:   /'
# spec: task-11-report.md "Gate 0b results" (3) -- the reply's max_write is the 1 MiB anylinuxfs was told it can rely on
grep -q '^ *max_write=0x00100000$' "$SMOKE_LOGS/gate0b-pt.log" || fail "passthrough3's INIT reply does not give max_write=0x00100000 (1 MiB)"
P="$M$S"
must 60 "making 64 MiB of random data" dd if=/dev/urandom of="$G/rand64" bs=1048576 count=64 2> /dev/null
must 300 "dd bs=1m write to passthrough3" dd if="$G/rand64" of="$P/big" bs=1m 2> "$G/dd-w"
r "dd bs=1m 64 MiB write: $(grep 'bytes transferred' "$G/dd-w")"
must 300 "dd bs=1m read from passthrough3" dd if="$P/big" of="$G/back64" bs=1m 2> "$G/dd-r"
r "dd bs=1m 64 MiB read-back: $(grep 'bytes transferred' "$G/dd-r")"
must 60 "the 64 MiB read back differs from what was written" cmp -s "$G/rand64" "$G/back64"
must 60 "the 64 MiB file on the backing directory differs" cmp -s "$G/rand64" "$S/big"
must 60 "rm through passthrough3" rm -f "$P/big"
rm -f "$G/back64"
r "64 MiB round trip byte-identical"
# spec: 2026-11-19-macfuse-product/task-11-report.md "Gate 0b results" (1) -- each worker writes, reads back and compares,
#       renames and unlinks its own files in a loop until the deadline; a worker still running 60 s past it is a hang
end=$(( $(date +%s) + SECS ))
i=1
while [ "$i" -le 8 ]; do
  (
    n=0
    while [ "$(date +%s)" -lt "$end" ]; do
      dd if="$G/rand64" of="$P/w$i" bs=65536 count=$(( (i * 7 + n) % 32 + 1 )) 2>/dev/null || { echo "worker $i: write failed" >&2; exit 1; }
      cmp -s "$P/w$i" "$S/w$i" || { echo "worker $i: read-back differs" >&2; exit 1; }
      mv "$P/w$i" "$P/r$i" && cat "$P/r$i" > /dev/null && rm "$P/r$i" || { echo "worker $i: rename/read/unlink failed" >&2; exit 1; }
      ls "$P" > /dev/null || exit 1
      n=$((n + 1))
    done
    echo "$n" > "$G/count$i"
  ) 2>> "$SMOKE_LOGS/gate0b-workers.log" &
  eval "W$i=\$!"
  track_pid "$!"
  i=$((i + 1))
done
threads=0
sleep 5
threads="$(ps -M -p "$PT" | sed 1d | wc -l | tr -d ' ')"
i=1; total=0
while [ "$i" -le 8 ]; do
  eval "wp=\$W$i"
  wait_exit "$wp" $((SECS + 60)) || { kill -9 "$wp"; fail "worker $i hung (passthrough3, multithreaded loop)"; }
  wait "$wp" || fail "worker $i failed: $(tail -n 3 "$SMOKE_LOGS/gate0b-workers.log")"
  total=$((total + $(cat "$G/count$i")))
  i=$((i + 1))
done
r "8 workers x ${SECS} s on passthrough3 (no -s): $total write/compare/rename/unlink rounds, no hang; daemon had $threads threads mid-run"
[ "$threads" -gt 2 ] 2>/dev/null || fail "passthrough3 had '$threads' threads mid-run: the default loop is not multithreaded"
[ "$total" -ge 8 ] || fail "the 8 workers made only $total rounds in ${SECS} s"
stop_daemon "$M" "$PT" "$SMOKE_LOGS/gate0b-pt.log"

echo "== (2) FUSE_THREAD_STACK"
PROBE_LOG="$G/probe.log"; export PROBE_LOG
: > "$PROBE_LOG"
M="$G/mnt/probe"; mkdir -p "$M"
stack_run() {  # LABEL [env...] : mount probe-fs, read /stack from 8 readers at once; sets STACK to the sizes reported
  _l=$1; shift
  mark "stack-$_l"
  start_daemon "$M" "$SMOKE_LOGS/gate0b-probe-$_l.log" env "$@" "$BIN/probe-fs" "$M" -f
  _p=$DPID
  _j=0; _rp=""
  while [ "$_j" -lt 8 ]; do cat "$M/stack" > /dev/null & _rp="$_rp $!"; _j=$((_j + 1)); done
  for _q in $_rp; do wait_exit "$_q" 30 || { kill -9 "$_q"; fail "a reader of $M/stack hung"; }; done
  stop_daemon "$M" "$_p" "$SMOKE_LOGS/gate0b-probe-$_l.log"
  STACK="$(sed -n "/^--- stack-$_l\$/,\$p" "$PROBE_LOG" | sed -n 's/^read \/stack stacksize=//p' | sort -u | tr '\n' ' ')"
}
stack_run default PROBE_X=1
r "worker stack, FUSE_THREAD_STACK unset: $STACK"
[ -n "$STACK" ] || fail "probe-fs reported no worker stack size"
stack_run 8m FUSE_THREAD_STACK=8388608
r "worker stack, FUSE_THREAD_STACK=8388608: $STACK"
[ "$STACK" = "8388608 " ] || fail "with FUSE_THREAD_STACK=8388608 the workers' stacks are '$STACK', not 8388608"
grep '^init ' "$PROBE_LOG" | head -n 1 | sed 's/^/gate0b: probe-fs negotiated: /'
grep -q '^init max_write=1048576 ' "$PROBE_LOG" || fail "probe-fs's init() did not see max_write=1048576"

echo "== (4) xattr callbacks, ditto and cp -p, with and without noappledouble"
echo source > "$G/xsrc"
xattr -w user.gate0b hello "$G/xsrc" && xattr -w com.apple.metadata:gate0b world "$G/xsrc" || fail "xattr on the local source"
for opt in none noappledouble; do
  if [ "$opt" = none ]; then set --; else set -- -o noappledouble; fi
  start_daemon "$M" "$SMOKE_LOGS/gate0b-probe-x-$opt.log" "$BIN/probe-fs" "$M" -f "$@"
  p=$DPID
  must 30 "write f ($opt)" sh -c 'echo data > "$1"' sh "$M/f"
  mark "w-$opt"; bounded 30 xattr -w user.k v "$M/f"; rw=$?
  mark "p-$opt"; got="$(bounded 30 xattr -p user.k "$M/f")"; rp=$?
  mark "d-$opt"; bounded 30 xattr -d user.k "$M/f"; rd=$?
  mark "end-$opt"
  r "[$opt] xattr -w rc=$rw -> $(sed -n "/^--- w-$opt\$/,/^--- p-$opt\$/p" "$PROBE_LOG" | grep -v '^---' | awk '{ print $1 }' | sort | uniq -c | awk '{ printf "%s=%s ", $2, $1 }')"
  r "[$opt] xattr -p rc=$rp value='$got' -> $(sed -n "/^--- p-$opt\$/,/^--- d-$opt\$/p" "$PROBE_LOG" | grep -v '^---' | awk '{ print $1 }' | sort | uniq -c | awk '{ printf "%s=%s ", $2, $1 }')"
  r "[$opt] xattr -d rc=$rd -> $(sed -n "/^--- d-$opt\$/,/^--- end-$opt\$/p" "$PROBE_LOG" | grep -v '^---' | awk '{ print $1 }' | sort | uniq -c | awk '{ printf "%s=%s ", $2, $1 }')"
  [ "$rw" -eq 0 ] && [ "$rp" -eq 0 ] && [ "$got" = v ] && [ "$rd" -eq 0 ] || fail "xattr -w/-p/-d on probe-fs ($opt)"
  mark "ditto-$opt"; bounded 60 ditto "$G/xsrc" "$M/dittoed"; rdi=$?
  r "[$opt] ditto rc=$rdi -> $(since "ditto-$opt")"
  dx="$(bounded 30 xattr "$M/dittoed" 2>&1 | sort | tr '\n' ' ')"
  r "[$opt] ditto copy's xattrs: $dx"
  mark "cpp-$opt"; bounded 60 cp -p "$G/xsrc" "$M/cpp"; rcp=$?
  r "[$opt] cp -p rc=$rcp -> $(since "cpp-$opt")"
  cx="$(bounded 30 xattr "$M/cpp" 2>&1 | sort | tr '\n' ' ')"
  r "[$opt] cp -p copy's xattrs: $cx"
  [ "$rdi" -eq 0 ] && [ "$dx" = "com.apple.metadata:gate0b user.gate0b " ] || fail "ditto ($opt) exited $rdi, or its copy's xattrs are '$dx'"
  [ "$rcp" -eq 0 ] && [ "$cx" = "com.apple.metadata:gate0b user.gate0b " ] || fail "cp -p ($opt) exited $rcp, or its copy's xattrs are '$cx'"
  r "[$opt] entries on the volume: $(bounded 30 ls -a "$M" | tr '\n' ' ')"
  ad="$(grep -c ' /\._' "$PROBE_LOG" | tr -d ' ')"
  r "[$opt] AppleDouble names the daemon was asked for: $ad (cumulative)"
  # spec: task-11-report.md "Gate 0b results" (4) -- a file system with xattr callbacks gets native xattrs, never ._ files
  [ "$ad" -eq 0 ] || fail "probe-fs was asked for $ad ._ names ($opt)"
  stop_daemon "$M" "$p" "$SMOKE_LOGS/gate0b-probe-x-$opt.log"
done

echo "== (5) destroy() before exit: umount, diskutil unmount, SIGTERM"
for how in umount diskutil sigterm; do
  mark "destroy-$how"
  start_daemon "$M" "$SMOKE_LOGS/gate0b-probe-$how.log" "$BIN/probe-fs" "$M" -f
  p=$DPID
  must 30 "ls $M" ls "$M" > /dev/null
  case $how in
    umount) must 60 "umount $M" umount "$M" ;;
    diskutil) bounded 60 diskutil unmount "$M" > "$SMOKE_LOGS/gate0b-diskutil.log" 2>&1 || fail "diskutil unmount: $(cat "$SMOKE_LOGS/gate0b-diskutil.log")" ;;
    sigterm) kill -TERM "$p" ;;
  esac
  wait_exit "$p" 30 || fail "probe-fs did not exit after $how"
  wait "$p"; prc=$?
  wait_unmounted "$M" 30
  d="$(sed -n "/^--- destroy-$how\$/,\$p" "$PROBE_LOG" | grep -c '^destroy$')"
  r "$how: destroy() called $d time(s), daemon exit status $prc, volume gone"
  [ "$d" -eq 1 ] || fail "$how: destroy() ran $d times, not once"
done

echo "== (6) df shows statfs"
start_daemon "$M" "$SMOKE_LOGS/gate0b-probe-df.log" "$BIN/probe-fs" "$M" -f
p=$DPID
dfk="$(bounded 30 df -k "$M" | sed 1d)"
dfi="$(bounded 30 df -i "$M" | sed 1d)"
r "df -k: $dfk"
r "df -i: $dfi"
# spec: tests/vm/probe-fs.c p_statfs -- frsize 4096: 1000000 blocks = 4000000 KiB, bfree 600000 = used 1600000 KiB, bavail 500000 = 2000000 KiB;
#       files 70000, ffree 50000 = 20000 inodes used
set -- $dfk
[ "$2" = 4000000 ] && [ "$3" = 1600000 ] && [ "$4" = 2000000 ] || fail "df -k is '$dfk', not 4000000 1600000 2000000"
set -- $dfi
[ "$6" = 20000 ] && [ "$7" = 50000 ] || fail "df -i is '$dfi', not 20000 used and 50000 free inodes"
stop_daemon "$M" "$p" "$SMOKE_LOGS/gate0b-probe-df.log"
r "df matches statfs"
ok "gate0b"
