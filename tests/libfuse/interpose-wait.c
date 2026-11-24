/*
 * interpose-wait.c -- loaded into tests/libfuse/fd-mountpoint with
 * DYLD_INSERT_LIBRARIES: dyld routes every call of MFChannelWaitForNextMessage
 * through counted_wait, which counts the calls, can hold back the single poll
 * (timeout 0) once, and can make a slice (any other timeout) sleep and report
 * nothing, as a kqueue that never reports the device would. fd-mountpoint finds
 * the state with dlsym.
 */
#include <errno.h>
#include <stdint.h>
#include <unistd.h>

int32_t MFChannelWaitForNextMessage(void *channel, int32_t timeout);

struct wait_state {
	volatile int wait_calls, slice_waits, blind, delay_probe;
};

struct wait_state mf_wait_state;

static int32_t counted_wait(void *channel, int32_t timeout)
{
	mf_wait_state.wait_calls++;
	if (timeout == 0) {
		if (mf_wait_state.delay_probe) {
			mf_wait_state.delay_probe = 0;
			usleep(300000);
		}
		return MFChannelWaitForNextMessage(channel, 0);
	}
	mf_wait_state.slice_waits++;
	if (mf_wait_state.blind) {
		usleep((useconds_t)timeout * 1000);
		errno = 0;
		return 0;
	}
	return MFChannelWaitForNextMessage(channel, timeout);
}

struct interpose {
	const void *replacement, *replacee;
};

__attribute__((used)) static struct interpose interposers[] __attribute__((section("__DATA,__interpose"))) = {
	{ (const void *)counted_wait, (const void *)MFChannelWaitForNextMessage },
};
