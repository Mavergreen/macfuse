/*
 * device.c -- spike replacement for MFMount's Swift implementation, 10.9 only.
 *
 * macFUSE 5.5.0's MFMount (macfuse/mount 395aa1b) is Swift that needs the
 * Foundation, Dispatch, OSLog, System and XPC Swift overlays plus the
 * swift-atomics and swift-collections packages. The Mavergreen Swift
 * toolchain has none of them, so the framework cannot be built for 10.9 as
 * written (see findings, Task 5a).
 *
 * The kernel backend only uses MFMount's device-channel half: libfuse execs
 * mount_macfuse, receives the /dev/macfuseN fd, wraps it with
 * MFChannelCreateWithDeviceFileDescriptor() and then reads/writes it through
 * the MFChannel and MFMessage functions. This file reimplements exactly that
 * half in C, following Channel/Channel.swift, Channel/Device/DeviceTransport.swift,
 * Channel/Device/DeviceMessage.swift, the Bridge Swift files and Parameters.swift.
 * Upstream's Bridge/Trampoline.c is compiled unchanged on top of it: it
 * provides the exported MF* names and calls the _MF* names defined here, as it
 * calls the Swift @c(_MF...) functions upstream.
 *
 * MFMount() (the FSKit/XPC backend) does what upstream does on any macOS
 * older than 15.4: it returns MFMountResultUnsupporteOSVersion. So Mounter's
 * install() and the XPC peer-signature check are never reached, as upstream.
 */

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/ioctl.h>
#include <sys/uio.h>
#include <unistd.h>

#include <dispatch/dispatch.h>

#include "MFMount-Swift.h"

/* Apple Generic Versioning symbols Xcode generates (MARKETING_VERSION 2.4, CURRENT_PROJECT_VERSION 6). */
const double MFMountVersionNumber = 6;
const unsigned char MFMountVersionString[] = "@(#)PROGRAM:MFMount  PROJECT:MFMount-6\n";

/* Parameters.deviceMessageBufferByteCount: 4 KiB structured + 32 MiB payload. */
#define MF_DEVICE_MESSAGE_BUFFER_BYTE_COUNT 0x2001000

/* FUSEDEVIOCINTERRUPTREADERS _IO('F', 6), DeviceTransport.interruptReadersCommand */
#define MF_FUSEDEVIOCINTERRUPTREADERS 0x20004606UL

enum mf_kind { MF_KIND_CHANNEL = 0x4d464348, MF_KIND_MESSAGE = 0x4d464d53 };

struct mf_object {
	uint32_t kind;
	atomic_int refcount;
};

enum mf_channel_state { MF_UNOPENED, MF_OPEN, MF_CLOSED };

#define MF_NSIGNALS 4
static const int mf_interrupt_signals[MF_NSIGNALS] = { SIGHUP, SIGINT, SIGPIPE, SIGTERM };

struct mf_channel {
	struct mf_object obj;
	pthread_mutex_t lock;
	enum mf_channel_state state;
	int fd;
	int *waiters;           /* kqueues blocked in wait */
	size_t nwaiters, capwaiters;
	dispatch_source_t signal_sources[MF_NSIGNALS];
};

struct mf_message {
	struct mf_object obj;
	void *buffer;
	struct iovec body;
};

static void mf_log(const char *function, const char *message, int error)
{
	if (error)
		fprintf(stderr, "MFMount: %s: %s: %s\n", function, message, strerror(error));
	else
		fprintf(stderr, "MFMount: %s: %s\n", function, message);
}

static void *mf_unwrap(MFTypeRef reference, uint32_t kind)
{
	struct mf_object *obj = reference;
	if (obj == NULL || obj->kind != kind)
		return NULL;
	return obj;
}

/* Bridge.perform: errno = 0 on success, errno = error on failure. */
#define MF_OK(value)        do { errno = 0; return (value); } while (0)
#define MF_FAIL(err, value) do { errno = (err); return (value); } while (0)

/* ------------------------------------------------------------------ objects */

static void mf_channel_destroy(struct mf_channel *ch);

