#!/bin/sh
# platform: macOS-only -- sources tests/vm/lib.sh, the 10.9 guest scripts' library, which is written for Darwin's mount and ps
# spec: tests/vm/lib.sh -- the guest library's failure and cleanup
#       paths, with no FUSE: (1) a failing or hung must whose command's output is redirected still prints its FAIL line on
#       the script's real stderr, and nothing of it lands in the redirect; (2) the EXIT cleanup runs its CLEAN_HOOK to the
#       end through a second TERM and an INT; (3) safe_rm refuses a symbolic link and leaves its target, refuses a
#       non-directory, and removes a real directory; (4) its MACFUSE_PREFIX is build/lib.sh's. kextstat, kextunload, sudo,
#       umount and diskutil are stubs on PATH that change nothing, so the cleanup can never act on this machine.
set -u
case "$(uname -s)" in Darwin) ;; *) echo "vm-lib-test: needs Darwin -- skipping"; exit 77 ;; esac
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/vm/lib.sh"
REPO_ROOT="$(cd "$HERE/.." && pwd)"; export REPO_ROOT
T="$(mktemp -d "${TMPDIR:-/tmp}/vm-lib-test.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$T/stubs" "$T/logs"
for s in kextstat kextunload sudo umount diskutil; do printf '#!/bin/sh\nexit 0\n' > "$T/stubs/$s"; chmod 755 "$T/stubs/$s"; done
PATH="$T/stubs:$PATH"; export PATH
failures=0
bad() { echo "vm-lib-test: FAIL: $*" >&2; failures=$((failures + 1)); }
script() {  # NAME BODY : a guest-style script that sources the library with no kexts to act on
  {
    echo 'set -u'
    echo "SMOKE_LOGS='$T/logs'; . '$LIB'; FUSE_KEXTS=''"
    printf '%s\n' "$2"
  } > "$T/$1.sh"
}

echo "== (1) a failing must, and a hung one, inside a redirect"
script redirected 'cleanup_on_exit
must 10 "a deliberately failing step" sh -c "echo noise; exit 3" > "'"$T"'/redirected.out" 2>&1
echo "not reached"'
sh "$T/redirected.sh" > "$T/redirected.stdout" 2> "$T/redirected.stderr"; rc=$?
[ "$rc" -eq 1 ] || bad "a failing must exited $rc, not 1"
grep -qx 'FAIL: a deliberately failing step (exit 3)' "$T/redirected.stderr" || bad "the FAIL line did not reach the real stderr: $(cat "$T/redirected.stderr")"
grep -q FAIL "$T/redirected.out" && bad "the FAIL line went into the command's redirect"
grep -q "not reached" "$T/redirected.stdout" && bad "the script went on after a failing must"
script hung 'cleanup_on_exit
must 2 "a deliberately hung step" sleep 30 2> /dev/null > /dev/null'
sh "$T/hung.sh" 2> "$T/hung.stderr"; rc=$?
[ "$rc" -eq 1 ] || bad "a hung must exited $rc, not 1"
grep -qx 'FAIL: a deliberately hung step: hung for 2 s' "$T/hung.stderr" || bad "the hang's FAIL line did not reach the real stderr: $(cat "$T/hung.stderr")"
[ "$failures" -eq 0 ] && echo "ok: a failing and a hung must, redirected, still say why on the real stderr"

echo "== (2) the cleanup survives a second signal"
f0=$failures
script signals 'cleanup_on_exit
CLEAN_HOOK="echo hook-started > '"$T"'/hook; sleep 3; echo restored >> '"$T"'/hook"
echo armed > "'"$T"'/armed"
sleep 60 &
echo $! > "'"$T"'/sleeper"
wait $!'
sh "$T/signals.sh" 2> "$T/signals.stderr" &
P=$!
i=0; while [ ! -f "$T/armed" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
kill -TERM "$P"
i=0; while [ ! -f "$T/hook" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ -f "$T/hook" ] || bad "the cleanup hook never started after TERM"
kill -TERM "$P" 2> /dev/null; kill -INT "$P" 2> /dev/null; kill -HUP "$P" 2> /dev/null
i=0; while kill -0 "$P" 2> /dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
kill -0 "$P" 2> /dev/null && { kill -9 "$P"; bad "the script did not exit after its cleanup"; }
wait "$P"; rc=$?
[ "$rc" -eq 143 ] || bad "the script exited $rc after TERM, not 143"
[ "$(cat "$T/hook" 2> /dev/null)" = "$(printf 'hook-started\nrestored')" ] || bad "a second TERM, an INT and a HUP cut the cleanup hook short: '$(cat "$T/hook" 2> /dev/null)'"
[ -f "$T/sleeper" ] && kill "$(cat "$T/sleeper")" 2> /dev/null
[ "$failures" -eq "$f0" ] && echo "ok: the cleanup hook runs to the end through TERM, TERM, INT and HUP"

echo "== (3) safe_rm and links"
f0=$failures
mkdir -p "$T/target/sub" && echo keep > "$T/target/sub/f" && ln -s "$T/target" "$T/link" && echo x > "$T/file"
script rmlink "safe_rm '$T/link'"
sh "$T/rmlink.sh" 2> "$T/rmlink.stderr"; rc=$?
[ "$rc" -eq 1 ] && grep -q "is a symbolic link" "$T/rmlink.stderr" || bad "safe_rm of a link did not refuse it (exit $rc)"
[ -f "$T/target/sub/f" ] && [ -h "$T/link" ] || bad "safe_rm of a link touched the link or its target"
script rmfile "safe_rm '$T/file'"
sh "$T/rmfile.sh" 2> "$T/rmfile.stderr"; rc=$?
[ "$rc" -eq 1 ] && [ -f "$T/file" ] || bad "safe_rm of a file did not refuse it (exit $rc)"
script rmdir "safe_rm '$T/target'"
sh "$T/rmdir.sh" 2> "$T/rmdir.stderr"; rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$T/target" ] || bad "safe_rm of a real directory with nothing mounted did not remove it (exit $rc): $(cat "$T/rmdir.stderr")"
[ "$failures" -eq "$f0" ] && echo "ok: safe_rm refuses a link and a file, and removes a directory"

echo "== (4) the install prefix comes from build/lib.sh"
script prefix 'printf "%s\n" "$MACFUSE_PREFIX"'
want="$(unset MACFUSE_PREFIX; . "$REPO_ROOT/build/lib.sh" && printf '%s\n' "$MACFUSE_PREFIX")"
got="$(unset MACFUSE_PREFIX; sh "$T/prefix.sh")"
[ -n "$want" ] && [ "$got" = "$want" ] && echo "ok: MACFUSE_PREFIX is build/lib.sh's $want" || bad "the guest library's MACFUSE_PREFIX is '$got', not build/lib.sh's '$want'"

[ "$failures" -eq 0 ] || exit 1
echo "vm-lib-test: PASS"
