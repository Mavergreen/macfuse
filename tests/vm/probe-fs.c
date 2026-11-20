/*
 * probe-fs -- a libfuse 3 file system that reports what the 10.9 acceptance job (tests/vm/gate0b.sh)
 * asks about libfuse's multithreaded loop and the kernel: one flat in-memory directory, every
 * callback logged by name to $PROBE_LOG, and three fixed answers:
 *   - reading /stack gives pthread_get_stacksize_np() of the worker thread serving that read;
 *   - statfs reports bsize 4096, blocks 1000000, bfree 600000, bavail 500000, files 70000,
 *     ffree 50000, so df can be checked against them;
 *   - init logs the negotiated max_write, max_read and max_readahead, and destroy logs "destroy".
 * Built against the installed product's headers and /usr/local/lib/libfuse3.4.dylib, like any
 * third-party file system (tests/vm/build-tests.sh). usage: probe-fs MOUNTPOINT [fuse options]
 */
#define FUSE_USE_VERSION 31
#include <fuse.h>
#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/xattr.h>
#include <time.h>
#include <unistd.h>

#define MAXF 256
#define MAXX 16
struct xa { char name[128]; char *val; size_t len; };
struct node {
  char name[256]; mode_t mode; char *data; size_t size, cap;
  struct timespec mtime; struct xa x[MAXX];
};
static struct node files[MAXF];
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static FILE *logf;

static void plog(const char *fmt, ...) {
  va_list ap;
  if (!logf) return;
  pthread_mutex_lock(&mu);
  va_start(ap, fmt); vfprintf(logf, fmt, ap); va_end(ap);
  fputc('\n', logf); fflush(logf);
  pthread_mutex_unlock(&mu);
}

static struct node *find(const char *path) {
  int i;
  if (path[0] != '/' || strchr(path + 1, '/')) return NULL;
  for (i = 0; i < MAXF; i++) if (files[i].name[0] && strcmp(files[i].name, path + 1) == 0) return &files[i];
  return NULL;
}
static struct node *add(const char *path, mode_t mode) {
  int i;
  if (path[0] != '/' || strchr(path + 1, '/') || strlen(path + 1) >= sizeof files[0].name) return NULL;
  for (i = 0; i < MAXF; i++) if (!files[i].name[0]) {
    memset(&files[i], 0, sizeof files[i]);
    strcpy(files[i].name, path + 1); files[i].mode = mode;
    clock_gettime(CLOCK_REALTIME, &files[i].mtime);
    return &files[i];
  }
  return NULL;
}
static void drop(struct node *n) {
  int i;
  free(n->data);
  for (i = 0; i < MAXX; i++) free(n->x[i].val);
  memset(n, 0, sizeof *n);
}
static int is_stack(const char *path) { return strcmp(path, "/stack") == 0; }

static void *p_init(struct fuse_conn_info *conn, struct fuse_config *cfg) {
  plog("init max_write=%u max_read=%u max_readahead=%u", conn->max_write, conn->max_read, conn->max_readahead);
  return NULL;
}
static void p_destroy(void *u) { plog("destroy"); }

