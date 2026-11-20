#!/bin/sh
# platform: host-agnostic
# usage: fetch-upstream.sh VERSION OUTDIR
# Downloads macFUSE VERSION's dmg, debug tbz and .sha256 into OUTDIR and verifies each asset against
# its own line in the .sha256. Exits non-zero, naming the asset, on any mismatch, absence or duplicate.
set -eu
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"; export REPO_ROOT
. "$REPO_ROOT/build/lib.sh"
. "$REPO_ROOT/build/msc.sh"
. "$SHIPYARD_SCRIPTS/mavericks_fetch.sh"

[ $# -eq 2 ] || { echo "usage: $0 VERSION OUTDIR" >&2; exit 2; }
v=$1
out=$2
tag="macfuse-$v"
base="${MACFUSE_RELEASES:-https://github.com/macfuse/macfuse/releases/download}/$tag"
sums="$tag.sha256"
assets="$tag.dmg $tag-debug.tbz"

mkdir -p "$out"
for f in $sums $assets; do
  shipyard_curl --quiet "$base/$f" "$out/$f" || { echo "fetch-upstream: cannot download $base/$f" >&2; exit 1; }
done

for f in $assets; do
  # each line is "<sum>  <name>" or "<sum> *<name>"; match the name exactly
  n="$(awk -v n="$f" '{ x = $2; sub(/^\*/, "", x); if (x == n) c++ } END { print c + 0 }' "$out/$sums")"
  [ "$n" -ne 0 ] || { echo "fetch-upstream: $f is not listed in $sums" >&2; rm -f "$out/$f"; exit 1; }
  [ "$n" -eq 1 ] || { echo "fetch-upstream: $f is listed $n times in $sums" >&2; rm -f "$out/$f"; exit 1; }
  want="$(awk -v n="$f" '{ x = $2; sub(/^\*/, "", x); if (x == n) print $1 }' "$out/$sums")"
  got="$(shasum -a 256 "$out/$f" | awk '{ print $1 }')"
  [ "$got" = "$want" ] || { echo "fetch-upstream: $f is sha256 $got, not $want" >&2; rm -f "$out/$f"; exit 1; }
  echo "$f: OK"
done
echo "all assets verified"
