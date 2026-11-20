#!/bin/sh
# platform: host-agnostic
# usage: sh scripts/pin-sources.sh VERSION
#        CI and dev only; needs git (the one script that does). Reads the gitlinks Library-2, Library-3, Mount and
#        Framework of macfuse/macfuse at tag macfuse-VERSION, fetches GitHub's tarball of each commit, checks with git
#        that the tarball holds exactly that commit's tree, and writes components/macfuse-sources/pins: the digests
#        and the tarballs' SHA-256s. The file is written once, by a rename, after all four pass; any failure or signal
#        leaves it as it was.
set -eu
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"; export REPO_ROOT
. "$REPO_ROOT/build/lib.sh"
. "$REPO_ROOT/build/msc.sh"
. "$SHIPYARD_SCRIPTS/mavericks_fetch.sh"

[ $# -eq 1 ] || { echo "usage: $0 VERSION" >&2; exit 2; }
tag="macfuse-$1"
gh="${MACFUSE_GITHUB:-https://github.com}"
fail() { echo "pin-sources: $*" >&2; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/pin-sources.XXXXXX")"
trap 'rm -rf "$T"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
git="git -c core.precomposeunicode=false -c core.ignorecase=false -c core.autocrlf=false -c core.fileMode=true -c core.symlinks=true"

$git init -q --bare "$T/m" && $git --git-dir="$T/m" fetch -q --depth 1 "$gh/macfuse/macfuse" "refs/tags/$tag:refs/tags/$tag" \
  || fail "cannot fetch tag $tag of macfuse/macfuse"
tree="$($git --git-dir="$T/m" ls-tree "$tag")" || fail "cannot read tag $tag"

: > "$T/pins"
printf '%s\n' "$MACFUSE_SOURCES" | while read -r key dir repo gitlink; do
  commit="$(printf '%s\n' "$tree" | awk -v n="$gitlink" '$1 == "160000" && $2 == "commit" && $4 == n { print $3 }')"
  [ -n "$commit" ] || fail "tag $tag has no gitlink $gitlink"
  url="$(sh "$SHIPYARD_SCRIPTS/fetch_pinned_source.sh" --url "https://github.com/$repo" "$commit")" || fail "no tarball URL for $repo at $commit"
  echo "==> ${key}_SHA256: $url" >&2
  shipyard_curl --quiet "$url" "$T/$key.tgz" || fail "cannot fetch $url"
  sha="$(shasum -a 256 < "$T/$key.tgz" | cut -c1-64)"
  mkdir "$T/$key.x" && tar xzf "$T/$key.tgz" -C "$T/$key.x" || fail "cannot extract $url"
  top="$(ls -A "$T/$key.x")"
  [ -d "$T/$key.x/$top" ] && [ "$(printf '%s\n' "$top" | wc -l | tr -d ' ')" = 1 ] || fail "$url holds more than one entry: $top"
  # platform: git status never looks at an entry named .git and never reports an empty directory, so a
  #           tarball could carry either unseen; neither is in a commit's tree.
  extra="$(find "$T/$key.x/$top" \( -name .git -o -type d -empty \) -print | head -5)"
  [ -z "$extra" ] || { printf '%s\n' "$extra" >&2; fail "$url is not commit $commit's tree: it holds the .git or empty directory above"; }
  g="$T/$key.git"
  $git init -q --bare "$g" && $git --git-dir="$g" fetch -q --depth 1 "$gh/$repo" "$commit" || fail "cannot fetch commit $commit of $repo"
  $git --git-dir="$g" read-tree "$commit" && $git --git-dir="$g" update-ref --no-deref HEAD "$commit" || fail "cannot read commit $commit"
  diffs="$($git --git-dir="$g" --work-tree="$T/$key.x/$top" status --porcelain --untracked-files=all --ignored)" || fail "git cannot compare $url with commit $commit"
  [ -z "$diffs" ] || { printf '%s\n' "$diffs" | head -20 >&2; fail "$url is not commit $commit's tree (the differences above)"; }
  echo "    $sha (the commit's tree, file for file)" >&2
  printf '%s_DIGEST=%s\n%s_SHA256=%s\n' "$key" "$commit" "$key" "$sha" >> "$T/pins"
  rm -rf "$T/$key.tgz" "$T/$key.x" "$g"
done

[ "$(wc -l < "$T/pins" | tr -d ' ')" -eq 8 ] || fail "did not pin all four sources"
mkdir -p "$(dirname "$MACFUSE_PINS")"
new="$MACFUSE_PINS.new.$$"
trap 'rm -rf "$T" "$new"' EXIT
cp "$T/pins" "$new" && mv "$new" "$MACFUSE_PINS" || fail "cannot write $MACFUSE_PINS"
echo "pin-sources: wrote $MACFUSE_PINS"