static int p_getattr(const char *path, struct stat *st, struct fuse_file_info *fi) {
  struct node *n;
  memset(st, 0, sizeof *st);
  st->st_uid = getuid(); st->st_gid = getgid();
  if (strcmp(path, "/") == 0) { st->st_mode = S_IFDIR | 0755; st->st_nlink = 2; return 0; }
  if (is_stack(path)) { st->st_mode = S_IFREG | 0444; st->st_nlink = 1; st->st_size = 32; return 0; }
  pthread_mutex_lock(&mu);
  n = find(path);
  if (n) {
    st->st_mode = n->mode; st->st_nlink = 1; st->st_size = (off_t)n->size;
    st->st_mtimespec = n->mtime; st->st_ctimespec = n->mtime; st->st_atimespec = n->mtime;
  }
  pthread_mutex_unlock(&mu);
  return n ? 0 : -ENOENT;
}
static int p_readdir(const char *path, void *buf, fuse_fill_dir_t fill, off_t off, struct fuse_file_info *fi,
                     enum fuse_readdir_flags fl) {
  int i;
  plog("readdir %s", path);
  if (strcmp(path, "/") != 0) return -ENOENT;
  fill(buf, ".", NULL, 0, 0); fill(buf, "..", NULL, 0, 0); fill(buf, "stack", NULL, 0, 0);
  pthread_mutex_lock(&mu);
  for (i = 0; i < MAXF; i++) if (files[i].name[0]) fill(buf, files[i].name, NULL, 0, 0);
  pthread_mutex_unlock(&mu);
  return 0;
}
static int p_create(const char *path, mode_t mode, struct fuse_file_info *fi) {
  struct node *n;
  plog("create %s", path);
  pthread_mutex_lock(&mu);
  n = find(path); if (!n) n = add(path, S_IFREG | (mode & 07777));
  pthread_mutex_unlock(&mu);
  return n ? 0 : -ENOSPC;
}
static int p_open(const char *path, struct fuse_file_info *fi) {
  plog("open %s", path);
  return (is_stack(path) || find(path)) ? 0 : -ENOENT;
}
static int p_read(const char *path, char *buf, size_t sz, off_t off, struct fuse_file_info *fi) {
  struct node *n; int r;
  if (is_stack(path)) {
    char s[33];
    size_t stack = pthread_get_stacksize_np(pthread_self());
    plog("read %s stacksize=%zu", path, stack);
    snprintf(s, sizeof s, "%-31zu\n", stack);
    if (off >= 32) return 0;
    if (off + sz > 32) sz = 32 - off;
    memcpy(buf, s + off, sz);
    return (int)sz;
  }
  pthread_mutex_lock(&mu);
  n = find(path);
  if (!n) r = -ENOENT;
  else if ((size_t)off >= n->size) r = 0;
  else { if (off + sz > n->size) sz = n->size - off; memcpy(buf, n->data + off, sz); r = (int)sz; }
  pthread_mutex_unlock(&mu);
  return r;
}
static int grow(struct node *n, size_t need) {
  char *d; size_t c = n->cap ? n->cap : 65536;
  if (need <= n->cap) return 0;
  while (c < need) c *= 2;
  d = realloc(n->data, c);
  if (!d) return -ENOSPC;
  memset(d + n->cap, 0, c - n->cap); n->data = d; n->cap = c;
  return 0;
}
static int p_write(const char *path, const char *buf, size_t sz, off_t off, struct fuse_file_info *fi) {
  struct node *n; int r;
  pthread_mutex_lock(&mu);
  n = find(path);
  if (!n) r = -ENOENT;
  else if ((r = grow(n, off + sz)) == 0) {
    memcpy(n->data + off, buf, sz);
    if ((size_t)off + sz > n->size) n->size = off + sz;
    clock_gettime(CLOCK_REALTIME, &n->mtime);
    r = (int)sz;
  }
  pthread_mutex_unlock(&mu);
  return r;
}
static int p_truncate(const char *path, off_t size, struct fuse_file_info *fi) {
  struct node *n; int r = 0;
  plog("truncate %s %lld", path, (long long)size);
  pthread_mutex_lock(&mu);
  n = find(path);
  if (!n) r = -ENOENT;
  else if ((r = grow(n, size)) == 0) { if ((size_t)size < n->size) memset(n->data + size, 0, n->size - size); n->size = size; }
  pthread_mutex_unlock(&mu);
  return r;
}
static int p_unlink(const char *path) {
  struct node *n;
  plog("unlink %s", path);
  pthread_mutex_lock(&mu);
  n = find(path); if (n) drop(n);
  pthread_mutex_unlock(&mu);
  return n ? 0 : -ENOENT;
}
static int p_rename(const char *from, const char *to, unsigned int flags) {
  struct node *n, *o; int r = 0;
  plog("rename %s %s", from, to);
  if (strchr(to + 1, '/') || strlen(to + 1) >= sizeof files[0].name) return -EINVAL;
  pthread_mutex_lock(&mu);
  n = find(from); o = find(to);
  if (!n) r = -ENOENT;
  else { if (o && o != n) drop(o); strcpy(n->name, to + 1); }
  pthread_mutex_unlock(&mu);
  return r;
}
static int p_chmod(const char *path, mode_t mode, struct fuse_file_info *fi) {
  struct node *n;
  plog("chmod %s %o", path, (unsigned)mode);
  pthread_mutex_lock(&mu);
  n = find(path); if (n) n->mode = (n->mode & S_IFMT) | (mode & 07777);
  pthread_mutex_unlock(&mu);
  return n || strcmp(path, "/") == 0 ? 0 : -ENOENT;
}
static int p_chown(const char *path, uid_t u, gid_t g, struct fuse_file_info *fi) {
  plog("chown %s", path);
  return 0;
}
static int p_utimens(const char *path, const struct timespec tv[2], struct fuse_file_info *fi) {
  struct node *n;
  plog("utimens %s", path);
  pthread_mutex_lock(&mu);
  n = find(path); if (n && tv) n->mtime = tv[1];
  pthread_mutex_unlock(&mu);
  return 0;
}
static int p_statfs(const char *path, struct statvfs *s) {
  plog("statfs %s", path);
  memset(s, 0, sizeof *s);
  s->f_bsize = 4096; s->f_frsize = 4096; s->f_blocks = 1000000; s->f_bfree = 600000; s->f_bavail = 500000;
  s->f_files = 70000; s->f_ffree = 50000; s->f_favail = 50000; s->f_namemax = 255;
  return 0;
}
static int p_setxattr(const char *path, const char *name, const char *val, size_t len, int flags) {
  struct node *n; int i, r = -ENOSPC, freei = -1;
  plog("setxattr %s %s", path, name);
  if (strlen(name) >= sizeof files[0].x[0].name) return -ENAMETOOLONG;
  pthread_mutex_lock(&mu);
  n = find(path);
  if (!n) { pthread_mutex_unlock(&mu); return -ENOENT; }
  for (i = 0; i < MAXX; i++) {
    if (n->x[i].name[0] && strcmp(n->x[i].name, name) == 0) { freei = i; break; }
    if (!n->x[i].name[0] && freei < 0) freei = i;
  }
  if (freei >= 0) {
    char *v = malloc(len ? len : 1);
    if (v) {
      memcpy(v, val, len); free(n->x[freei].val);
      strcpy(n->x[freei].name, name); n->x[freei].val = v; n->x[freei].len = len; r = 0;
    }
  }
  pthread_mutex_unlock(&mu);
  return r;
}
static int p_getxattr(const char *path, const char *name, char *val, size_t len) {
  struct node *n; int i, r = -ENOATTR;
  plog("getxattr %s %s", path, name);
  pthread_mutex_lock(&mu);
  n = find(path);
  if (n) for (i = 0; i < MAXX; i++) if (n->x[i].name[0] && strcmp(n->x[i].name, name) == 0) {
    if (len == 0) r = (int)n->x[i].len;
    else if (len < n->x[i].len) r = -ERANGE;
    else { memcpy(val, n->x[i].val, n->x[i].len); r = (int)n->x[i].len; }
    break;
  }
  pthread_mutex_unlock(&mu);
  return r;
}
static int p_listxattr(const char *path, char *list, size_t len) {
  struct node *n; int i; size_t need = 0;
  plog("listxattr %s", path);
  pthread_mutex_lock(&mu);
  n = find(path);
  if (n) for (i = 0; i < MAXX; i++) if (n->x[i].name[0]) {
    size_t l = strlen(n->x[i].name) + 1;
    if (len && need + l <= len) memcpy(list + need, n->x[i].name, l);
    need += l;
  }
  pthread_mutex_unlock(&mu);
  if (len && need > len) return -ERANGE;
  return (int)need;
}
static int p_removexattr(const char *path, const char *name) {
  struct node *n; int i, r = -ENOATTR;
  plog("removexattr %s %s", path, name);
  pthread_mutex_lock(&mu);
  n = find(path);
  if (n) for (i = 0; i < MAXX; i++) if (n->x[i].name[0] && strcmp(n->x[i].name, name) == 0) {
    free(n->x[i].val); memset(&n->x[i], 0, sizeof n->x[i]); r = 0; break;
  }
  pthread_mutex_unlock(&mu);
  return r;
}

static const struct fuse_operations ops = {
  .init = p_init, .destroy = p_destroy, .getattr = p_getattr, .readdir = p_readdir, .create = p_create,
  .open = p_open, .read = p_read, .write = p_write, .truncate = p_truncate, .unlink = p_unlink,
  .rename = p_rename, .chmod = p_chmod, .chown = p_chown, .utimens = p_utimens, .statfs = p_statfs,
  .setxattr = p_setxattr, .getxattr = p_getxattr, .listxattr = p_listxattr, .removexattr = p_removexattr,
};

int main(int argc, char *argv[]) {
  const char *l = getenv("PROBE_LOG");
  if (l && !(logf = fopen(l, "a"))) { perror(l); return 1; }
  return fuse_main(argc, argv, &ops, NULL);
}
