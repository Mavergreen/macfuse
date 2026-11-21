# macFUSE for Mavericks: details

The [README](README.md) covers installing and using it. This is everything else.

So far it has been tested only on Mac OS X 10.9.5 (build 13F1911), in a virtual machine.

## Install

Install [Recaulk](https://github.com/Mavergreen/recaulk/releases) first, at the version this
release's notes name under "Before you update", or later; its latest release works. The installer
refuses to go on without Recaulk, and names the version it needs when the installed one is older:
the kernel extension links Recaulk's kernel back-fill, and the mount helper loads its system
library. The product installs only on Mac OS X 10.9; on a newer macOS, install
[macFUSE](https://macfuse.github.io) itself.

Everything installs under `/usr/local/mavergreen/macfuse/`. Links at upstream's own paths point
into it, so programs and builds that expect macFUSE find it where they always have:

- `/Library/Filesystems/macfuse.fs` and `/Library/Frameworks/macFUSE.framework`
- `/usr/local/lib/libfuse.2.dylib`, `libfuse.dylib`, `libfuse.la`, `libfuse3.4.dylib`, `libfuse3.dylib`,
  and `pkgconfig/fuse.pc` and `fuse3.pc`
- `/usr/local/include/fuse.h`, `fuse/` and `fuse3/`

The kernel extension loads the first time something mounts. An updater checks for new releases
once a day. To remove the product, unmount every FUSE volume, then run
`sudo mavergreen uninstall macfuse`; it refuses while a FUSE volume is mounted, and unloads the kernel
extension.

## Coming from macFUSE 4

If upstream macFUSE 4.x is installed, installing this takes it over:

- The installer refuses, and changes nothing, while any FUSE volume is mounted. Unmount them
  (`umount PATH`, or eject them in the Finder), then run it again.
- It also refuses if one of upstream's paths holds a file that no macFUSE installer receipt lists. It
  never overwrites a file it cannot account for; move such files aside and run it again.
- It unloads upstream's kernel extension, removes exactly the files upstream's core and preference
  pane receipts list, forgets those two receipts, and removes upstream's `io.macfuse.*` launch agents
  and daemons. The macFUSE preference pane goes with them.
- It leaves sshfs alone: its binary and its receipt stay, and it keeps working against this libfuse 2
  when run in the foreground (below).
- The osxfuse compatibility names that macFUSE 4 installed (`/Library/Frameworks/OSXFUSE.framework`,
  `/usr/local/lib/libosxfuse.2.dylib` and `libosxfuse_i64.2.dylib`) come back as links to this
  product's framework and libfuse 2.
- Programs built against macFUSE 4's libfuse 2 keep working: it has the same install name and
  compatibility version.
- sshfs 2.x and other libfuse file systems no longer put themselves in the background after
  mounting. They stop with "forking after mount is not supported", which is upstream macFUSE 5's
  libfuse. Run them with `-f` and background them yourself, for example `sshfs host: ~/mnt -f &`.
- Each mount of a multithreaded file system prints "fuse: forking a threaded process is unsafe" once.
  It is harmless: it is upstream's diagnostic, and the forked child only starts `mount_macfuse`.

Uninstalling this product does not bring macFUSE 4 back.

## Coming from osxfuse 3

The installer refuses to install beside osxfuse 3 (FUSE for macOS 3.x), and changes nothing: osxfuse
3's own `OSXFUSE.framework` and `libosxfuse` libraries are where this product puts its compatibility
links. Uninstall osxfuse 3 first, with the Remove button in its pane in System Preferences, or by
removing what its `com.github.osxfuse.pkg.*` receipts list (`pkgutil --only-files --files ID`) and forgetting
them (`sudo pkgutil --forget ID`). Keep `com.github.osxfuse.pkg.SSHFS`, which is sshfs. Then run the
installer again.

## Known limits

- **Updates wait until nothing is mounted.** The installer refuses an update while a FUSE volume is
  mounted, because the kernel extension cannot unload. Until the family's updater can say so,
  Installer reports a generic failure; the updater tries again at its next check.
- **A missing kernel extension gets upstream's wrong message.** If the product's `macfuse.kext` is
  missing, mounting fails and upstream's notice says "Unsupported macOS Version" and that the installed
  macFUSE is too old. Reinstall the product. If Recaulk's kernel extension is missing instead, the mount
  fails with "the file system is not available" and no notice.
- **`mount_macfuse` can crash when run by hand.** Upstream's `mount_macfuse` crashes when
  `_FUSE_DAEMON_PATH` is unset and the mount fails. libfuse always sets it, so file systems are not
  affected.
- **Change notifications are unreliable for changes made outside the mount.** A kqueue watcher on a
  FUSE volume (the Finder, `tail -f`) saw such a change at the next open through the mount in most
  trials, but not all. Writes made through the mount always notify.
- **`diskutil info` cannot see a macFUSE volume.** `diskutil unmount PATH` and `umount PATH` work.
- **A rejected mount option holds a device for about 60 seconds.** When libfuse rejects a mount
  option (sshfs 2.x, for example), no volume appears, but `mount_macfuse` keeps its `/dev/macfuseN`
  until the kernel gives up on it, about a minute later.
- **A killed file system's volume stays mounted.** I/O on it fails at once, and nothing hangs.
  `umount PATH` clears it.
- **No Swift `FileAttributeKey` properties.** `macFUSE.framework` lacks upstream's 16 Swift-only
  `FileAttributeKey` properties (see below). Every `kGMUserFileSystem*Key` constant they wrap is
  there.
- **Links point at the boot volume.** The links at upstream's paths are absolute, so installing onto
  a volume other than the startup disk makes them point at the startup disk's
  `/usr/local/mavergreen/macfuse`.
- **Installing resets `/usr/local/lib` and `/usr/local/include`** to owner root:wheel, mode 755, as
  upstream's installer does. If a package manager made them yours or group-writable, set them back.

## MFMount is a C stand-in

Upstream's `MFMount.framework` is Swift that needs the Foundation, Dispatch, OSLog, System and XPC
overlays and the swift-atomics and swift-collections packages, which the family's Swift toolchain
lacks. Both libfuses link it, so this port builds `mfmount/device.c` instead: a C reimplementation of
the device-channel half that libfuse's kernel path uses. It exports the same 34 names (`_MF*`,
`__MF*`) at upstream's install name and versions, and upstream's `Bridge/Trampoline.c` is compiled
unchanged on top of it. `tests/mfmount-exports-test.sh` compares the exported names with upstream's
x86_64 slice, so API drift in a new upstream release turns CI red. `MFMount()` (the FSKit backend)
returns `MFMountResultUnsupporteOSVersion`, as upstream does below macOS 15.4.

It differs from upstream in four ways:

- Closing a channel also wakes kqueue waiters; upstream only closes the descriptor.
- A closed channel reports `ENODEV`; upstream would call into the closed descriptor.
- It logs to stderr only, never `os_log`; upstream also writes to stderr.
- Its signal sources hold a strong reference to the channel (upstream's are weak), so a channel
  released without `MFChannelClose` leaks its descriptor and armed sources. libfuse always closes first.

## macFUSE.framework is Objective-C only

`macFUSE.framework` is built from upstream's Objective-C sources at upstream's install name,
versions and bundle identifier, with upstream's headers and module map, and exports the same 46
Objective-C classes and constants as upstream's x86_64 slice (`tests/framework-exports-test.sh`).
Upstream also compiles one Swift file, `NSFileManager.swift`, which adds 16 `FileAttributeKey`
properties (`.flags`, `.accessDate`, `.systemVolumeName` and so on) for Swift callers. That Swift-only
extension is absent until the Swift overlays are ported to 10.9; the `kGMUserFileSystem*Key`
constants it wraps are all present. The framework links no `/usr/lib/swift` library.

It differs from upstream in two more ways:

- It has no DTrace probes: upstream's `macfuse_objc:::delegate-entry` probe is compiled out.
- Upstream's headers use annotations newer than the 10.9 SDK (nullability macros, `NSFileAttributeKey`,
  generic collections). The framework ships those headers unchanged, so a file system built against
  it with the 10.9 SDK needs what `build/build-framework.sh` uses to build `tests/framework-fs`:
  `framework/sdk109-prelude.h` and copies of the headers without the collections' type arguments.
  Building with a newer SDK and `-mmacosx-version-min=10.9` needs neither.
