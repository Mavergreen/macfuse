/*
 * framework-fs -- a minimal GMUserFileSystem file system, built against macFUSE.framework as a
 * third-party one would be: one read-only directory holding hello.txt.
 *
 *   usage: framework-fs MOUNTPOINT
 *
 * It stays in the foreground until unmounted (umount MOUNTPOINT), then exits 0; a failed mount
 * exits 1. Built by build/build-framework.sh into EXAMPLES; run only on 10.9.
 */
#import <Foundation/Foundation.h>
#import <macFUSE/macFUSE.h>
#include <errno.h>

static NSString *const kHello = @"/hello.txt";

@interface HelloFS : NSObject
@property (nonatomic, assign) int status;
@end

@implementation HelloFS

- (NSData *)helloData {
  return [@"Hello from macFUSE.framework on 10.9\n" dataUsingEncoding:NSUTF8StringEncoding];
}

- (NSArray *)contentsOfDirectoryAtPath:(NSString *)path
            includingAttributesForKeys:(NSArray *)keys
                                 error:(NSError **)error {
  if (![path isEqualToString:@"/"]) {
    *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOENT userInfo:nil];
    return nil;
  }
  NSDictionary *attrs = [self attributesOfItemAtPath:kHello userData:nil error:error];
  return @[ [GMDirectoryEntry directoryEntryWithName:[kHello lastPathComponent] attributes:attrs] ];
}

- (NSDictionary *)attributesOfItemAtPath:(NSString *)path userData:(id)userData error:(NSError **)error {
  if ([path isEqualToString:@"/"])
    return @{ NSFileType: NSFileTypeDirectory, NSFilePosixPermissions: @0555 };
  if ([path isEqualToString:kHello])
    return @{ NSFileType: NSFileTypeRegular, NSFilePosixPermissions: @0444,
              NSFileSize: @([[self helloData] length]) };
  *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOENT userInfo:nil];
  return nil;
}

- (NSData *)contentsAtPath:(NSString *)path {
  return [path isEqualToString:kHello] ? [self helloData] : nil;
}

- (void)mountFailed:(NSNotification *)note {
  NSLog(@"framework-fs: mount failed: %@", [[note userInfo] objectForKey:kGMUserFileSystemErrorKey]);
  self.status = 1;
  CFRunLoopStop(CFRunLoopGetMain());
}

- (void)didUnmount:(NSNotification *)note {
  CFRunLoopStop(CFRunLoopGetMain());
}

@end

int main(int argc, char *argv[]) {
  @autoreleasepool {
    if (argc != 2) {
      fprintf(stderr, "usage: framework-fs MOUNTPOINT\n");
      return 2;
    }
    HelloFS *fs = [[HelloFS alloc] init];
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:fs selector:@selector(mountFailed:) name:kGMUserFileSystemMountFailed object:nil];
    [center addObserver:fs selector:@selector(didUnmount:) name:kGMUserFileSystemDidUnmount object:nil];
    GMUserFileSystem *ufs = [[GMUserFileSystem alloc] initWithDelegate:fs isThreadSafe:YES];
    [ufs mountAtPath:[NSString stringWithUTF8String:argv[1]]
         withOptions:@[ @"volname=framework-fs", @"rdonly" ]
    shouldForeground:YES
     detachNewThread:YES];
    CFRunLoopRun();
    int status = fs.status;
    [center removeObserver:fs];
    [ufs release];
    [fs release];
    return status;
  }
}
