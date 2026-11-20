/*
 * sdk109-prelude.h -- the declarations upstream's framework sources and headers use that the
 * 10.9 SDK lacks, for compiling them unchanged (build/build-framework.sh passes
 * it with -include). Each is compile-time only: no symbol, no runtime behavior.
 *
 *   NS_ASSUME_NONNULL_BEGIN/END  the 10.11 SDK's spelling of clang's assume_nonnull pragma
 *   NS_SWIFT_NAME                the 10.11 SDK's swift_name attribute (Swift-only renaming)
 *   NSFileAttributeKey           the 10.12 SDK's typedef; the 10.9 SDK types NSFileType and
 *                                friends as NSString *, which is what the typedef names
 *   NSErrorUserInfoKey           the 10.13 SDK's typedef, likewise NSString *
 *   PREALLOCATE                  from <sys/vnode.h>, which newer SDKs reach through Foundation
 *   RENAME_SWAP, RENAME_EXCL     renamex_np(2)'s flags (the 10.12 SDK's <sys/stdio.h>), defined as
 *                                libfuse 2's lib/fuse.c defines them where the SDK lacks them
 */
#ifndef MACFUSE_SDK109_PRELUDE_H
#define MACFUSE_SDK109_PRELUDE_H

#import <Foundation/Foundation.h>

#ifndef NS_ASSUME_NONNULL_BEGIN
#define NS_ASSUME_NONNULL_BEGIN _Pragma("clang assume_nonnull begin")
#define NS_ASSUME_NONNULL_END _Pragma("clang assume_nonnull end")
#endif

#ifndef NS_SWIFT_NAME
#define NS_SWIFT_NAME(_name) __attribute__((swift_name(#_name)))
#endif

#if MAC_OS_X_VERSION_MAX_ALLOWED < 101200
typedef NSString *NSFileAttributeKey;
#endif

#if MAC_OS_X_VERSION_MAX_ALLOWED < 101300
typedef NSString *NSErrorUserInfoKey;
#endif

#include <sys/vnode.h>

#ifndef RENAME_SWAP
#define RENAME_SWAP 0x00000002
#endif
#ifndef RENAME_EXCL
#define RENAME_EXCL 0x00000004
#endif

#endif