MFTypeRef _MFRetain(MFTypeRef reference)
{
	struct mf_object *obj = reference;
	atomic_fetch_add_explicit(&obj->refcount, 1, memory_order_relaxed);
	return reference;
}

void _MFRelease(MFTypeRef reference)
{
	struct mf_object *obj = reference;
	if (atomic_fetch_sub_explicit(&obj->refcount, 1, memory_order_acq_rel) != 1)
		return;
	if (obj->kind == MF_KIND_CHANNEL) {
		mf_channel_destroy((struct mf_channel *)obj);
	} else if (obj->kind == MF_KIND_MESSAGE) {
		struct mf_message *msg = (struct mf_message *)obj;
		free(msg->buffer);
		msg->obj.kind = 0;
		free(msg);
	} else {
		abort();
	}
}

/* ----------------------------------------------------------------- messages */

ssize_t _MFMessageGetBodySize(MFMessageRef message)
{
	struct mf_message *msg = mf_unwrap(message, MF_KIND_MESSAGE);
	if (msg == NULL) {
		mf_log(__func__, "Invalid argument message", 0);
		MF_FAIL(EINVAL, -1);
	}
	MF_OK((ssize_t)msg->body.iov_len);
}

ssize_t _MFMessageGetBodyBuffers(MFMessageRef message, const struct iovec **buffers)
{
	struct mf_message *msg = mf_unwrap(message, MF_KIND_MESSAGE);
	if (msg == NULL || buffers == NULL) {
		mf_log(__func__, "Invalid argument message", 0);
		MF_FAIL(EINVAL, -1);
	}
	*buffers = &msg->body;
	MF_OK(1);
}

ssize_t _MFMessageGetReplyBuffer(MFMessageRef message, void **buffer)
{
	struct mf_message *msg = mf_unwrap(message, MF_KIND_MESSAGE);
	if (msg == NULL || buffer == NULL) {
		mf_log(__func__, "Invalid argument message", 0);
		MF_FAIL(EINVAL, -1);
	}
	/* DeviceMessage.replyBuffer is nil. */
	*buffer = NULL;
	MF_OK(0);
}

/* ----------------------------------------------------------------- channels */

static int mf_channel_interrupt_locked_waiters(struct mf_channel *ch)
{
	int error = 0;
	struct kevent64_s ev;
	EV_SET64(&ev, 1, EVFILT_USER, 0, NOTE_TRIGGER, 0, 0, 0, 0);
	for (size_t i = 0; i < ch->nwaiters; i++) {
		if (kevent64(ch->waiters[i], &ev, 1, NULL, 0, 0, NULL) == -1 && error == 0)
			error = errno;
	}
	return error;
}

/* Channel.interrupt() + DeviceTransport.interrupt(); returns 0 or an errno. */
static int mf_channel_interrupt(struct mf_channel *ch)
{
	int error, fd;

	pthread_mutex_lock(&ch->lock);
	if (ch->state != MF_OPEN) {
		pthread_mutex_unlock(&ch->lock);
		return ch->state == MF_CLOSED ? ENODEV : 0;
	}
	error = mf_channel_interrupt_locked_waiters(ch);
	fd = ch->fd;
	pthread_mutex_unlock(&ch->lock);

	if (ioctl(fd, MF_FUSEDEVIOCINTERRUPTREADERS) == -1 && error == 0)
		error = errno;
	return error;
}

static void mf_signal_handler(void *context)
{
	(void)mf_channel_interrupt(context);
}

static void mf_signal_cancel_handler(void *context)
{
	_MFRelease(context);
}

static struct mf_channel *mf_channel_new(void)
{
	struct mf_channel *ch = calloc(1, sizeof(*ch));
	if (ch == NULL)
		return NULL;
	ch->obj.kind = MF_KIND_CHANNEL;
	atomic_init(&ch->obj.refcount, 1);
	pthread_mutex_init(&ch->lock, NULL);
	ch->state = MF_UNOPENED;
	ch->fd = -1;
	return ch;
}

