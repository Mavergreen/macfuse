/*
 * MFMount-Swift.h -- stands in for the header swiftc generates from MFMount's
 * @c(_MF...) functions, so that upstream's Bridge/Trampoline.c compiles
 * unchanged against device.c.
 */
#ifndef MFMOUNT_SWIFT_H
#define MFMOUNT_SWIFT_H

#include "MFMount.h"

MFTypeRef _MFRetain(MFTypeRef reference);
void _MFRelease(MFTypeRef reference);
ssize_t _MFMessageGetBodySize(MFMessageRef message);
ssize_t _MFMessageGetBodyBuffers(MFMessageRef message, const struct iovec **buffers);
ssize_t _MFMessageGetReplyBuffer(MFMessageRef message, void **buffer);
MFChannelRef _MFChannelCreate(void);
MFChannelRef _MFChannelCreateWithDeviceFileDescriptor(int fileDescriptor);
int _MFChannelGetFileDescriptor(MFChannelRef channel);
bool _MFChannelGetFlags(MFChannelRef channel, MFChannelFlags *flags);
bool _MFChannelSetFlags(MFChannelRef channel, MFChannelFlags flags);
bool _MFChannelInterrupt(MFChannelRef channel);
int32_t _MFChannelWaitForNextMessage(MFChannelRef channel, int32_t timeout);
MFMessageRef _MFChannelCopyNextMessage(MFChannelRef channel);
ssize_t _MFChannelSendMessage(MFChannelRef channel, const struct iovec *buffers, size_t count);
bool _MFChannelClose(MFChannelRef channel);
MFMountResult _MFMount(MFChannelRef channel, const char *mountPoint, const char *options, bool quiet);

#endif
