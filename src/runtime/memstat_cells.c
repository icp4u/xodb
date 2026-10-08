#include "xrt_memstat.h"
#include <string.h>

#define CATEGORIES ((UINT64_C(1) << 9) - 1)
#define CHANGES (XRT_MEM_PAGE_PRESENT | XRT_MEM_PAGE_SWAPPED | XRT_MEM_PAGE_FILE | XRT_MEM_PAGE_WRITTEN)
struct segment {
    const struct xrt_mem_vma *vma;
    uint64_t end, categories, known;
    int mapping_known, observed, anon;
};
static struct segment at(const struct xrt_mem_process *s, uint64_t address, uint64_t end)
{
    struct segment result = {.end = end};
    if (!s) return result;
    uint32_t lo = 0, hi = s->vma_count;
    while (lo < hi) {
        uint32_t mid = lo + (hi - lo) / 2;
        if (s->vmas[mid].end <= address) lo = mid + 1; else hi = mid;
    }
    result.mapping_known = s->maps_status.state == XRT_MEM_OK;
    if (lo == s->vma_count) return result;
    const struct xrt_mem_vma *v = &s->vmas[lo];
    if (address < v->start) { if (v->start < result.end) result.end = v->start; return result; }
    result.vma = v; result.mapping_known = 1;
    if (v->end < result.end) result.end = v->end;
    result.anon = !v->inode && !v->dev_major && !v->dev_minor && v->permissions[3] == 'p' &&
        (v->known & XRT_MEM_VMFLAGS) && !(v->flags & (XRT_MEM_VMA_HUGETLB | XRT_MEM_VMA_SPECIAL));
    lo = 0; hi = s->range_count;
    while (lo < hi) {
        uint32_t mid = lo + (hi - lo) / 2;
        if (s->ranges[mid].end <= address) lo = mid + 1; else hi = mid;
    }
    if (lo == s->range_count) return result;
    const struct xrt_mem_range *r = &s->ranges[lo];
    if (address < r->start) { if (r->start < result.end) result.end = r->start; return result; }
    if (r->end < result.end) result.end = r->end;
    result.categories = r->categories; result.known = r->known;
    result.observed = r->backend != XRT_MEM_BACKEND_NONE;
    return result;
}
int xrt_mem_cell_read(const struct xrt_mem_process *current,
    const struct xrt_mem_process *previous, uint64_t start, uint64_t end,
    struct xrt_mem_cell *out)
{
    if (!current || !out || end <= start || !current->page_size ||
        start % current->page_size || end % current->page_size) return 0;
    *out = (struct xrt_mem_cell){.start = start, .end = end, .known = CATEGORIES,
        .categories_all = CATEGORIES, .change_known = CHANGES, .mapping_known = 1, .pmd_change_known = 1};
    if (!previous || previous->pid != current->pid || !current->start_ticks ||
        previous->start_ticks != current->start_ticks || previous->started_ns >= current->started_ns) previous = NULL;
    for (uint64_t pos = start; pos < end;) {
        struct segment cur = at(current, pos, end), old = at(previous, pos, end);
        uint64_t next = cur.end < old.end ? cur.end : old.end;
        if (next <= pos) return 0;
        uint64_t bytes = next - pos;
        out->mapped_bytes += cur.vma ? bytes : 0;
        out->observed_bytes += cur.observed ? bytes : 0;
        out->mapping_known &= cur.mapping_known;
        out->known &= cur.known;
        out->categories |= cur.categories & cur.known;
        out->categories_all &= cur.categories & cur.known;
        uint64_t comparison = cur.known & old.known & CHANGES;
        out->change_known &= comparison;
        out->changed_categories |= (cur.categories ^ old.categories) & comparison;
        const uint64_t thp_bits = XRT_MEM_PAGE_HUGE | XRT_MEM_PAGE_ZERO;
        int pmd_known = previous && current->pmd_size_known && previous->pmd_size_known &&
            current->pmd_size == previous->pmd_size && cur.anon && old.anon &&
            (cur.known & old.known & thp_bits) == thp_bits;
        out->pmd_change_known &= !!pmd_known;
        /* A huge zero mapping has no backed THP. Writing it can clear ZERO
         * without changing HUGE, and is still a collapse for this view. */
        int cur_thp = (cur.categories & thp_bits) == XRT_MEM_PAGE_HUGE;
        int old_thp = (old.categories & thp_bits) == XRT_MEM_PAGE_HUGE;
        if (pmd_known && cur_thp != old_thp) {
            if (cur_thp) out->collapsed_bytes += bytes;
            else out->split_bytes += bytes;
        }
        pos = next;
    }
    out->mixed = (out->categories ^ out->categories_all) & out->known;
    /* A highlight is valid only if the whole cell's corresponding comparison
     * is observable. Partial evidence remains available as byte coverage. */
    out->changed_categories &= out->change_known;
    if (!out->pmd_change_known) out->collapsed_bytes = out->split_bytes = 0;
    return 1;
}
void xrt_mem_system_delta(struct xrt_mem_system *current, const struct xrt_mem_system *previous)
{
    if (!current) return;
    current->delta_interval_ns = 0;
    for (uint32_t i = 0; i < current->counter_count; ++i) {
        struct xrt_mem_counter *c = &current->counters[i];
        c->delta = 0; c->delta_known = c->reset = 0;
    }
    if (!previous || current->started_ns <= previous->started_ns ||
        current->vmstat_status.state != XRT_MEM_OK || previous->vmstat_status.state != XRT_MEM_OK) return;
    current->delta_interval_ns = current->started_ns - previous->started_ns;
    for (uint32_t i = 0; i < current->counter_count; ++i) {
        struct xrt_mem_counter *c = &current->counters[i];
        if (!c->cumulative) continue;
        for (uint32_t j = 0; j < previous->counter_count; ++j) {
            const struct xrt_mem_counter *p = &previous->counters[j];
            if (!p->cumulative || strcmp(c->name, p->name)) continue;
            if (c->value < p->value) c->reset = 1;
            else { c->delta = c->value - p->value; c->delta_known = 1; }
            break;
        }
    }
}