/* Channel.resumeSignalSources(). Each source holds a reference until it is cancelled. */
static void mf_channel_resume_signal_sources(struct mf_channel *ch)
{
	dispatch_queue_t q = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
	for (int i = 0; i < MF_NSIGNALS; i++) {
		dispatch_source_t s = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,
		    (uintptr_t)mf_interrupt_signals[i], 0, q);
		if (s == NULL)
			continue;
		_MFRetain(ch);
		dispatch_set_context(s, ch);
		dispatch_source_set_event_handler_f(s, mf_signal_handler);
		dispatch_source_set_cancel_handler_f(s, mf_signal_cancel_handler);
		ch->signal_sources[i] = s;
		dispatch_resume(s);
	}
}

static void mf_channel_cancel_signal_sources(struct mf_channel *ch)
{
	for (int i = 0; i < MF_NSIGNALS; i++) {
		dispatch_source_t s = ch->signal_sources[i];
		if (s == NULL)
			continue;
		ch->signal_sources[i] = NULL;
		dispatch_source_cancel(s);
		dispatch_release(s);
	}
}

static void mf_channel_destroy(struct mf_channel *ch)
{
	pthread_mutex_destroy(&ch->lock);
	free(ch->waiters);
	ch->obj.kind = 0;
	free(ch);
}

MFChannelRef _MFChannelCreate(void)
{
	/* An unopened channel. Only MFMount() (FSKit) would ever open it. */
	struct mf_channel *ch = mf_channel_new();
	if (ch == NULL)
		MF_FAIL(ENOMEM, NULL);
	MF_OK(ch);
}

MFChannelRef _MFChannelCreateWithDeviceFileDescriptor(int fileDescriptor)
{
	struct mf_channel *ch;

	if (fileDescriptor < 0) {
		mf_log(__func__, "Invalid argument fileDescriptor", 0);
		MF_FAIL(EINVAL, NULL);
	}
	ch = mf_channel_new();
	if (ch == NULL)
		MF_FAIL(ENOMEM, NULL);
	ch->fd = fileDescriptor;
	ch->state = MF_OPEN;          /* DeviceTransport.activate() does nothing */
	mf_channel_resume_signal_sources(ch);
	MF_OK(ch);
}

/* Takes the lock; returns the open fd, or -1 with *error set. */
static int mf_channel_fd(struct mf_channel *ch, int closed_error, int *error)
{
	int fd;
	pthread_mutex_lock(&ch->lock);
	fd = ch->state == MF_OPEN ? ch->fd : -1;
	pthread_mutex_unlock(&ch->lock);
	if (fd < 0)
		*error = closed_error;
	return fd;
}

int _MFChannelGetFileDescriptor(MFChannelRef channel)
{
	struct mf_channel *ch = mf_unwrap(channel, MF_KIND_CHANNEL);
	int fd, error = 0;
	if (ch == NULL) {
		mf_log(__func__, "Invalid argument channel", 0);
		MF_FAIL(EINVAL, -1);
	}
	fd = mf_channel_fd(ch, ENOTSUP, &error);
	if (fd < 0)
		MF_FAIL(error, -1);
	MF_OK(fd);
}

bool _MFChannelGetFlags(MFChannelRef channel, MFChannelFlags *flags)
{
	struct mf_channel *ch = mf_unwrap(channel, MF_KIND_CHANNEL);
	int fd, fl, error = 0;
	if (ch == NULL || flags == NULL) {
		mf_log(__func__, "Invalid argument channel", 0);
		MF_FAIL(EINVAL, false);
	}
	fd = mf_channel_fd(ch, ENODEV, &error);
	if (fd < 0)
		MF_FAIL(error, false);
	fl = fcntl(fd, F_GETFL);
	if (fl == -1)
		MF_FAIL(errno, false);
	*flags = (fl & O_NONBLOCK) ? MFChannelFlagNonBlocking : MFChannelFlagNone;
	MF_OK(true);
}

bool _MFChannelSetFlags(MFChannelRef channel, MFChannelFlags flags)
{
	struct mf_channel *ch = mf_unwrap(channel, MF_KIND_CHANNEL);
	int fd, fl, error = 0;
	if (ch == NULL || (flags & ~MFChannelFlagNonBlocking) != 0) {
		mf_log(__func__, "Invalid argument channel", 0);
		MF_FAIL(EINVAL, false);
	}
	fd = mf_channel_fd(ch, ENODEV, &error);
	if (fd < 0)
		MF_FAIL(error, false);
	fl = fcntl(fd, F_GETFL);
	if (fl == -1)
		MF_FAIL(errno, false);
	fl &= ~O_NONBLOCK;
	if (flags & MFChannelFlagNonBlocking)
		fl |= O_NONBLOCK;
	if (fcntl(fd, F_SETFL, fl) == -1)
		MF_FAIL(errno, false);
	MF_OK(true);
}

