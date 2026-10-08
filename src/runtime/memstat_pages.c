#define _GNU_SOURCE 1
#define _FILE_OFFSET_BITS 64
#include "memstat_internal.h"
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

/* Linux UAPI layout: all fields are fixed-width, including userspace pointers.
 * Keeping the wire structure here lets old build headers use a new kernel;
 * unsupported running kernels still select the required pagemap fallback. */
struct scan_region { uint64_t start, end, categories; };
struct scan_request {
    uint64_t size, flags, start, end, walk_end, vec, vec_len, max_pages;
    uint64_t category_inverted, category_mask, category_anyof_mask, return_mask;
};
#define MEM_PAGEMAP_SCAN _IOWR('f', 16, struct scan_request)
#define SCAN_WPALLOWED (UINT64_C(1) << 0)
#define SCAN_WRITTEN   (UINT64_C(1) << 1)
#define SCAN_FILE      (UINT64_C(1) << 2)
#define SCAN_PRESENT   (UINT64_C(1) << 3)
#define SCAN_SWAPPED   (UINT64_C(1) << 4)
#define SCAN_ZERO      (UINT64_C(1) << 5)
#define SCAN_HUGE      (UINT64_C(1) << 6)
#define SCAN_DIRTY     (UINT64_C(1) << 7)

