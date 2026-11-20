#!/bin/sh
# platform: host-agnostic
# spec: build/fetch-sources.sh (task 3), tested against fixture tarballs served over file://.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
fails=0
fail() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }
T="$(mktemp -d "${TMPDIR:-/tmp}/fetch-sources-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT

mk() { # NAME KEY N -> writes the tarball, appends the pins
  c="$(printf '%s%s' "$3" "$3" | cut -c1-1 | awk -v n="$3" 'BEGIN { for (i = 0; i < 40; i++) printf "%s", n }')"
  mkdir -p "$T/cl/macfuse/$1/tar.gz" "$T/w/$1-$c"
  printf '%s\n' "$1" > "$T/w/$1-$c/file"
  tar czf "$T/cl/macfuse/$1/tar.gz/$c" -C "$T/w" "$1-$c"
  printf '%s_DIGEST=%s\n%s_SHA256=%s\n' "$2" "$c" "$2" "$(shasum -a 256 "$T/cl/macfuse/$1/tar.gz/$c" | cut -c1-64)" >> "$T/pins"
}
mkpins() { : > "$T/pins"; mk library LIBRARY2 a; mk library LIBRARY3 b; mk mount MOUNT c; mk framework FRAMEWORK d; }
run() {
  rc=0
  out="$(MAVERICKS_CODELOAD="file://$T/cl" MAVERICKS_SOURCE_CACHE="$T/cache" SHIPYARD_FETCH_BACKOFF=0 MACFUSE_PINS="$T/pins" \
    sh "$ROOT/build/fetch-sources.sh" "$T/out" 2>&1)" || rc=$?
}

mkpins; run
[ "$rc" -eq 0 ] || fail "good pins: exit $rc: $out"
for d in library2 library3 mount framework; do
  [ -f "$T/out/$d/file" ] || fail "missing $d/file"
done

rm -rf "$T/out" "$T/cache"; mkpins
sed 's/^MOUNT_SHA256=.*/MOUNT_SHA256=0000000000000000000000000000000000000000000000000000000000000000/' "$T/pins" > "$T/p2"; mv "$T/p2" "$T/pins"; run
[ "$rc" -ne 0 ] || fail "wrong sha256: exit 0"
case "$out" in *MOUNT*) ;; *) fail "wrong sha256: output does not name the pin: $out" ;; esac
[ ! -e "$T/out" ] || fail "wrong sha256: partial output left: $(ls "$T/out")"

[ "$fails" -eq 0 ] && echo "fetch-sources-test: PASS" || { echo "fetch-sources-test: $fails failure(s)" >&2; exit 1; }
