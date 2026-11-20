#!/bin/sh
# platform: macOS-only -- installs pkgs and mounts sshfs on a Mac OS X 10.9 guest (the acceptance job's Scenario C)
# spec: 2026-11-18-macfuse-design.md "Takeover of an existing upstream install" and 2026-11-19-macfuse-product/task-11-brief.md
#       Scenario C -- on a guest where upstream macFUSE 4.0.5 (core and preferencepane receipts) and an sshfs are installed:
#       install Recaulk, then the run's pkg; 4.0.5's two receipts are gone and nothing they listed is left except our
#       links; the sshfs binary is byte-identical and its receipt remains; an io.macfuse.installer.components.sshfs
#       receipt -- upstream's own sshfs component, which no pinnable installer for 10.9 carries, so a marker pkg with that
#       identifier is built here -- survives with its file; the untouched sshfs mounts the guest's own sshd with
#       -o volname=t,noappledouble and reads and writes. Leaves the product installed, nothing mounted and no FUSE or
#       Recaulk kext loaded, so tests/smoke-mavericks.sh can follow on the same guest. Every wait is bounded; on any exit
#       it unmounts sshfs, kills it and removes a key it authorized; on a failing one it unloads the kexts it loaded.
#   usage: takeover-scenario.sh VERSION PKG RECAULK_PKG [RECAULK_KPI_KEXT]
#          VERSION is the run's version; PKG its macfuse-VERSION.pkg; RECAULK_PKG the pinned Recaulk release's pkg.
#          RECAULK_KPI_KEXT, given only by hand, installs a RecaulkKPI.kext linked outside a release; the job never
#          passes it, so the kext must come from the Recaulk release's pkg. Needs passwordless sudo.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/../.." && pwd)}"
export REPO_ROOT
. "$REPO_ROOT/build/lib.sh"
. "$HERE/lib.sh"
cleanup_on_exit
case "$(sw_vers -productVersion 2>/dev/null)" in 10.9*) ;; *) echo "not Mac OS X 10.9 -- skipping"; exit 77 ;; esac
[ $# -eq 3 ] || [ $# -eq 4 ] || { echo "usage: $0 VERSION PKG RECAULK_PKG [RECAULK_KPI_KEXT]" >&2; exit 2; }
VERSION=$1; PKG=$2; RPKG=$3; KPI="${4:-}"
sudo -n true 2>/dev/null || { echo "takeover-scenario: needs passwordless sudo for installer" >&2; exit 1; }
mkdir -p "$SMOKE_LOGS"
UP_CORE=io.macfuse.installer.components.core
UP_PREF=io.macfuse.installer.components.preferencepane
SSHFS=/usr/local/bin/sshfs
UP_SSHFS=io.macfuse.installer.components.sshfs
MARKER=/usr/local/share/macfuse-test/components-sshfs.marker

echo "== before: upstream 4.0.5 and sshfs"
pkgutil --pkg-info "$UP_CORE" > /dev/null 2>&1 || fail "upstream's $UP_CORE receipt is not installed"
pkgutil --pkg-info "$UP_PREF" > /dev/null 2>&1 || fail "upstream's $UP_PREF receipt is not installed"
[ "$(pkgutil --pkg-info "$UP_CORE" | awk '/^version:/ { print $2 }')" = 4.0.5 ] || fail "upstream's core receipt is not 4.0.5"
pkgutil --files "$UP_CORE" > "$SMOKE_LOGS/core-files.txt" || fail "pkgutil --files $UP_CORE"
pkgutil --files "$UP_PREF" > "$SMOKE_LOGS/pref-files.txt" || fail "pkgutil --files $UP_PREF"
[ -x "$SSHFS" ] || fail "no $SSHFS"
sshfs_sum="$(shasum -a 256 "$SSHFS" | awk '{ print $1 }')"
# spec: 2026-11-18-macfuse-design.md "Takeover" step 4 -- whatever receipt installed sshfs (macFUSE's components.sshfs,
#       osxfuse's com.github.osxfuse.pkg.SSHFS) is left alone; a hand-copied sshfs has none, and then there is none to keep
sshfs_receipts="$(pkgutil --file-info "$SSHFS" 2>/dev/null | awk '/^pkgid:/ { print $2 }' | sort -u)"
echo "sshfs $sshfs_sum, receipts: ${sshfs_receipts:-none}"
echo "loaded before the install: $(kextstat -l | awk '$6 ~ /macfuse|recaulk/ { printf "%s ", $6 }')"
# spec: task-11-report.md "Fix round 1" (5) -- the takeover forgets only core and preferencepane inside upstream's
#       io.macfuse.installer.components.* namespace, and must keep its sshfs component; a marker pkg stands in for it
if ! pkgutil --pkg-info "$UP_SSHFS" > /dev/null 2>&1; then
  R="$SMOKE_LOGS/sshfs-marker"
  safe_rm "$R"
  mkdir -p "$R/root$(dirname "$MARKER")" || fail "mkdir $R"
  echo "stands in for upstream's sshfs component (tests/vm/takeover-scenario.sh)" > "$R/root$MARKER"
  must 120 "pkgbuild of the $UP_SSHFS marker" pkgbuild --quiet --root "$R/root" --identifier "$UP_SSHFS" --version 2.5.0.1 \
    --install-location / "$R/components-sshfs.pkg"
  must 600 "installing the $UP_SSHFS marker pkg" sudo installer -pkg "$R/components-sshfs.pkg" -target / > "$SMOKE_LOGS/install-sshfs-marker.log" 2>&1
fi
pkgutil --files "$UP_SSHFS" > "$SMOKE_LOGS/sshfs-component-files.txt" || fail "pkgutil --files $UP_SSHFS"
up_sshfs_file="$(while IFS= read -r f; do [ -f "/$f" ] && [ ! -h "/$f" ] && echo "/$f"; done < "$SMOKE_LOGS/sshfs-component-files.txt" | head -n 1)"
[ -n "$up_sshfs_file" ] || fail "$UP_SSHFS lists no file that is present"
up_sshfs_sum="$(shasum -a 256 "$up_sshfs_file" | awk '{ print $1 }')"
echo "$UP_SSHFS: receipt present, $up_sshfs_file $up_sshfs_sum"

echo "== install Recaulk, then the run's pkg"
must 600 "Recaulk's pkg did not install" sudo installer -pkg "$RPKG" -target / > "$SMOKE_LOGS/install-recaulk.log" 2>&1
if [ -n "$KPI" ]; then
  sudo rm -rf /Library/Extensions/RecaulkKPI.kext && sudo cp -R "$KPI" /Library/Extensions/RecaulkKPI.kext &&
    sudo find /Library/Extensions/RecaulkKPI.kext -name '._*' -exec rm -f {} + &&
    sudo chown -R root:wheel /Library/Extensions/RecaulkKPI.kext &&
    sudo find /Library/Extensions/RecaulkKPI.kext -type d -exec chmod 755 {} + &&
    sudo find /Library/Extensions/RecaulkKPI.kext -type f -exec chmod 644 {} + &&
    sudo chmod 755 /Library/Extensions/RecaulkKPI.kext/Contents/MacOS/RecaulkKPI &&
    sudo touch /Library/Extensions || fail "could not install $KPI by hand"
  echo "RecaulkKPI.kext installed by hand from $KPI"
fi
[ -f /Library/Extensions/RecaulkKPI.kext/Contents/Info.plist ] ||
  fail "no /Library/Extensions/RecaulkKPI.kext: the Recaulk release must ship the kernel back-fill the kext links"
bounded 900 sudo installer -pkg "$PKG" -target / > "$SMOKE_LOGS/install-macfuse.log" 2>&1 ||
  { sudo tail -n 60 /var/log/install.log > "$SMOKE_LOGS/install.log"; fail "the run's pkg did not install over 4.0.5"; }
ok "installed $(basename "$PKG") over upstream 4.0.5"

echo "== after: the takeover"
[ "$(manifest_version "$MACFUSE_PREFIX")" = "$VERSION" ] || fail "manifest version is '$(manifest_version "$MACFUSE_PREFIX")', not $VERSION"
pkgutil --pkg-info "$UP_CORE" > /dev/null 2>&1 && fail "upstream's $UP_CORE receipt is still there"
pkgutil --pkg-info "$UP_PREF" > /dev/null 2>&1 && fail "upstream's $UP_PREF receipt is still there"
ok "4.0.5's core and preferencepane receipts are gone"
# spec: build/lib.sh MACFUSE_LINKS -- what is one of our links, or under one, is ours; a real directory may be shared
#       with others; anything else 4.0.5 listed that is still there is a leftover. Each link must point into our tree.
links="$(printf '%s\n' "$MACFUSE_LINKS" | awk '{ print "/" $1 }')"
for l in $links; do
  [ -h "$l" ] || fail "$l is not a link"
  case "$(readlink "$l")" in "$MACFUSE_PREFIX"/*) ;; *) fail "$l points to $(readlink "$l"), not into $MACFUSE_PREFIX" ;; esac
done
cat "$SMOKE_LOGS/core-files.txt" "$SMOKE_LOGS/pref-files.txt" | while IFS= read -r p; do
  [ -e "/$p" ] || [ -h "/$p" ] || continue
  under=0
  for l in $links; do case "/$p" in "$l"|"$l"/*) under=1 ;; esac; done
  [ "$under" = 1 ] && continue
  [ -d "/$p" ] && [ ! -h "/$p" ] && continue
  printf '%s\n' "/$p"
done > "$SMOKE_LOGS/left-behind.txt"
[ ! -s "$SMOKE_LOGS/left-behind.txt" ] || fail "4.0.5 files left behind: $(tr '\n' ' ' < "$SMOKE_LOGS/left-behind.txt")"
[ ! -e /Library/PreferencePanes/macFUSE.prefPane ] || fail "4.0.5's prefPane is still there"
[ -h /usr/local/lib/libfuse.2.dylib ] && [ "$(readlink /usr/local/lib/libfuse.2.dylib)" = "$MACFUSE_PREFIX/lib/libfuse.2.dylib" ] ||
  fail "/usr/local/lib/libfuse.2.dylib is not our link"
ok "nothing 4.0.5 listed is left except where our links stand"
[ "$(shasum -a 256 "$SSHFS" | awk '{ print $1 }')" = "$sshfs_sum" ] || fail "$SSHFS changed"
for r in $sshfs_receipts; do pkgutil --pkg-info "$r" > /dev/null 2>&1 || fail "sshfs's receipt $r is gone"; done
ok "sshfs and its receipt (${sshfs_receipts:-none}) are untouched"
pkgutil --pkg-info "$UP_SSHFS" > /dev/null 2>&1 || fail "the takeover removed the $UP_SSHFS receipt"
pkgutil --files "$UP_SSHFS" | cmp -s - "$SMOKE_LOGS/sshfs-component-files.txt" || fail "the $UP_SSHFS receipt's file list changed"
[ "$(shasum -a 256 "$up_sshfs_file" | awk '{ print $1 }')" = "$up_sshfs_sum" ] || fail "$up_sshfs_file changed or is gone"
ok "$UP_SSHFS: the receipt and $up_sshfs_file survive the takeover"

echo "== sshfs, untouched, to the guest's own sshd"
S=/private/tmp/macfuse-smoke/sshfs-remote
M=/private/tmp/macfuse-smoke/sshfs
is_mounted "$M" && fail "$M is already mounted before sshfs starts"
safe_rm "$S"
mkdir -p "$S" "$M" || fail "mkdir $S $M"
echo "written locally" > "$S/local.txt"
# spec: 2026-11-18-macfuse-spike-findings.md "Task 6" -- the guest's own ~/.ssh/config may be unusable (the VM's is an NFS
#       symlink), so ssh reads none (-F /dev/null), and never writes the user's known_hosts; a key is made only when
#       none already reaches localhost (the job's fresh guest), and only in the job's own directory
K="$SMOKE_LOGS/ssh"
mkdir -p "$K" && chmod 700 "$K"
SSHOPTS="-F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=$K/known_hosts"
# shellcheck disable=SC2086
if ! bounded 60 ssh $SSHOPTS localhost true 2>/dev/null; then
  [ -f "$K/id_rsa" ] || ssh-keygen -q -t rsa -b 2048 -N '' -f "$K/id_rsa" || fail "ssh-keygen"
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh" && cat "$K/id_rsa.pub" >> "$HOME/.ssh/authorized_keys" &&
    chmod 600 "$HOME/.ssh/authorized_keys" || fail "could not authorize the job's key"
  # spec: task-11-review.md Minor 9 -- the key is authorized for this run only
  AK_LINE="$(cat "$K/id_rsa.pub")"
  CLEAN_HOOK='grep -vxF "$AK_LINE" "$HOME/.ssh/authorized_keys" > "$HOME/.ssh/authorized_keys.mm$$"; mv "$HOME/.ssh/authorized_keys.mm$$" "$HOME/.ssh/authorized_keys"; chmod 600 "$HOME/.ssh/authorized_keys"'

  SSHOPTS="$SSHOPTS -i $K/id_rsa"
  # shellcheck disable=SC2086
  must 60 "the guest cannot ssh to itself (is Remote Login on?)" ssh $SSHOPTS localhost true
fi
# spec: upstream libfuse 2's lib/helper.c fuse_daemonize -- macFUSE 5.x refuses to fork once mounted ("forking after mount is
#       not supported") and stays in the foreground, and sshfs 2.x mounts before it daemonizes; so sshfs runs as -f, in the
#       background, as it would have to for any user of this libfuse
"$SSHFS" "localhost:$S" "$M" -f -o volname=t,noappledouble -o "ssh_command=ssh $SSHOPTS" > "$SMOKE_LOGS/sshfs.log" 2>&1 &
sshfs_pid=$!
track_pid "$sshfs_pid"; track_mount "$M"
wait_mounted "$M" 30 "$sshfs_pid"
mount | grep -F " on $M (" | grep -q macfuse || fail "the sshfs volume is not a macfuse mount: $(mount | grep -F " on $M (")"
vn="$(bounded 30 python "$HERE/volname.py" "$M" 2>&1)"
[ "$vn" = t ] || fail "the volume's name is '$vn', not t (volname=t)"
[ "$(bounded 30 cat "$M/local.txt")" = "written locally" ] || fail "reading through sshfs"
must 30 "writing through sshfs" sh -c 'echo "written through sshfs" > "$1"' sh "$M/remote.txt"
[ "$(cat "$S/remote.txt")" = "written through sshfs" ] || fail "the file written through sshfs is not on the remote side"
ls -a "$S" | grep -q '^\._' && fail "noappledouble did not keep ._ files off the remote side"
ok "sshfs reads and writes; nothing ._ was written"
umount_mp "$M"
wait_exit "$sshfs_pid" 30 || fail "sshfs did not exit after its volume was unmounted"
[ "$(fork_warnings "$SMOKE_LOGS/sshfs.log")" -le 1 ] || fail "sshfs.log has more than one fork warning for one mount"
ok "sshfs unmounted and exited"

echo "== leave nothing loaded for the smoke that follows"
for id in io.macfuse.filesystems.macfuse.21 dev.mavergreen.recaulk.kpi; do
  i=0
  while kext_loaded "$id" && [ "$i" -lt 30 ]; do bounded 60 sudo kextunload -b "$id" > /dev/null 2>&1 || sleep 1; i=$((i + 1)); done
  kext_loaded "$id" && fail "$id would not unload"
done
ok "takeover scenario"
