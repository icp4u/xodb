#define _GNU_SOURCE 1
#define _FILE_OFFSET_BITS 64
#include "cache_pool.h"
#include "object_cache.h"
#include "cache_io.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#include <time.h>

#define HEADER 256u
struct xcp_entry { int lease, range, index; uint64_t range_limit; };
static int private_directory(int fd) {
    struct stat st;
    return fd >= 0 && !fstat(fd, &st) && S_ISDIR(st.st_mode) &&
        st.st_uid == geteuid() && !(st.st_mode & 077);
}
static void retire_ranges(int parent);
int xcp_directory(void) {
    const char *base = getenv("XDG_CACHE_HOME");
    char *allocated = NULL;
    if (!base || !*base) {
        const char *home = getenv("HOME");
        if (!home || *home != '/' || asprintf(&allocated, "%s/.cache", home) < 0) return -1;
        base = allocated;
    }
    if (*base != '/') { free(allocated); return -1; }
    if (mkdir(base, 0700) && errno != EEXIST) { free(allocated); return -1; }
    int parent = open(base, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    free(allocated);
    if (parent < 0) return -1;
    struct stat st;
    /* A shared cache root may be group-writable. Only the opened, owned
     * private child and its verified files are trusted. */
    if (fstat(parent, &st) || st.st_uid != geteuid()) { close(parent); return -1; }
    if (mkdirat(parent, "xodb-debug-v2", 0700) && errno != EEXIST) { close(parent); return -1; }
    int dir = openat(parent, "xodb-debug-v2", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (!private_directory(dir)) { if (dir >= 0) close(dir); close(parent); return -1; }
    retire_ranges(parent);
    close(parent);
    return dir;
}
static int checked_file(int dir, unsigned slot, const char *suffix, int create) {
    char name[32];
    snprintf(name, sizeof name, "%u.%s", slot, suffix);
    int fd = openat(dir, name, O_RDWR | (create ? O_CREAT : 0) | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0600);
    if (fd < 0) return -1;
    struct stat st, named;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != geteuid() ||
        (st.st_mode & 077) || st.st_nlink != 1 ||
        fstatat(dir, name, &named, AT_SYMLINK_NOFOLLOW) || st.st_dev != named.st_dev || st.st_ino != named.st_ino) {
        close(fd); return -1;
    }
    return fd;
}
static int file(int dir, unsigned slot, const char *suffix) {
    return checked_file(dir, slot, suffix, 1);
}
/* Old clients may still own v1 leases. Reclaim only known range files after
 * taking both their slot and component locks; never follow links, create old
 * entries, unlink names or wait for another session. */
static void retire_ranges(int parent) {
    int dir = openat(parent, "xodb-debug-v1", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (!private_directory(dir)) { if (dir >= 0) close(dir); return; }
    for (unsigned slot = 0; slot < XCP_SLOTS; ++slot) {
        int lease = checked_file(dir, slot, "lease", 0);
        if (lease < 0) continue;
        if (!flock(lease, LOCK_EX | LOCK_NB)) {
            int range = checked_file(dir, slot, "ranges", 0);
            if (range >= 0) {
                if (!flock(range, LOCK_EX | LOCK_NB)) (void)ftruncate(range, 0);
                close(range);
            }
        }
        close(lease);
    }
    close(dir);
}
static void header(unsigned char out[HEADER], const struct xbo_identity *id,
        const unsigned char *build, size_t size) {
    memset(out, 0, HEADER); memcpy(out, "XODBSLOT", 8); xc_put(out + 8, 1, 4);
    xc_put(out + 16, id->device, 8); xc_put(out + 24, id->inode, 8); xc_put(out + 32, id->size, 8);
    xc_put(out + 40, (uint64_t)id->mtime_sec, 8); xc_put(out + 48, id->mtime_nsec, 4);
    xc_put(out + 56, (uint64_t)id->ctime_sec, 8); xc_put(out + 64, id->ctime_nsec, 4);
    xc_put(out + 72, size, 4); memcpy(out + 80, build, size);
    xc_put(out + HEADER - 4, xc_checksum(out, HEADER - 4), 4);
}
static enum xbo_status acquire(int dir, const struct xbo_identity *id,
        const unsigned char *build, size_t size, struct xcp_entry **out) {
    if (!out) return XBO_MALFORMED;
    *out = NULL;
    if (!id || !build || !size || size > 64) return XBO_MALFORMED;
    uint64_t extent;
    enum xbo_status status = xbc_extent(id->size, &extent);
    /* Leave room for the name index's bucket table. */
    if (status != XBO_OK || extent > XCP_SLOT_LIMIT - UINT64_C(1052672)) return XBO_LIMIT;
    if (!private_directory(dir)) return XBO_IO;
    int leases[XCP_SLOTS];
    struct stat stats[XCP_SLOTS];
    int selected = -1, matching = 0;
    unsigned char key[HEADER], previous[HEADER]; header(key, id, build, size);
    for (unsigned n = 0; n < XCP_SLOTS; ++n) leases[n] = -1;
    status = XBO_AGAIN;
    for (unsigned n = 0; n < XCP_SLOTS; ++n) {
        int fd = file(dir, n, "lease");
        if (fd < 0) { status = XBO_IO; goto done; }
        if (flock(fd, LOCK_EX | LOCK_NB)) {
            int busy = errno == EWOULDBLOCK; close(fd);
            if (busy) continue;
            status = XBO_IO; goto done;
        }
        leases[n] = fd;
        if (fstat(fd, &stats[n])) { status = XBO_IO; goto done; }
        int same = stats[n].st_size == HEADER && !xc_io(fd, previous, HEADER, 0, 0) && !memcmp(previous, key, HEADER);
        if (same && !matching) { selected = (int)n; matching = 1; }
        if (!matching && (selected < 0 || stats[n].st_mtim.tv_sec < stats[selected].st_mtim.tv_sec ||
                (stats[n].st_mtim.tv_sec == stats[selected].st_mtim.tv_sec && stats[n].st_mtim.tv_nsec < stats[selected].st_mtim.tv_nsec))) selected = (int)n;
    }
    if (selected < 0) goto done;
    struct xcp_entry *entry = calloc(1, sizeof *entry);
    if (!entry) { status = XBO_NOMEM; goto done; }
    entry->lease = leases[selected]; leases[selected] = -1;
    entry->range = file(dir, (unsigned)selected, "ranges");
    entry->index = file(dir, (unsigned)selected, "names");
    entry->range_limit = extent;
    if (entry->range < 0 || entry->index < 0) { status = XBO_IO; goto failed; }
    /* Also respect component users holding either file directly. */
    if (flock(entry->range, LOCK_EX | LOCK_NB) || flock(entry->index, LOCK_EX | LOCK_NB)) {
        status = errno == EWOULDBLOCK ? XBO_AGAIN : XBO_IO; goto failed;
    }
    struct stat range, index;
    if (fstat(entry->range, &range) || fstat(entry->index, &index)) { status = XBO_IO; goto failed; }
    if (!matching || range.st_size < 0 || (uint64_t)range.st_size > extent || index.st_size < 0 ||
        (uint64_t)index.st_size > XCP_SLOT_LIMIT - extent) {
        status = xcp_reset(entry); if (status != XBO_OK) goto failed;
    }
    if (ftruncate(entry->lease, HEADER) || xc_io(entry->lease, key, HEADER, 0, 1) || futimens(entry->lease, NULL)) {
        status = XBO_IO; goto failed;
    }
    *out = entry; status = XBO_OK; goto done;
failed:
    xcp_release(entry);
done:
    for (unsigned n = 0; n < XCP_SLOTS; ++n) if (leases[n] >= 0) close(leases[n]);
    return status;
}
/* Concurrent scans temporarily hold multiple free leases. Bound retries so
 * a second acquirer can use a released slot without blocking indefinitely. */
enum xbo_status xcp_acquire(int dir, const struct xbo_identity *id,
        const unsigned char *build, size_t size, struct xcp_entry **out) {
    enum xbo_status status;
    for (unsigned attempt = 0; ; ++attempt) {
        status = acquire(dir, id, build, size, out);
        if (status != XBO_AGAIN || attempt == 4) return status;
        struct timespec pause = {.tv_nsec = 1000000};
        nanosleep(&pause, NULL);
    }
}
int xcp_range_fd(const struct xcp_entry *p) { return p ? p->range : -1; }
int xcp_index_fd(const struct xcp_entry *p) { return p ? p->index : -1; }
uint64_t xcp_range_limit(const struct xcp_entry *p) { return p ? p->range_limit : 0; }
uint64_t xcp_index_limit(const struct xcp_entry *p) { return p ? XCP_SLOT_LIMIT - p->range_limit : 0; }
enum xbo_status xcp_reset(struct xcp_entry *p) {
    if (!p) return XBO_MALFORMED;
    if (flock(p->range, LOCK_EX | LOCK_NB) || flock(p->index, LOCK_EX | LOCK_NB))
        return errno == EWOULDBLOCK ? XBO_AGAIN : XBO_IO;
    return ftruncate(p->range, 0) || ftruncate(p->index, 0) ? XBO_IO : XBO_OK;
}
void xcp_release(struct xcp_entry *p) {
    if (!p) return;
    if (p->index >= 0) close(p->index);
    if (p->range >= 0) close(p->range);
    if (p->lease >= 0) close(p->lease);
    free(p);
}
