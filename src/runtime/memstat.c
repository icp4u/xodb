#define _GNU_SOURCE 1
#include "memstat_internal.h"
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

uint64_t xrt_mem_clock(clockid_t id)
{
    struct timespec t;
    return clock_gettime(id, &t) ? 0 : (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
}
void xrt_mem_status(struct xrt_mem_status *s, uint32_t state, int error, const char *reason)
{
    s->state = state;
    s->error = error;
    snprintf(s->reason, sizeof(s->reason), "%s", reason);
}
void xrt_mem_error(struct xrt_mem_status *s, int error, const char *source)
{
    s->state = error == EACCES || error == EPERM ? XRT_MEM_DENIED : XRT_MEM_UNAVAILABLE;
    s->error = error;
    snprintf(s->reason, sizeof(s->reason), "%s: %s", source, strerror(error));
}
void xrt_mem_limits_default(struct xrt_mem_limits *l)
{
    if (l) *l = (struct xrt_mem_limits){65536, 16384, 128, 256, 256, 64u << 20, 4u << 20, 1u << 20, 20000000};
}
int xrt_mem_limits_valid(const struct xrt_mem_limits *l)
{
    return l && l->vmas && l->vmas <= 65536 && l->ranges && l->ranges <= 65536 &&
        l->zones && l->zones <= 1024 && l->counters && l->counters <= 1024 &&
        l->settings && l->settings <= 1024 && l->text_bytes && l->text_bytes <= (64u << 20) &&
        l->path_bytes && l->path_bytes <= (4u << 20) && l->pages && l->pages <= (8u << 20) &&
        l->scan_cpu_ns && l->scan_cpu_ns <= UINT64_C(1000000000);
}
char *xrt_mem_text(int root, const char *name, size_t cap, size_t *length, struct xrt_mem_status *s)
{
    *length = 0;
    if (root < 0) { xrt_mem_error(s, ENOENT, name); return NULL; }
    int fd = openat(root, name, O_RDONLY | O_CLOEXEC);
    if (fd < 0) { xrt_mem_error(s, errno, name); return NULL; }
    size_t allocated = cap < 4096 ? cap : 4096;
    char *text = malloc(allocated + 1);
    if (!text) { close(fd); xrt_mem_error(s, ENOMEM, name); return NULL; }
    while (*length < cap) {
        if (*length == allocated) {
            size_t next = allocated > cap / 2 ? cap : allocated * 2;
            char *grown = realloc(text, next + 1);
            if (!grown) { close(fd); free(text); xrt_mem_error(s, ENOMEM, name); return NULL; }
            text = grown; allocated = next;
        }
        ssize_t n = read(fd, text + *length, allocated - *length);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) { int e = errno; close(fd); free(text); xrt_mem_error(s, e, name); return NULL; }
        if (!n) break;
        *length += (size_t)n;
    }
    text[*length] = 0;
    xrt_mem_status(s, XRT_MEM_OK, 0, "ok");
    if (*length == cap) {
        char extra;
        ssize_t n;
        do { n = read(fd, &extra, 1); } while (n < 0 && errno == EINTR);
        if (n != 0) xrt_mem_status(s, XRT_MEM_PARTIAL, n < 0 ? errno : 0, "bounded text read; remainder unavailable");
    }
    close(fd);
    if (memchr(text, 0, *length)) xrt_mem_status(s, XRT_MEM_INVALID, 0, "unexpected NUL in text source");
    return text;
}
/* Limits cap growth; they never determine a small snapshot's allocation. */
void *xrt_mem_grow(void *storage, uint32_t *capacity, uint32_t count,
                   uint32_t limit, size_t size)
{
    if (count <= *capacity) return storage;
    if (count > limit || !size) return NULL;
    uint32_t next = *capacity ? *capacity : (limit < 64 ? limit : 64);
    while (next < count) next = next > limit / 2 ? limit : next * 2;
    if (next > SIZE_MAX / size) return NULL;
    void *grown = realloc(storage, (size_t)next * size);
    if (grown) *capacity = next;
    return grown;
}
void *xrt_mem_trim(void *storage, size_t bytes)
{
    /* Keep empty arrays non-null for consumers forming a zero-length slice. */
    if (!bytes) bytes = 1;
    void *smaller = realloc(storage, bytes);
    return smaller ? smaller : storage;
}
int xrt_mem_u64(const char *text, uint64_t *out)
{
    while (isspace((unsigned char)*text)) ++text;
    if (!isdigit((unsigned char)*text)) return 0;
    uint64_t n = 0;
    while (isdigit((unsigned char)*text)) {
        uint32_t digit = (uint32_t)(*text++ - '0');
        if (n > (UINT64_MAX - digit) / 10) return 0;
        n = n * 10 + digit;
    }
    while (isspace((unsigned char)*text)) ++text;
    if (*text) return 0;
    *out = n;
    return 1;
}
int xrt_mem_add(uint64_t a, uint64_t b, uint64_t *out)
{
    if (a > UINT64_MAX - b) return 0;
    *out = a + b;
    return 1;
}
int xrt_mem_fragmentation(const struct xrt_mem_zone *z, uint32_t order,
                          struct xrt_mem_fragmentation *out)
{
    if (!z || !out || !z->orders || z->orders > XRT_MEM_MAX_ORDERS || order >= z->orders) return 0;
    uint64_t pages = 0, blocks = 0, suitable = 0;
    for (uint32_t i = 0; i < z->orders; ++i) {
        if (z->blocks[i] > UINT64_MAX >> i ||
            !xrt_mem_add(pages, z->blocks[i] << i, &pages) ||
            !xrt_mem_add(blocks, z->blocks[i], &blocks)) return 0;
        if (i >= order) {
            if (z->blocks[i] > UINT64_MAX >> (i - order) ||
                !xrt_mem_add(suitable, z->blocks[i] << (i - order), &suitable)) return 0;
        }
    }
    const uint64_t suitable_pages = suitable << order;
    if (pages > (UINT64_MAX - 1000) / 1000) return 0;
    *out = (struct xrt_mem_fragmentation){.suitable_blocks = suitable, .suitable_pages = suitable_pages};
    if (pages) out->unusable_permille = (uint32_t)(((pages - suitable_pages) * 1000) / pages);
    if (suitable) out->index_permille = -1000;
    else if (blocks) {
        uint64_t fraction = (1000 + (pages * 1000 >> order)) / blocks;
        out->index_permille = 1000 - (int32_t)fraction;
    }
    return 1;
}
void xrt_mem_process_free(struct xrt_mem_process *s)
{
    if (!s) return;
    free(s->vmas); free(s->ranges); free(s->paths); free(s);
}
void xrt_mem_system_free(struct xrt_mem_system *s)
{
    if (!s) return;
    free(s->zones); free(s->counters); free(s->settings); free(s);
}
