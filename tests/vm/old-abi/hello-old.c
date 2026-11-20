/* old-abi -- a libfuse 2 file system built against upstream macFUSE 4.0.5's installed headers and
 * /usr/local/lib/libfuse.2.dylib (tests/vm/build-tests.sh), as a third-party binary from before this
 * product would be: one read-only file, old-abi.txt. usage: hello-old MOUNTPOINT [fuse options] */
#define FUSE_USE_VERSION 26
#include <fuse.h>
#include <errno.h>
#include <string.h>
#include <sys/stat.h>

static const char *text = "built against macFUSE 4.0.5\n";

static int o_getattr(const char *p, struct stat *st) {
  memset(st, 0, sizeof *st);
  if (strcmp(p, "/") == 0) { st->st_mode = S_IFDIR | 0555; st->st_nlink = 2; return 0; }
  if (strcmp(p, "/old-abi.txt") == 0) { st->st_mode = S_IFREG | 0444; st->st_nlink = 1; st->st_size = strlen(text); return 0; }
  return -ENOENT;
}
static int o_readdir(const char *p, void *b, fuse_fill_dir_t fill, off_t o, struct fuse_file_info *fi) {
  if (strcmp(p, "/") != 0) return -ENOENT;
  fill(b, ".", NULL, 0); fill(b, "..", NULL, 0); fill(b, "old-abi.txt", NULL, 0);
  return 0;
}
static int o_read(const char *p, char *b, size_t n, off_t o, struct fuse_file_info *fi) {
  size_t len = strlen(text);
  if (strcmp(p, "/old-abi.txt") != 0) return -ENOENT;
  if ((size_t)o >= len) return 0;
  if (o + n > len) n = len - o;
  memcpy(b, text + o, n);
  return (int)n;
}
static struct fuse_operations ops = { .getattr = o_getattr, .readdir = o_readdir, .read = o_read };
int main(int argc, char *argv[]) { return fuse_main(argc, argv, &ops, NULL); }
