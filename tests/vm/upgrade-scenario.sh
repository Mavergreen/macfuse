#!/bin/sh
# platform: macOS-only -- installs pkgs over a mounted FUSE volume on a Mac OS X 10.9 guest (the acceptance job's Scenario B)
# spec: 2026-11-18-macfuse-design.md "Takeover" ("Upgrading our own product uses the same mounted-volume refusal and kext unload")
#       and 2026-11-19-macfuse-product/task-11-brief.md Scenario B -- with OLD_PKG installed and a volume mounted from it, the
#       run's pkg is refused, saying to unmount, and changes nothing; unmounted, it installs, the old kext is unloaded, and the
#       next mount loads the kext anew at the run's upstream version. Every wait is bounded; on any exit it unmounts and
#       kills what it started, and on a failing one unloads the kexts it loaded.
#   usage: upgrade-scenario.sh OLD_PKG NEW_PKG NEW_VERSION BINDIR
#          OLD_PKG is the previous published release's pkg (by hand, any earlier build); Recaulk and its back-fill kext must
#          already be installed. BINDIR holds hello3. Needs passwordless sudo.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/../.." && pwd)}"
. "$HERE/lib.sh"
cleanup_on_exit
case "$(sw_vers -productVersion 2>/dev/null)" in 10.9*) ;; *) echo "not Mac OS X 10.9 -- skipping"; exit 77 ;; esac
[ $# -eq 4 ] || { echo "usage: $0 OLD_PKG NEW_PKG NEW_VERSION BINDIR" >&2; exit 2; }
OLD=$1; NEW=$2; VERSION=$3; BIN="$(cd "$4" && pwd)" || fail "no $4"
sudo -n true 2>/dev/null || { echo "upgrade-scenario: needs passwordless sudo for installer" >&2; exit 1; }
[ -f /Library/Extensions/RecaulkKPI.kext/Contents/Info.plist ] || fail "Recaulk's back-fill kext is not installed"
mkdir -p "$SMOKE_LOGS"
M=/private/tmp/macfuse-smoke/mnt/upgrade
mkdir -p "$M"
track_mount "$M"
kext_index() { kextstat -l | awk '$6 == "io.macfuse.filesystems.macfuse.21" { print $1 }'; }

echo "== the earlier release, mounted"
must 900 "the earlier pkg did not install" sudo installer -pkg "$OLD" -target / > "$SMOKE_LOGS/install-old.log" 2>&1
old_v="$(manifest_version "$MACFUSE_PREFIX")"
is_mounted "$M" && fail "$M is already mounted before hello3 starts"
"$BIN/hello3" "$M" -f > "$SMOKE_LOGS/upgrade-hello3.log" 2>&1 &
H=$!
track_pid "$H"
wait_mounted "$M" 30 "$H"
kill -0 "$H" 2>/dev/null || fail "hello3 is gone, though $M is mounted"
[ "$(bounded 30 cat "$M/hello")" = "Hello World!" ] || fail "reading hello3 under $old_v"
idx_old="$(kext_index)"
[ -n "$idx_old" ] || fail "no macfuse kext loaded under $old_v"
ok "$old_v installed, hello3 mounted, kext at index $idx_old"

echo "== the run's pkg, while mounted: refused"
bounded 900 sudo installer -pkg "$NEW" -target / > "$SMOKE_LOGS/install-refused.log" 2>&1
rc=$?
[ "$rc" -ne 124 ] || fail "installer hung for 900 s with a FUSE volume mounted"
[ "$rc" -ne 0 ] || fail "the run's pkg installed while a FUSE volume was mounted"
sudo -n tail -n 80 /var/log/install.log > "$SMOKE_LOGS/install-refused-detail.log" 2>&1
grep -q "these FUSE volumes are mounted" "$SMOKE_LOGS/install-refused-detail.log" || fail "the refusal does not say which volumes are mounted"
grep -qF "$M" "$SMOKE_LOGS/install-refused-detail.log" || fail "the refusal does not name $M"
grep -q "Unmount them" "$SMOKE_LOGS/install-refused-detail.log" || fail "the refusal does not say to unmount"
[ "$(manifest_version "$MACFUSE_PREFIX")" = "$old_v" ] || fail "the refused install changed the manifest"
is_mounted "$M" || fail "the refused install unmounted $M"
[ "$(bounded 30 cat "$M/hello")" = "Hello World!" ] || fail "hello3 stopped answering after the refused install"
[ "$(kext_index)" = "$idx_old" ] || fail "the refused install reloaded the kext"
ok "refused: $(grep -m1 "these FUSE volumes are mounted" "$SMOKE_LOGS/install-refused-detail.log" | sed 's/^.*macFUSE for Mavericks: //')"

echo "== unmounted: the run's pkg installs"
umount_mp "$M"
wait_exit "$H" 30 || fail "hello3 did not exit"
bounded 900 sudo installer -pkg "$NEW" -target / > "$SMOKE_LOGS/install-new.log" 2>&1 ||
  { sudo -n tail -n 60 /var/log/install.log > "$SMOKE_LOGS/install.log"; fail "the run's pkg did not install with nothing mounted"; }
[ "$(manifest_version "$MACFUSE_PREFIX")" = "$VERSION" ] || fail "the manifest says '$(manifest_version "$MACFUSE_PREFIX")', not $VERSION"
kext_loaded io.macfuse.filesystems.macfuse.21 && fail "the upgrade left the earlier kext loaded"
is_mounted "$M" && fail "$M is still mounted before the new hello3 starts"
"$BIN/hello3" "$M" -f > "$SMOKE_LOGS/upgrade-hello3-new.log" 2>&1 &
H=$!
track_pid "$H"
wait_mounted "$M" 30 "$H"
kill -0 "$H" 2>/dev/null || fail "hello3 is gone, though $M is mounted"
[ "$(bounded 30 cat "$M/hello")" = "Hello World!" ] || fail "reading hello3 under $VERSION"
idx_new="$(kext_index)"
[ -n "$idx_new" ] && [ "$idx_new" != "$idx_old" ] || fail "the kext was not loaded anew (index '$idx_new', was $idx_old)"
want="$(tr -d '[:space:]' < "$REPO_ROOT/UPSTREAM_VERSION")"
[ "$(sysctl -n vfs.generic.macfuse.version.number)" = "$want" ] || fail "vfs.generic.macfuse.version.number is not $want"
umount_mp "$M"
wait_exit "$H" 30 || fail "hello3 did not exit"
ok "upgraded $old_v -> $VERSION; the kext reloaded (index $idx_old -> $idx_new) at $want"