bool _MFChannelInterrupt(MFChannelRef channel)
{
	struct mf_channel *ch = mf_unwrap(channel, MF_KIND_CHANNEL);
	int error;
	if (ch == NULL) {
		mf_log(__func__, "Invalid argument channel", 0);
		MF_FAIL(EINVAL, false);
	}
	error = mf_channel_interrupt(ch);
	if (error)
		MF_FAIL(error, false);
	MF_OK(true);
}

static void mf_waiters_remove(struct mf_channel *ch, int kq)
{
	pthread_mutex_lock(&ch->lock);
	for (size_t i = 0; i < ch->nwaiters; i++) {
		if (ch->waiters[i] == kq) {
			ch->waiters[i] = ch->waiters[--ch->nwaiters];
			break;
		}
	}
	pthread_mutex_unlock(&ch->lock);
}

/* DeviceTransport.waitForNextMessage(until:) */
int32_t _MFChannelWaitForNextMessage(MFChannelRef channel, int32_t timeout)
{
	struct mf_channel *ch = mf_unwrap(channel, MF_KIND_CHANNEL);
	struct kevent64_s ev, out;
	struct timespec ts, *tsp = NULL;
	int fd, kq, n, error = 0;

	if (ch == NULL) {
		mf_log(__func__, "Invalid argument channel", 0);
		MF_FAIL(EINVAL, -1);
	}
	fd = mf_channel_fd(ch, ENODEV, &error);
	if (fd < 0) {
		mf_log(__func__, "Failed to wait on channel", error);
		MF_FAIL(error, -1);
	}

	if (timeout == 0) {
		struct pollfd p = { .fd = fd, .events = POLLIN };
		n = poll(&p, 1, 0);
		if (n == -1)
			MF_FAIL(errno, -1);
		MF_OK(n == 1 ? 1 : 0);
	}

	kq = kqueue();
	if (kq == -1)
		MF_FAIL(errno, -1);
	EV_SET64(&ev, 1, EVFILT_USER, EV_ADD | EV_ENABLE | EV_CLEAR, 0, 0, 0, 0, 0);
	if (kevent64(kq, &ev, 1, NULL, 0, 0, NULL) == -1) {
		error = errno;
		close(kq);
		MF_FAIL(error, -1);
	}

	pthread_mutex_lock(&ch->lock);
	if (ch->nwaiters == ch->capwaiters) {
		size_t cap = ch->capwaiters ? ch->capwaiters * 2 : 4;
		int *w = realloc(ch->waiters, cap * sizeof(*w));
		if (w == NULL) {
			pthread_mutex_unlock(&ch->lock);
			close(kq);
			MF_FAIL(ENOMEM, -1);
		}
		ch->waiters = w;
		ch->capwaiters = cap;
	}
	ch->waiters[ch->nwaiters++] = kq;
	pthread_mutex_unlock(&ch->lock);

	EV_SET64(&ev, (uint64_t)fd, EVFILT_READ, EV_ADD | EV_ENABLE, 0, 0, 0, 0, 0);
	if (kevent64(kq, &ev, 1, NULL, 0, 0, NULL) == -1) {
		error = errno;
		goto out;
	}
	if (timeout > 0) {
		ts.tv_sec = timeout / 1000;
		ts.tv_nsec = (long)(timeout % 1000) * 1000000L;
		tsp = &ts;
	}
	n = kevent64(kq, NULL, 0, &out, 1, 0, tsp);
	if (n == -1)
		error = errno;
	else if (n == 1 && out.filter == EVFILT_USER)
		error = EINTR;
out:
	mf_waiters_remove(ch, kq);
	close(kq);
	if (error) {
		if (error != EINTR)
			mf_log(__func__, "Failed to wait on channel", error);
		MF_FAIL(error, -1);
	}
	MF_OK(n == 1 ? 1 : 0);
}

