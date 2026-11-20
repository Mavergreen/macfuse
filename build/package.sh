#!/bin/sh
# platform: host-agnostic -- shipyard's stevedore seams build the pkg
# spec: 2026-11-19-macfuse-product/task-9-brief.md "Produces" -- tests/package-test.sh holds the contract.
#   usage: package.sh --stage DIR --updater-app APP --version V --out DIR
#          Packages build/stage.sh's stage DIR, with APP (build/build-updater.sh's macfuse-updater.app) as the family
#          updater, as OUT/macfuse-V.pkg: dev.mavergreen.base first, then dev.mavergreen.macfuse, with the 10.9.5 floor.
#          Its preinstall refuses a volume without Recaulk at the version components/recaulk/version pins, or newer, then
#          runs the takeover (build/lib.sh's macfuse_preinstall_hook: packaging/preinstall-hook.sh).
#          V is UPSTREAM_VERSION with its -mavericks.N. The pkg appears in OUT only once it is made; DIR and APP are not
#          changed. A caller without git exports SOURCE_DATE_EPOCH, which stamps every file's mtime.
set -eu
umask 022
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/.." && pwd)}"
export REPO_ROOT
. "$REPO_ROOT/build/lib.sh"
. "$REPO_ROOT/build/msc.sh"
die() { echo "package: $*" >&2; exit 1; }
usage() { echo "usage: $0 --stage DIR --updater-app APP --version V --out DIR" >&2; exit 2; }
stage=; app=; V=; out=
while [ $# -gt 0 ]; do
  case "$1" in
    --stage|--updater-app|--version|--out) [ $# -ge 2 ] || usage ;;
    *) usage ;;
  esac
  case "$1" in
    --stage) stage=$2 ;;
    --updater-app) app=$2 ;;
    --version) V=$2 ;;
    --out) out=$2 ;;
  esac
  shift 2
done
[ -n "$stage" ] && [ -n "$app" ] && [ -n "$V" ] && [ -n "$out" ] || usage
short=macfuse
id="$(sh "$SHIPYARD_SCRIPTS/product-name.sh" identifier "$short" 2>/dev/null)" ||
  die "the shipyard at $SHIPYARD_SCRIPTS does not register $short"
up="$(upstream_version)"
case "$V" in
  "$up"-mavericks.[1-9]*) ;;
  *) die "--version $V is not $up with a -mavericks.N (UPSTREAM_VERSION)" ;;
esac
H="$stage$MACFUSE_PREFIX/fs/Contents/Resources"
[ -f "$H/mount_macfuse" ] && [ -d "$stage$MACFUSE_PREFIX/fs/Contents/Extensions/10/macfuse.kext" ] ||
  die "$stage is not a build/stage.sh stage"
# spec: global-constraints.md "mount_macfuse and load_macfuse: setuid root (root:wheel 4755) as installed" -- stevedore takes the mode from the stage
for h in mount_macfuse load_macfuse; do
  [ -n "$(find "$H/$h" -perm 4755)" ] || die "$h is not 4755 in $stage: stage it with build/stage.sh"
done
rc="$(tr -d ' \t\r\n' < "$REPO_ROOT/components/recaulk/version")" || die "cannot read components/recaulk/version"
case "$rc" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].[1-9]*) case "${rc#*.}" in *[!0-9]*) rc=bad ;; esac ;;
  *) rc=bad ;;
esac
[ "$rc" != bad ] || die "components/recaulk/version is not a Recaulk YYYYMMDD.N: $(head -n 1 "$REPO_ROOT/components/recaulk/version")"

mkdir -p "$out"
out="$(cd "$out" && pwd)"
pkg="$out/$short-$V.pkg"
W="$(mktemp -d "${MAVERICKS_BUILD_ROOT:-${TMPDIR:-/tmp}/mm-build}/package.XXXXXX" 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/package.XXXXXX")"
trap 'rm -rf "$W"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
root="$W/root"
# platform: cp -p keeps the set-user-ID bits, which a copy without it clears; COPYFILE_DISABLE keeps macOS's cp from writing ._* files
COPYFILE_DISABLE=1 cp -pR "$stage" "$root"
macfuse_preinstall_hook "$W/preinstall-hook.sh" || die "cannot compose the preinstall hook"
sh "$SHIPYARD_SCRIPTS/stage_product.sh" --stage "$root" --product "$short" --name "Mavericks macFUSE" --version "$V" \
  --requires "recaulk>=$rc" --updater-app "$app" --preinstall-hook "$W/preinstall-hook.sh" --scripts-out "$W/scripts" >&2
find "$root" -name '._*' -exec rm -f {} +
mkdir -p "$W/component"
sh "$SHIPYARD_SCRIPTS/build_component_pkg.sh" --root "$root" --identifier "$id" --version "$V" \
  --install-location / --scripts "$W/scripts" --out "$W/component/$short.pkg" > /dev/null
sh "$SHIPYARD_SCRIPTS/set_install_floor.sh" --identifier "$id" --title "macFUSE for Mavericks" \
  --component "$W/component/$short.pkg" --out "$W/product.pkg" --host-arch x86_64 --min-os 10.9.5 --require-scripts > /dev/null
sh "$SHIPYARD_SCRIPTS/assert_pkg_installs_in_place.sh" "$W/product.pkg" >&2
mv "$W/product.pkg" "$pkg"
echo "package: $pkg" >&2