static int append(struct xrt_mem_process *s, const struct xrt_mem_limits *l,
                  uint32_t *capacity, uint32_t vma, uint32_t backend, uint64_t start, uint64_t end,
                  uint64_t categories, uint64_t known)
{
    if (end <= start) return 1;
    if (s->range_count) {
        struct xrt_mem_range *last = &s->ranges[s->range_count - 1];
        if (last->vma == vma && last->backend == backend && last->end == start &&
            last->categories == categories && last->known == known) {
            last->end = end;
            if (known) s->scanned_bytes += end - start;
            return 1;
        }
    }
    if (s->range_count == l->ranges) {
        s->scan_resume = start;
        xrt_mem_status(&s->pages_status, XRT_MEM_PARTIAL, 0, "page range limit reached");
        return 0;
    }
    struct xrt_mem_range *grown = xrt_mem_grow(s->ranges, capacity,
        s->range_count + 1, l->ranges, sizeof(*s->ranges));
    if (!grown) {
        s->scan_resume = start;
        xrt_mem_status(&s->pages_status, XRT_MEM_PARTIAL, ENOMEM, "page range storage allocation failed");
        return 0;
    }
    s->ranges = grown;
    s->ranges[s->range_count++] = (struct xrt_mem_range){start, end, categories, known, vma, backend};
    if (known) s->scanned_bytes += end - start;
    return 1;
}
static void scan_bits(uint64_t raw, uint64_t *categories, uint64_t *known)
{
    *categories = 0;
    *known = XRT_MEM_PAGE_PRESENT | XRT_MEM_PAGE_SWAPPED | XRT_MEM_PAGE_FILE |
        XRT_MEM_PAGE_HUGE | XRT_MEM_PAGE_ZERO | XRT_MEM_PAGE_SOFT_DIRTY | XRT_MEM_PAGE_WP_TRACKED;
    if (raw & SCAN_PRESENT) *categories |= XRT_MEM_PAGE_PRESENT;
    if (raw & SCAN_SWAPPED) *categories |= XRT_MEM_PAGE_SWAPPED;
    if (raw & SCAN_FILE) *categories |= XRT_MEM_PAGE_FILE;
    if (raw & SCAN_HUGE) *categories |= XRT_MEM_PAGE_HUGE;
    if (raw & SCAN_ZERO) *categories |= XRT_MEM_PAGE_ZERO;
    if (raw & SCAN_DIRTY) *categories |= XRT_MEM_PAGE_SOFT_DIRTY;
    /* Some kernels set WRITTEN on ordinary writable mappings. It is only
     * meaningful dirty-tracking evidence in the target's WP-enabled range. */
    if (raw & SCAN_WPALLOWED) {
        *known |= XRT_MEM_PAGE_WRITTEN;
        *categories |= XRT_MEM_PAGE_WP_TRACKED;
        if (raw & SCAN_WRITTEN) *categories |= XRT_MEM_PAGE_WRITTEN;
    }
}
static uint64_t pagemap_bits(uint64_t raw)
{
    uint64_t result = 0;
    if (raw & (UINT64_C(1) << 63)) result |= XRT_MEM_PAGE_PRESENT;
    if (raw & (UINT64_C(1) << 62)) result |= XRT_MEM_PAGE_SWAPPED;
    if (raw & (UINT64_C(1) << 61)) result |= XRT_MEM_PAGE_FILE;
    if (raw & (UINT64_C(1) << 56)) result |= XRT_MEM_PAGE_EXCLUSIVE;
    if (raw & (UINT64_C(1) << 55)) result |= XRT_MEM_PAGE_SOFT_DIRTY;
    /* PFN/swap-offset bits are never retained, inferred from, or published. */
    return result;
}
void xrt_mem_pages(struct xrt_mem_process *s, int dir, const struct xrt_mem_limits *l)
{
    if (!s->vma_count || s->maps_status.state == XRT_MEM_INVALID || !s->page_size) {
        xrt_mem_status(&s->pages_status, XRT_MEM_UNAVAILABLE, 0, "no valid VMA ranges to scan"); return;
    }
    int fd = openat(dir, "pagemap", O_RDONLY | O_CLOEXEC);
    if (fd < 0) { xrt_mem_error(&s->pages_status, errno, "pagemap"); return; }
    xrt_mem_status(&s->pages_status, XRT_MEM_OK, 0, "read-only page metadata; PFNs not collected");
    uint64_t budget = l->pages;
    const uint64_t cpu_started = xrt_mem_clock(CLOCK_THREAD_CPUTIME_ID);
    uint32_t backend = XRT_MEM_BACKEND_SCAN, capacity = 0;
    for (uint32_t i = 0; i < s->vma_count; ++i) {
        const struct xrt_mem_vma *v = &s->vmas[i];
        uint64_t start = v->start;
        uint64_t stop = v->end;
        if (s->range_end) {
            if (start < s->range_start) start = s->range_start;
            if (stop > s->range_end) stop = s->range_end;
            if (stop <= start) continue;
        }
        if (start % s->page_size || v->end % s->page_size) {
            xrt_mem_status(&s->pages_status, XRT_MEM_PARTIAL, 0, "unaligned VMA range"); continue;
        }
        /* The x86 gate VMA has no user page-table entries. Keep its mapping
         * but publish no page-state evidence, for either page backend. */
        if (v->path_length == sizeof("[vsyscall]") - 1 &&
            !(v->flags & XRT_MEM_PATH_CUT) && !strcmp(s->paths + v->path, "[vsyscall]")) {
            if (!append(s, l, &capacity, i, XRT_MEM_BACKEND_NONE, start, stop, 0, 0)) goto done;
            s->scan_resume = stop;
            continue;
        }
        while (start < stop) {
            s->scan_resume = start;
            if (xrt_mem_clock(CLOCK_THREAD_CPUTIME_ID) - cpu_started >= l->scan_cpu_ns) {
                xrt_mem_status(&s->pages_status, XRT_MEM_PARTIAL, 0, "page scan CPU budget reached"); goto done;
            }
            if (backend == XRT_MEM_BACKEND_PAGEMAP && !budget) {
                xrt_mem_status(&s->pages_status, XRT_MEM_PARTIAL, 0, "pagemap page budget reached"); goto done;
            }
            uint64_t pages = (stop - start) / s->page_size;
            const uint64_t chunk = backend == XRT_MEM_BACKEND_SCAN ? (UINT64_C(1) << 30) / s->page_size : 4096;
            if (backend == XRT_MEM_BACKEND_PAGEMAP && pages > budget) pages = budget;
            if (pages > chunk) pages = chunk;
            uint64_t end = start + pages * s->page_size;
            if (backend == XRT_MEM_BACKEND_SCAN) {
                struct scan_region ranges[256];
                struct scan_request arg = {.size = sizeof(arg), .start = start, .end = end,
                    .vec = (uintptr_t)ranges, .vec_len = 256, .max_pages = pages, .return_mask = 255};
                int count;
                do { count = ioctl(fd, MEM_PAGEMAP_SCAN, &arg); } while (count < 0 && errno == EINTR);
                if (count < 0 && (errno == ENOTTY || errno == EINVAL || errno == EOPNOTSUPP)) {
                    backend = XRT_MEM_BACKEND_PAGEMAP;
                    continue;
                }
                if (count < 0) {
                    int error = errno;
                    if (!s->range_count) xrt_mem_error(&s->pages_status, error, "PAGEMAP_SCAN");
                    else xrt_mem_status(&s->pages_status, XRT_MEM_PARTIAL, error, "PAGEMAP_SCAN failed after partial coverage");
                    goto done;
                }
                if (count > 256 || arg.walk_end <= start || arg.walk_end > end || arg.walk_end % s->page_size) {
                    xrt_mem_status(&s->pages_status, XRT_MEM_INVALID, 0, "invalid PAGEMAP_SCAN continuation"); goto done;
                }
                uint64_t cursor = start;
                for (int j = 0; j < count; ++j) {
                    const struct scan_region *r = &ranges[j];
                    if (r->start < cursor || r->end <= r->start || r->end > arg.walk_end || r->start % s->page_size || r->end % s->page_size) {
                        xrt_mem_status(&s->pages_status, XRT_MEM_INVALID, 0, "invalid PAGEMAP_SCAN range"); goto done;
                    }
                    if (!append(s, l, &capacity, i, XRT_MEM_BACKEND_NONE, cursor, r->start, 0, 0)) goto done;
                    uint64_t categories, known; scan_bits(r->categories, &categories, &known);
                    if (!append(s, l, &capacity, i, backend, r->start, r->end, categories, known)) goto done;
                    cursor = r->end;
                }
                if (!append(s, l, &capacity, i, XRT_MEM_BACKEND_NONE, cursor, arg.walk_end, 0, 0)) goto done;
                start = arg.walk_end;
            } else {
                uint64_t values[4096];
                uint64_t offset = start / s->page_size;
                if (offset > INT64_MAX / 8) { xrt_mem_status(&s->pages_status, XRT_MEM_PARTIAL, 0, "pagemap file offset out of range"); goto done; }
                ssize_t bytes;
                do { bytes = pread(fd, values, (size_t)pages * 8, (off_t)(offset * 8)); } while (bytes < 0 && errno == EINTR);
                if (bytes <= 0 || bytes % 8) {
                    if (!s->range_count && bytes < 0) xrt_mem_error(&s->pages_status, errno, "pagemap read");
                    else xrt_mem_status(&s->pages_status, XRT_MEM_PARTIAL, bytes < 0 ? errno : 0, "short or failed pagemap read");
                    goto done;
                }
                uint64_t read_pages = (uint64_t)bytes / 8;
                for (uint64_t j = 0; j < read_pages; ++j) {
                    const uint64_t known = XRT_MEM_PAGE_PRESENT | XRT_MEM_PAGE_SWAPPED | XRT_MEM_PAGE_FILE |
                        XRT_MEM_PAGE_EXCLUSIVE | XRT_MEM_PAGE_SOFT_DIRTY;
                    if (!append(s, l, &capacity, i, backend, start, start + s->page_size, pagemap_bits(values[j]), known)) goto done;
                    start += s->page_size;
                }
                budget -= read_pages;
            }
        }
        s->scan_resume = stop;
    }
    if (s->maps_status.state != XRT_MEM_OK && s->pages_status.state == XRT_MEM_OK)
        xrt_mem_status(&s->pages_status, XRT_MEM_PARTIAL, 0, "page scan covers only the partial VMA list");
done:
    close(fd);
}
