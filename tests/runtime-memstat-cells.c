#include "xrt_memstat.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

int main(void)
{
    const uint64_t p = 4096, h = 2u << 20;
    struct xrt_mem_vma v = {.start = h, .end = 2*h, .known = XRT_MEM_VMFLAGS, .permissions = "rw-p"};
    const uint64_t known = XRT_MEM_PAGE_PRESENT | XRT_MEM_PAGE_SWAPPED | XRT_MEM_PAGE_FILE | XRT_MEM_PAGE_HUGE | XRT_MEM_PAGE_ZERO;
    struct xrt_mem_range before = {h, 2*h, XRT_MEM_PAGE_PRESENT | XRT_MEM_PAGE_HUGE, known, 0, XRT_MEM_BACKEND_SCAN};
    struct xrt_mem_range after[2] = {{h, h+p, 0, known, 0, XRT_MEM_BACKEND_SCAN},
        {h+p, 2*h, XRT_MEM_PAGE_PRESENT, known, 0, XRT_MEM_BACKEND_SCAN}};
    struct xrt_mem_process old = {.pid = 42, .start_ticks = 123, .started_ns = 1, .page_size = p,
        .pmd_size = h, .pmd_size_known = 1, .vma_count = 1, .range_count = 1, .vmas = &v, .ranges = &before};
    struct xrt_mem_process cur = old; cur.started_ns = 1001; cur.ranges = after; cur.range_count = 2;
    struct xrt_mem_cell c;
    assert(xrt_mem_cell_read(&cur, &old, h, 2*h, &c));
    assert(c.mapping_known && c.mapped_bytes == h && c.observed_bytes == h);
    assert(c.categories == XRT_MEM_PAGE_PRESENT && !c.categories_all);
    assert(c.mixed == XRT_MEM_PAGE_PRESENT && c.changed_categories == XRT_MEM_PAGE_PRESENT);
    assert(!(c.change_known & XRT_MEM_PAGE_WRITTEN));
    assert(c.pmd_change_known && c.split_bytes == h && !c.collapsed_bytes && !c.physical_change_known);
    assert(xrt_mem_cell_read(&cur, &old, h, h+p, &c));
    assert(c.split_bytes == p && c.changed_categories == XRT_MEM_PAGE_PRESENT);
    assert(xrt_mem_cell_read(&cur, NULL, h, 2*h, &c) && !c.change_known && !c.pmd_change_known);
    {
        struct xrt_mem_range zero = before, backed = before;
        zero.categories |= XRT_MEM_PAGE_ZERO;
        struct xrt_mem_process a = old, b = cur;
        a.ranges = &zero; b.ranges = &backed; b.range_count = 1;
        assert(xrt_mem_cell_read(&b, &a, h, 2*h, &c));
        assert(c.pmd_change_known && c.collapsed_bytes == h && !c.split_bytes);
        a.ranges = &backed; b.ranges = &zero;
        assert(xrt_mem_cell_read(&b, &a, h, 2*h, &c));
        assert(c.pmd_change_known && c.split_bytes == h && !c.collapsed_bytes);
        backed.categories = XRT_MEM_PAGE_PRESENT;
        assert(xrt_mem_cell_read(&b, &a, h, 2*h, &c));
        assert(c.pmd_change_known && !c.split_bytes && !c.collapsed_bytes);
        zero.known &= ~XRT_MEM_PAGE_ZERO;
        assert(xrt_mem_cell_read(&b, &a, h, 2*h, &c));
        assert(!c.pmd_change_known && !c.split_bytes && !c.collapsed_bytes);
    }
    old.start_ticks++;
    assert(xrt_mem_cell_read(&cur, &old, h, 2*h, &c) && !c.change_known && !c.pmd_change_known);
    old.start_ticks--;
    for (unsigned i = 0; i < 2; ++i) { after[i].backend = XRT_MEM_BACKEND_PAGEMAP; after[i].known &= ~XRT_MEM_PAGE_HUGE; }
    assert(xrt_mem_cell_read(&cur, &old, h, 2*h, &c) && !c.pmd_change_known && !c.split_bytes);
    assert(c.change_known & XRT_MEM_PAGE_PRESENT);
    assert(xrt_mem_cell_read(&cur, &old, 0, h, &c) && c.mapping_known && !c.mapped_bytes && !c.known);
    cur.maps_status.state = XRT_MEM_PARTIAL;
    assert(xrt_mem_cell_read(&cur, &old, 0, h, &c) && !c.mapping_known);
    assert(!xrt_mem_cell_read(&cur, &old, 1, h, &c));
    struct xrt_mem_counter counters[3] = {{.name = "thp_collapse_alloc", .value = 25, .cumulative = 1},
        {.name = "compact_stall", .value = 10, .cumulative = 1}, {.name = "nr_anon_pages", .value = 100}};
    struct xrt_mem_counter previous[3]; memcpy(previous, counters, sizeof(previous));
    previous[0].value = 20; previous[1].value = 15; previous[2].value = 60;
    struct xrt_mem_system sys = {.started_ns = 1001, .counters = counters, .counter_count = 3};
    struct xrt_mem_system prior = {.started_ns = 1, .counters = previous, .counter_count = 3};
    xrt_mem_system_delta(&sys, &prior);
    assert(sys.delta_interval_ns == 1000 && counters[0].delta_known && counters[0].delta == 5);
    assert(!counters[1].delta_known && counters[1].reset && !counters[2].delta_known);
    xrt_mem_system_delta(&sys, NULL);
    assert(!sys.delta_interval_ns && !counters[0].delta_known && !counters[1].reset);
    puts("memory cells: fixed gaps, mixed states, distinct changes, fallback unknown, identity and counter resets passed");
    return 0;
}
