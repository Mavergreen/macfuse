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