/* DeviceTransport.nextMessage() */
MFMessageRef _MFChannelCopyNextMessage(MFChannelRef channel)
{
	struct mf_channel *ch = mf_unwrap(channel, MF_KIND_CHANNEL);
	struct mf_message *msg;
	void *buffer = NULL;
	ssize_t n;
	int fd, error = 0;

	if (ch == NULL) {
		mf_log(__func__, "Invalid argument channel", 0);
		MF_FAIL(EINVAL, NULL);
	}
	fd = mf_channel_fd(ch, ENODEV, &error);
	if (fd < 0)
		MF_FAIL(error, NULL);

	error = posix_memalign(&buffer, (size_t)getpagesize(), MF_DEVICE_MESSAGE_BUFFER_BYTE_COUNT);
	if (error)
		MF_FAIL(error, NULL);
	n = read(fd, buffer, MF_DEVICE_MESSAGE_BUFFER_BYTE_COUNT);
	if (n <= 0) {
		error = n == 0 ? ENODEV : errno;
		free(buffer);
		if (error != ENODEV && error != EINTR && error != EAGAIN)
			mf_log(__func__, "Failed to receive message", error);
		MF_FAIL(error, NULL);
	}
	msg = calloc(1, sizeof(*msg));
	if (msg == NULL) {
		free(buffer);
		MF_FAIL(ENOMEM, NULL);
	}
	msg->obj.kind = MF_KIND_MESSAGE;
	atomic_init(&msg->obj.refcount, 1);
	msg->buffer = buffer;
	msg->body.iov_base = buffer;
	msg->body.iov_len = (size_t)n;
	MF_OK(msg);
}

/* DeviceTransport.send(message:) */
ssize_t _MFChannelSendMessage(MFChannelRef channel, const struct iovec *buffers, size_t count)
{
	struct mf_channel *ch = mf_unwrap(channel, MF_KIND_CHANNEL);
	ssize_t n;
	int fd, error = 0;

	if (ch == NULL || buffers == NULL || count == 0) {
		mf_log(__func__, "Invalid argument", 0);
		MF_FAIL(EINVAL, -1);
	}
	fd = mf_channel_fd(ch, ENODEV, &error);
	if (fd < 0)
		MF_FAIL(error, -1);
	n = writev(fd, buffers, (int)count);
	if (n == -1) {
		error = errno;
		/* ENOENT: the request is no longer pending or the volume is dead. */
		if (error != ENOENT)
			mf_log(__func__, "Failed to send message", error);
		MF_FAIL(error, -1);
	}
	MF_OK(n);
}

/* Channel.close() + DeviceTransport.deactivate() */
bool _MFChannelClose(MFChannelRef channel)
{
	struct mf_channel *ch = mf_unwrap(channel, MF_KIND_CHANNEL);
	enum mf_channel_state was;
	int fd;

	if (ch == NULL) {
		mf_log(__func__, "Invalid argument channel", 0);
		MF_FAIL(EINVAL, false);
	}
	mf_channel_cancel_signal_sources(ch);

	pthread_mutex_lock(&ch->lock);
	was = ch->state;
	fd = ch->fd;
	ch->state = MF_CLOSED;
	ch->fd = -1;
	if (was == MF_OPEN)
		(void)mf_channel_interrupt_locked_waiters(ch);
	pthread_mutex_unlock(&ch->lock);

	if (was == MF_OPEN && close(fd) == -1) {
		mf_log(__func__, "Failed to close device file descriptor", errno);
		MF_FAIL(EBADF, false);
	}
	MF_OK(true);
}

/* ------------------------------------------------------------------- volumes */

MFMountResult _MFMount(MFChannelRef channel, const char *mountPoint, const char *options, bool quiet)
{
	(void)channel; (void)mountPoint; (void)options; (void)quiet;
	/* Upstream: guard #available(macOS 15.4, *) else { return .unsupporteOSVersion } */
	mf_log(__func__, "Unsupported version of macOS", 0);
	MF_OK(MFMountResultUnsupporteOSVersion);
}
