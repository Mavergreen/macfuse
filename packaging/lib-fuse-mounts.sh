#!/bin/sh
# platform: macOS-only -- sourced by the pkg's preinstall and by libexec/mavergreen/pre-uninstall on Mac OS X 10.9: mount, pkgutil, kextstat, kextunload
# spec: 2026-11-18-macfuse-design.md "Takeover of an existing upstream install" -- definitions only. ROOT arguments are
#       Installer's target volume without its trailing slash: empty for the boot volume. unaccounted_paths and
#       remove_upstream_receipts read MACFUSE_PREFIX and MACFUSE_LINKS (build/lib.sh), which the caller sets.
#   usage: target_macos_version ROOT            prints ROOT's ProductVersion
#          fuse_mounts ROOT                     prints each mounted macfuse or osxfuse volume's mount point (none unless ROOT is empty)
#          fuse_refuse_if_mounted ROOT AGAIN    fails, listing them, while fuse_mounts prints any
#          fuse_kexts_unload AGAIN              unloads each loaded io.macfuse.filesystems.macfuse* kext, by bundle id
#          upstream_receipt_paths ROOT          prints every path upstream's core and preferencepane receipts list; fails
#                                               on any pkgutil failure other than an absent receipt
#          unaccounted_paths ROOT               prints what stands where a link of ours goes and no receipt or link of ours explains
#          osxfuse3_installed ROOT              succeeds when ROOT holds osxfuse 3's core receipt or its osxfuse.fs; returns 1
#                                               when it holds neither, and 2 on any pkgutil failure other than an absent receipt
#          remove_upstream_receipts ROOT AGAIN  removes what those receipts list and forgets them
#          remove_upstream_launchd ROOT AGAIN   removes upstream's io.macfuse.* launchd plists (unloading a daemon when ROOT is empty)
#          AGAIN completes "..., then": what to do once the cause is fixed. Messages go to stderr.
MACFUSE_UPSTREAM_RECEIPTS="io.macfuse.installer.components.core io.macfuse.installer.components.preferencepane"
OSXFUSE3_RECEIPT=com.github.osxfuse.pkg.Core

target_macos_version() {
  awk '
    want { if (sub(/^[ \t]*<string>/, "") && sub(/<\/string>[ \t]*$/, "")) { print; found = 1 } exit }
    /^[ \t]*<key>ProductVersion<\/key>[ \t]*$/ { want = 1 }
    END { exit !found }' "$1/System/Library/CoreServices/SystemVersion.plist" 2>/dev/null
}

# spec: 2026-11-18-macfuse-design.md "Takeover" step 2 -- the mount table alone, never the mount point: a dead FUSE mount
#       hangs whatever touches it, and is still listed here
fuse_mounts() {
  [ -z "$1" ] || return 0
  _mt="$(mount)" || return 1
  printf '%s\n' "$_mt" | awk '{
    o = index($0, " on "); if (o == 0) next
    rest = substr($0, o + 4); p = 0
    for (i = length(rest); i > 0; i--) if (substr(rest, i, 2) == " (") { p = i; break }
    if (p == 0) next
    t = substr(rest, p + 2); sub(/[,)].*$/, "", t)
    if (t == "macfuse" || t == "osxfuse") print substr(rest, 1, p - 1)
  }'
}

fuse_refuse_if_mounted() {
  _fm="$(fuse_mounts "$1")" || { echo "macFUSE for Mavericks: cannot read the mount table; check that mount works, then $2." >&2; return 1; }
  [ -n "$_fm" ] || return 0
  {
    echo "macFUSE for Mavericks: these FUSE volumes are mounted, and the FUSE kernel extension cannot be unloaded while they are:"
    printf '%s\n' "$_fm" | sed 's/^/  /'
    echo "Unmount them (umount PATH, or eject them in the Finder), then $2."
  } >&2
  return 1
}

fuse_kexts_unload() {
  _fk="$(kextstat -l)" ||
    { echo "macFUSE for Mavericks: cannot list the loaded kernel extensions; check that kextstat works, then $1." >&2; return 1; }
  for _k in $(printf '%s\n' "$_fk" | awk '$6 ~ /^io\.macfuse\.filesystems\.macfuse/ { print $6 }'); do
    kextunload -b "$_k" || {
      echo "macFUSE for Mavericks: cannot unload $_k. Unmount every FUSE volume and quit what uses FUSE, then $1." >&2
      return 1
    }
  done
}

upstream_receipt_paths() {
  for _id in $MACFUSE_UPSTREAM_RECEIPTS; do
    _info="$(pkgutil --volume "$1/" --pkg-info "$_id" 2>&1)" || {
      case "$_info" in
        "No receipt for"*) continue ;;
        *) printf '%s\n' "$_info" >&2; return 1 ;;
      esac
    }
    _loc="$(printf '%s\n' "$_info" | sed -n 's/^location: *//p' | sed 's|^/*||; s|/*$||')"
    _files="$(pkgutil --volume "$1/" --files "$_id")" || return 1
    printf '%s\n' "$_files" | while IFS= read -r _p; do
      [ -n "$_p" ] || continue
      if [ -n "$_loc" ]; then printf '%s/%s\n' "$_loc" "$_p"; else printf '%s\n' "$_p"; fi
    done
  done
}

