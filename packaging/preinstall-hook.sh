#!/bin/sh
# platform: macOS-only -- runs inside the pkg's preinstall on Mac OS X 10.9
# spec: 2026-11-19-macfuse-product/task-10-brief.md "Order in the preinstall hook" -- build/lib.sh's macfuse_preinstall_hook
#       puts MACFUSE_PREFIX, MACFUSE_LINKS and packaging/lib-fuse-mounts.sh before this; stage_product.sh runs it in a subshell
#       after unlinking the installed version and before removing its tree, so it runs before the payload lands
macfuse_takeover() {
  _again="run this installer again"
  _v="$(target_macos_version "$ROOT")" || _v=""
  case "$_v" in
    10.9|10.9.*) ;;
    *)
      echo "macFUSE for Mavericks installs only on Mac OS X 10.9, and this volume has ${_v:-an unknown version}. On a newer macOS, install macFUSE itself: https://macfuse.github.io" >&2
      return 1 ;;
  esac
  fuse_refuse_if_mounted "$ROOT" "$_again" || return 1
  _u="$(unaccounted_paths "$ROOT")" ||
    { echo "macFUSE for Mavericks: cannot read upstream macFUSE's receipts; fix the pkgutil error above, then $_again." >&2; return 1; }
  if [ -n "$_u" ]; then
    {
      echo "macFUSE for Mavericks puts links at these paths, which hold files no macFUSE installer receipt accounts for:"
      printf '%s\n' "$_u" | sed 's|^|  /|'
      echo "It never overwrites files it cannot account for. Move them aside, then $_again."
    } >&2
    return 1
  fi
  if [ -z "$ROOT" ]; then
    fuse_kexts_unload "$_again" || return 1
  fi
  remove_upstream_receipts "$ROOT" "$_again" || return 1
  remove_upstream_launchd "$ROOT" "$_again"
}
macfuse_takeover
