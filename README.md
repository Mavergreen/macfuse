# macFUSE for Mavericks

**This README has not been read or edited by a human yet.** Until it has, this project cannot cut
its first release.

macFUSE for Mac OS X 10.9 Mavericks: upstream macFUSE's userspace libraries and tools, and its
kernel extension, adapted to run on 10.9 (x86_64 only).

It is an unofficial community port for the Mavergreen family. It is not affiliated with or endorsed
by the macFUSE project. Upstream's license is in `LICENSE`, including its clause 4: redistributing
the binary form bundled with commercial software is not allowed without upstream's written permission.

Everything installs under `/usr/local/mavergreen/macfuse/`, linked from upstream's usual paths.

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

It differs from upstream in three more ways:

- It has no DTrace probes: upstream's `macfuse_objc:::delegate-entry` probe is compiled out.
- Upstream's headers use annotations newer than the 10.9 SDK (nullability macros, `NSFileAttributeKey`,
  generic collections). The framework ships those headers unchanged, so a file system built against
  it with the 10.9 SDK needs what `build/build-framework.sh` uses to build `tests/framework-fs`:
  `framework/sdk109-prelude.h` and copies of the headers without the collections' type arguments.
  Building with a newer SDK and `-mmacosx-version-min=10.9` needs neither.
- The family's strict Objective-C check (`build/compat-guard.sh`) cannot measure it yet: Drydock's
  analyzer does not classify `objc_loadWeak`, does not follow an `objc_msgSend` pointer copied between
  registers, and does not resolve absolute install names such as `/usr/local/lib/libfuse.2.dylib`.
  The default compat guard passes.