# spec: 2026-11-18-macfuse-design.md "Collisions" -- every file, link or directory at, or inside a real directory at, a path a link of
#       ours occupies, that no upstream receipt lists and that is not already our link into MACFUSE_PREFIX
unaccounted_paths() {
  _listed="$(upstream_receipt_paths "$1")" || return 1
  printf '%s\n' "$MACFUSE_LINKS" | while read -r _p _t; do
    [ -n "$_p" ] || continue
    _a="$1/$_p"
    if [ -L "$_a" ]; then
      case "$(readlink "$_a")" in "$MACFUSE_PREFIX"/*) continue ;; esac
      printf '%s\n' "$_p"
    elif [ -d "$_a" ]; then
      (cd "$1/" && find "$_p" -print)
    elif [ -e "$_a" ]; then
      printf '%s\n' "$_p"
    fi
  done | { printf '%s\n' "$_listed"; echo '//listed//'; cat; } | awk '
    !done && $0 == "//listed//" { done = 1; next }
    !done { listed[$0] = 1; next }
    !($0 in listed) { print }'
}

osxfuse3_installed() {
  _oi="$(pkgutil --volume "$1/" --pkg-info "$OSXFUSE3_RECEIPT" 2>&1)" && return 0
  case "$_oi" in
    "No receipt for"*) ;;
    *) printf '%s\n' "$_oi" >&2; return 2 ;;
  esac
  [ -d "$1/Library/Filesystems/osxfuse.fs" ] || return 1
}

upstream_dir_removable() {
  case "/$1/" in */*.fs/*|*/*.framework/*|*/*.prefPane/*|*/*.kext/*|*/*.app/*|*/*.bundle/*|*/*.plugin/*) return 0 ;; esac
  printf '%s\n' "$MACFUSE_LINKS" | awk -v d="$1" '$1 == d || index(d, $1 "/") == 1 { found = 1 } END { exit !found }'
}

# spec: 2026-11-18-macfuse-design.md "Takeover" step 4 -- exactly the receipts' files and links; then their directories
#       that are left empty, inside a bundle or at or under a path a link of ours occupies, so that no real directory is
#       left where the payload puts a link; then the two receipts, forgotten
remove_upstream_receipts() {
  _listed="$(upstream_receipt_paths "$1")" || { echo "macFUSE for Mavericks: cannot read upstream macFUSE's receipts; fix the pkgutil error above, then $2." >&2; return 1; }
  printf '%s\n' "$_listed" | {
    _bad=0
    while IFS= read -r _p; do
      case "/$_p/" in //|*/../*|*/./*) continue ;; esac
      _a="$1/$_p"
      if [ -L "$_a" ] || { [ -e "$_a" ] && [ ! -d "$_a" ]; }; then
        rm -f "$_a" || _bad=1
      fi
    done
    [ "$_bad" -eq 0 ]
  } || { echo "macFUSE for Mavericks: could not remove every file of upstream macFUSE (see above); fix that, then $2." >&2; return 1; }
  printf '%s\n' "$_listed" | awk '{ print length($0) "\t" $0 }' | sort -rn | cut -f 2- | while IFS= read -r _p; do
    case "/$_p/" in //|*/../*|*/./*) continue ;; esac
    _a="$1/$_p"
    if [ -d "$_a" ] && [ ! -L "$_a" ] && upstream_dir_removable "$_p"; then rmdir "$_a" 2>/dev/null || :; fi
  done
  _left="$(printf '%s\n' "$MACFUSE_LINKS" | while read -r _p _t; do
    if [ -n "$_p" ] && [ ! -L "$1/$_p" ] && [ -e "$1/$_p" ]; then printf '  /%s\n' "$_p"; fi
  done)"
  if [ -n "$_left" ]; then
    printf 'macFUSE for Mavericks: these paths, where it installs links, still hold upstream files after removing them:\n%s\nRemove them, then %s.\n' "$_left" "$2" >&2
    return 1
  fi
  for _id in $MACFUSE_UPSTREAM_RECEIPTS; do
    pkgutil --volume "$1/" --pkg-info "$_id" > /dev/null 2>&1 || continue
    pkgutil --volume "$1/" --forget "$_id" > /dev/null ||
      { echo "macFUSE for Mavericks: could not forget the receipt $_id; run: sudo pkgutil --forget $_id, then $2." >&2; return 1; }
  done
}

# spec: 2026-11-18-macfuse-design.md "Takeover" step 5 -- upstream's own updater or launch jobs, if present
remove_upstream_launchd() {
  for _j in "$1"/Library/LaunchAgents/io.macfuse.*.plist "$1"/Library/LaunchDaemons/io.macfuse.*.plist; do
    [ -f "$_j" ] || [ -L "$_j" ] || continue
    if [ -z "$1" ]; then
      case "$_j" in */LaunchDaemons/*) launchctl unload "$_j" 2>/dev/null || : ;; esac
    fi
    rm -f "$_j" || { echo "macFUSE for Mavericks: cannot remove upstream's $_j; remove it, then $2." >&2; return 1; }
  done
}
