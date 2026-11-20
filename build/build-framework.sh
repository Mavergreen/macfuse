#!/bin/sh
# platform: host-agnostic
# spec: 2026-11-18-macfuse-design.md decision A -- macFUSE.framework is built from upstream's Objective-C only. What upstream's
#       Framework.xcodeproj and its 5.5.0 binary say (Step 1 of the Task 6 brief):
#   - Swift: Framework/Extensions/Foundation/NSFileManager.swift is the only Swift file. It extends
#     FileAttributeKey with 16 @_alwaysEmitIntoClient properties, so upstream's binary exports for it only
#     their 16 property descriptors (_$sSo18NSFileAttributeKeya7macFUSEE...MV) and links 8 /usr/lib/swift
#     libraries, libc++ and an LC_RPATH /usr/lib/swift for them. All three are absent here (README.md).
#   - Sources (PBXSourcesBuildPhase): GMDirectoryEntry.m, GMFinderInfo.m, GMResourceFork.m,
#     GMUserFileSystem.m, GMDataBackedFileDelegate.m, macfuse_objc_dtrace.d and NSFileManager.swift.
#     Public headers: GMAvailability.h, GMDirectoryEntry.h, GMFinderInfo.h, GMResourceFork.h,
#     GMUserFileSystem.h, macFUSE.h (GMDataBackedFileDelegate.h is a project header, not shipped). The
#     module map is generated: framework module macFUSE, umbrella header "macFUSE.h", export *.
#   - Settings: no CLANG_ENABLE_OBJC_ARC (manual retain/release), GCC_ENABLE_OBJC_EXCEPTIONS, c99,
#     GCC_SYMBOLS_PRIVATE_EXTERN (GM_EXPORT marks the API), ENABLE_STRICT_OBJC_MSGSEND,
#     _DARWIN_USE_64_BIT_INODE and _FILE_OFFSET_BITS=64, -lfuse from /usr/local, Foundation.
#   - Binary: install name /Library/Frameworks/macFUSE.framework/Versions/A/macFUSE, compatibility 1.0.0,
#     current 3.0.0; links /usr/local/lib/libfuse.2.dylib (12.0.0/12.9.0), Foundation, libobjc, libSystem,
#     CoreFoundation; bundle id io.macfuse.frameworks.macfuse, both bundle versions the release (5.5.0).
#   - Exports: 62 names, 46 of them not Swift: the 8 classes' _OBJC_CLASS_$_/_OBJC_METACLASS_$_ and 30
#     kGMUserFileSystem* constants.
#   usage: build-framework.sh SRC STAGE EXAMPLES
#          SRC holds the fetched upstream sources (build/fetch-sources.sh): SRC/framework. STAGE must already
#          hold libfuse 2 and its headers (build/build-libfuse.sh). Writes STAGE/<MACFUSE_PREFIX>/Frameworks/
#          macFUSE.framework at the upstream install name, versions and Info.plist identity, and the example
#          framework-fs (tests/framework-fs) into EXAMPLES. Fails, leaving no framework, on any error.
set -eu
[ $# -eq 3 ] || { echo "usage: $0 SRC STAGE EXAMPLES" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/.." && pwd)}"
export REPO_ROOT
. "$REPO_ROOT/build/lib.sh"
. "$REPO_ROOT/build/msc.sh"
SRC=$1
STAGE=$2
EX=$3
FS="$SRC/framework/Framework"
[ -f "$FS/GMUserFileSystem.m" ] && [ -f "$FS/macFUSE.h" ] || { echo "build-framework: no upstream Framework sources under $SRC/framework" >&2; exit 1; }
# spec: 2026-11-18-macfuse-design.md decision A assumed one Swift file; another means the ObjC-only framework may drop more than FileAttributeKey
swift="$(cd "$SRC/framework" && find . -name '*.swift' | LC_ALL=C sort)"
[ "$swift" = ./Framework/Extensions/Foundation/NSFileManager.swift ] || { echo "build-framework: upstream's Swift is not just NSFileManager.swift: $swift" >&2; exit 1; }
TREE="$STAGE$MACFUSE_PREFIX"
[ -f "$TREE/lib/libfuse.2.dylib" ] && [ -f "$TREE/include/fuse.h" ] || { echo "build-framework: no libfuse 2 in $TREE (build/build-libfuse.sh first)" >&2; exit 1; }
macfuse_toolchain build-framework || exit 1
CC="$CL/bin/clang"
INSTALL_DIR=/Library/Frameworks
FW="$TREE/Frameworks/macFUSE.framework"
mkdir -p "$(dirname "$FW")" "$EX"
W="$(mktemp -d "$BUILD/framework.XXXXXX")"
trap 'rm -rf "$W"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

OUT="$W/macFUSE.framework"
mkdir -p "$OUT/Versions/A/Headers" "$OUT/Versions/A/Resources" "$OUT/Versions/A/Modules"
for h in GMAvailability.h GMDirectoryEntry.h GMFinderInfo.h GMResourceFork.h GMUserFileSystem.h macFUSE.h; do
  cp "$FS/$h" "$OUT/Versions/A/Headers/$h"
done
printf '%s\n' 'framework module macFUSE {' '  umbrella header "macFUSE.h"' '  export *' '}' > "$OUT/Versions/A/Modules/module.modulemap"
ln -s A "$OUT/Versions/Current"
for n in Headers Modules Resources; do ln -s "Versions/Current/$n" "$OUT/$n"; done

# platform: the 10.9 SDK's collection classes take no type arguments (lightweight generics came with the 10.11 SDK), so
#           the sources and headers are compiled from copies with the type arguments removed (compile-time only: the
#           ABI and the exported names do not change); the framework ships upstream's headers unchanged
CS="$W/compile"
mkdir -p "$CS/src" "$CS/macFUSE.framework/Headers"
for f in "$FS"/*.h "$FS"/*.m; do
  sed -E -e ':a' -e 's/(NS(Mutable)?(Array|Dictionary|Set|OrderedSet))<[^<>;]*>/\1/g' -e 'ta' "$f" > "$CS/src/$(basename "$f")"
done
for h in GMAvailability.h GMDirectoryEntry.h GMFinderInfo.h GMResourceFork.h GMUserFileSystem.h macFUSE.h; do
  cp "$CS/src/$h" "$CS/macFUSE.framework/Headers/$h"
done

# platform: --no-default-config, because clang22's clang.cfg links its own librecaulk.a copy; the inputs are
#           exactly the 10.9 SDK, the pinned Recaulk headers and its whole librecaulk.a, last on the link
BASE="--no-default-config --target=x86_64-apple-macos10.9 -isysroot $SDK -isystem $RC/include/recaulk"
# platform: -F$CS for <macFUSE/...> from the compiled copies, as Xcode's built-products directory gives them;
#           -I$REPO_ROOT/framework for macfuse_objc_dtrace.h, the compiled-out probes dtrace -h would generate;
#           framework/sdk109-prelude.h for the declarations upstream's sources use that the 10.9 SDK lacks;
#           -fmodules as upstream's CLANG_ENABLE_MODULES, for the headers' @import Foundation; -fmodule-name=macFUSE includes
#           macFUSE's own headers textually (as Xcode does for the module being built), so the prelude reaches them;
#           no -fvisibility=hidden for GCC_SYMBOLS_PRIVATE_EXTERN: clang22 would then hide GMUserFileSystemInternal, which
#           upstream's binary exports; without it the exports are exactly upstream's non-Swift ones (tests/framework-exports-test.sh);
#           -fobjc-weak as upstream's CLANG_ENABLE_OBJC_WEAK, for its one __weak under manual reference counting;
#           -Os as Xcode's Release default, which upstream's project does not override
MODS="-fmodules -fmodule-name=macFUSE -fmodules-cache-path=$W/modules -Wno-deprecated-module-dot-map -include $REPO_ROOT/framework/sdk109-prelude.h"
OBJC="$BASE -x objective-c -std=c99 $MODS -fobjc-exceptions -fobjc-weak -DOBJC_OLD_DISPATCH_PROTOTYPES=0
      -D_DARWIN_USE_64_BIT_INODE -D_FILE_OFFSET_BITS=64 -Os -g -Wall -Wno-deprecated-declarations
      -F$CS -I$CS/src -I$REPO_ROOT/framework -I$TREE/include"
NM="$CL/bin/llvm-nm" sh "$REPO_ROOT/build/recaulk-unexported.sh" "$RC/lib/librecaulk.a" > "$W/unexported"
O=""
for f in GMDirectoryEntry.m GMFinderInfo.m GMResourceFork.m GMUserFileSystem.m GMDataBackedFileDelegate.m; do
  # shellcheck disable=SC2086
  "$CC" $OBJC -c "$CS/src/$f" -o "$W/${f%.m}.o"
  O="$O $W/${f%.m}.o"
done
# shellcheck disable=SC2086
"$CC" $BASE -fuse-ld=lld -dynamiclib \
  -install_name "$INSTALL_DIR/macFUSE.framework/Versions/A/macFUSE" \
  -compatibility_version 1.0.0 -current_version 3.0.0 \
  -Wl,-headerpad_max_install_names -Wl,-unexported_symbols_list,"$W/unexported" \
  $O -L"$TREE/lib" -lfuse.2 -framework Foundation -framework CoreFoundation -lobjc \
  "$RC/lib/librecaulk.a" -o "$OUT/Versions/A/macFUSE"
ln -s Versions/Current/macFUSE "$OUT/macFUSE"
sed -e "s|@VERSION@|$(upstream_version)|" -e 's|@MINIMUM_SYSTEM_VERSION@|10.9|' \
  "$REPO_ROOT/framework/Info.plist.in" > "$OUT/Versions/A/Resources/Info.plist"

# spec: 2026-11-19-macfuse-product task-6-brief.md -- a third-party file system built against the staged framework; upstream's headers need the prelude
#       and the copies above on the 10.9 SDK, as they need a 10.12 SDK or later elsewhere
# shellcheck disable=SC2086
"$CC" $BASE -x objective-c $MODS -Wno-atimport-in-framework-header -O2 -g -Wall -F"$CS" \
  -c "$REPO_ROOT/tests/framework-fs/main.m" -o "$W/framework-fs.o"
# shellcheck disable=SC2086
"$CC" $BASE -fuse-ld=lld "$W/framework-fs.o" -F"$W" -framework macFUSE -framework Foundation \
  "$RC/lib/librecaulk.a" -Wl,-unexported_symbols_list,"$W/unexported" -o "$W/framework-fs"

rm -rf "$FW"
mv "$OUT" "$FW"
mv -f "$W/framework-fs" "$EX/framework-fs"
echo "built $FW and $EX/framework-fs"
