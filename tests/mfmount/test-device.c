/*
 * test-device.c -- exercise the 10.9 MFMount device channel without a kext:
 * a socketpair stands in for /dev/macfuseN (message boundaries hold on
 * SOCK_DGRAM, as they do on the device). The interrupt ioctl is expected to
 * fail with EOPNOTSUPP on a socket; the kqueue wake-up must still happen.
 */
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
#include <MFMount/MFMount.h>

#define CHECK(c) do { if (!(c)) { printf("FAIL line %d: %s (errno %d %s)\n", __LINE__, #c, errno, strerror(errno)); return 1; } } while (0)

static MFChannelRef ch;
static void *waiter(void *arg)
{
	int32_t *res = arg;
	res[0] = MFChannelWaitForNextMessage(ch, -1);
	res[1] = errno;
	return NULL;
}

int main(void)
{
	int sv[2];
	CHECK(socketpair(AF_UNIX, SOCK_DGRAM, 0, sv) == 0);
	ch = MFChannelCreateWithDeviceFileDescriptor(sv[0]);
	CHECK(ch != NULL);
	CHECK(MFChannelGetFileDescriptor(ch) == sv[0]);

	/* nothing pending: poll and a 50 ms wait both time out */
	CHECK(MFChannelWaitForNextMessage(ch, 0) == 0);
	CHECK(MFChannelWaitForNextMessage(ch, 50) == 0);

	/* "kernel" -> daemon */
	CHECK(write(sv[1], "request-1", 9) == 9);
	CHECK(MFChannelWaitForNextMessage(ch, 1000) == 1);
	MFMessageRef m = MFChannelCopyNextMessage(ch);
	CHECK(m != NULL);
	CHECK(MFMessageGetBodySize(m) == 9);
	const struct iovec *iov;
	CHECK(MFMessageGetBodyBuffers(m, &iov) == 1);
	CHECK(iov[0].iov_len == 9 && memcmp(iov[0].iov_base, "request-1", 9) == 0);
	void *rb = (void *)1;
	CHECK(MFMessageGetReplyBuffer(m, &rb) == 0 && rb == NULL);
	MFRetain(m); MFRelease(m); MFRelease(m);

	/* daemon -> "kernel", two iovecs, one message */
	struct iovec out[2] = { { "rep", 3 }, { "ly", 2 } };
	CHECK(MFChannelSendMessage(ch, out, 2) == 5);
	char buf[16];
	CHECK(read(sv[1], buf, sizeof(buf)) == 5 && memcmp(buf, "reply", 5) == 0);

	/* flags */
	MFChannelFlags fl;
	CHECK(MFChannelSetFlags(ch, MFChannelFlagNonBlocking));
	CHECK(MFChannelGetFlags(ch, &fl) && fl == MFChannelFlagNonBlocking);
	CHECK(MFChannelCopyNextMessage(ch) == NULL && errno == EAGAIN);
	CHECK(MFChannelSetFlags(ch, MFChannelFlagNone));

	/* interrupt wakes a blocked waiter with EINTR; the ioctl itself fails on a socket */
	int32_t res[2] = { 99, 0 };
	pthread_t t;
	pthread_create(&t, NULL, waiter, res);
	usleep(200000);
	bool ok = MFChannelInterrupt(ch);
	int ierr = errno;
	pthread_join(t, NULL);
	printf("interrupt: returned %d errno %d (%s); waiter got %d errno %d (%s)\n",
	    ok, ierr, strerror(ierr), res[0], res[1], strerror(res[1]));
	CHECK(res[0] == -1 && res[1] == EINTR);

	/* MFMount (FSKit backend) refuses, as upstream does below macOS 15.4 */
	MFChannelRef unopened = MFChannelCreate();
	CHECK(unopened != NULL);
	CHECK(MFMount(unopened, "/tmp/x", "", true) == MFMountResultUnsupporteOSVersion);
	CHECK(MFChannelClose(unopened));
	MFRelease(unopened);

	/* close: fd closed, later calls ENODEV */
	CHECK(MFChannelClose(ch));
	CHECK(MFChannelWaitForNextMessage(ch, 0) == -1 && errno == ENODEV);
	CHECK(MFChannelCopyNextMessage(ch) == NULL && errno == ENODEV);
	CHECK(write(sv[1], "x", 1) == -1);
	MFRelease(ch);
	printf("PASS\n");
	return 0;
}
