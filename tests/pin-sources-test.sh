#!/bin/sh
# platform: host-agnostic
# Task 3: scripts/pin-sources.sh against fixture git repos and a file:// codeload tree.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
fails=0
fail() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }
T="$(mktemp -d "${TMPDIR:-/tmp}/pin-sources-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
V=9.9.9
G="git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c init.defaultBranch=main"

mksub() { # NAME FILE -> prints the commit
  d="$T/gh/macfuse/$1"; mkdir -p "$d"
  ( cd "$d" && git init -q . && printf '%s\n' "$2" > file && mkdir -p sub && printf 'x\n' > sub/x && $G add . && $G commit -q -m c ) >/dev/null
  git -C "$d" rev-parse HEAD
}
mktarball() { # NAME COMMIT [extra file]
  mkdir -p "$T/cl/macfuse/$1/tar.gz"
  git -C "$T/gh/macfuse/$1" archive --format=tar --prefix="$1-$2/" "$2" > "$T/cl/macfuse/$1/tar.gz/$2.tar"
  if [ -n "${3:-}" ]; then
    mkdir -p "$T/x/$1-$2" && printf 'extra\n' > "$T/x/$1-$2/$3"
    tar rf "$T/cl/macfuse/$1/tar.gz/$2.tar" -C "$T/x" "$1-$2/$3"
  fi
  gzip -c "$T/cl/macfuse/$1/tar.gz/$2.tar" > "$T/cl/macfuse/$1/tar.gz/$2"; rm "$T/cl/macfuse/$1/tar.gz/$2.tar"
}

l2="$(mksub library 'lib two')"
l3="$( cd "$T/gh/macfuse/library" && printf 'lib three\n' > file && $G commit -q -am three && git rev-parse HEAD )"
mo="$(mksub mount mount)"
fw="$(mksub framework framework)"
mktarball library "$l2"; mktarball library "$l3"; mktarball mount "$mo"; mktarball framework "$fw"

m="$T/gh/macfuse/macfuse"; mkdir -p "$m"
( cd "$m" && git init -q . && printf 'x\n' > README \
  && git update-index --add --cacheinfo "160000,$l2,Library-2" \
  && git update-index --add --cacheinfo "160000,$l3,Library-3" \
  && git update-index --add --cacheinfo "160000,$mo,Mount" \
  && git update-index --add --cacheinfo "160000,$fw,Framework" \
  && $G add README && $G commit -q -m rel && $G tag "macfuse-$V" )

run() { # sets out, rc; pins file at $T/pins
  rc=0
  out="$(MACFUSE_GITHUB="file://$T/gh" MAVERICKS_CODELOAD="file://$T/cl" MAVERICKS_SOURCE_CACHE="$T/cache" SHIPYARD_FETCH_BACKOFF=0 \
    MACFUSE_PINS="$T/pins" sh "$ROOT/scripts/pin-sources.sh" "$@" 2>&1)" || rc=$?
}
sha() { shasum -a 256 "$T/cl/macfuse/$1/tar.gz/$2" | cut -c1-64; }

rm -f "$T/pins"; run "$V"
[ "$rc" -eq 0 ] || fail "good tag: exit $rc: $out"
for row in "LIBRARY2 $l2 library" "LIBRARY3 $l3 library" "MOUNT $mo mount" "FRAMEWORK $fw framework"; do
  set -- $row
  grep -qx "$1_DIGEST=$2" "$T/pins" || fail "$1_DIGEST is not $2: $(cat "$T/pins" 2>/dev/null)"
  grep -qx "$1_SHA256=$(sha "$3" "$2")" "$T/pins" || fail "$1_SHA256 is not the tarball's"
done
[ "$(wc -l < "$T/pins" | tr -d ' ')" -eq 8 ] || fail "pins is not eight lines"

printf 'LIBRARY2_DIGEST=0\n' > "$T/pins"; run 9.9.8
[ "$rc" -ne 0 ] || fail "missing tag: exit 0"
case "$out" in *macfuse-9.9.8*) ;; *) fail "missing tag: output does not name it: $out" ;; esac
[ "$(cat "$T/pins")" = "LIBRARY2_DIGEST=0" ] || fail "missing tag: pins was touched"

mktarball mount "$mo" stray; rm -f "$T/pins"; run "$V"
[ "$rc" -ne 0 ] || fail "tarball with an extra file: exit 0"
case "$out" in *"$mo"*) ;; *) fail "extra file: output does not name the commit: $out" ;; esac
[ ! -e "$T/pins" ] || fail "extra file: pins was written"
ls "$T" | grep -q 'pins\.' && fail "extra file: temp file left behind"

[ "$fails" -eq 0 ] && echo "pin-sources-test: PASS" || { echo "pin-sources-test: $fails failure(s)" >&2; exit 1; }
