#ifndef XODB_RUNTIME_MEMSTAT_H
#define XODB_RUNTIME_MEMSTAT_H

/* Read-only, bounded Linux memory observations. These are page metadata, not
 * target memory bytes. No dirty bits, protections or system settings change.
 * Each call observes an interval, not an atomic view of the kernel. */
#include <stddef.h>
#include <stdint.h>

enum xrt_mem_state {
    XRT_MEM_OK, XRT_MEM_UNAVAILABLE, XRT_MEM_DENIED, XRT_MEM_EXITED,
    XRT_MEM_IDENTITY_CHANGED, XRT_MEM_PARTIAL, XRT_MEM_INVALID
};
struct xrt_mem_status {
    uint32_t state;
    int32_t error;
    char reason[128];
};
struct xrt_mem_limits {
    uint32_t vmas, ranges, zones, counters, settings;
    uint32_t text_bytes, path_bytes;
    uint64_t pages; /* Plain-pagemap fallback work bound. */
    uint64_t scan_cpu_ns; /* PAGEMAP_SCAN CPU budget; checked between bounded ioctls. */
};
struct xrt_mem_roots {
    /* NULL selects /proc and /sys. Alternative roots are for owned fixtures,
     * never accepted from an observer's MCP arguments. */
    const char *proc, *sys;
};
struct xrt_mem_request {
    int32_t pid;
    uint32_t flags;
    uint64_t start_ticks;
    /* Both zero scans the bounded VMA set. Otherwise these page-aligned
     * addresses select a half-open range; smaps metadata still covers VMAs. */
    uint64_t range_start, range_end;
};
#define XRT_MEM_SKIP_PAGES 1u
#define XRT_MEM_NUMA 2u /* Request the additional numa_maps walk explicitly. */
void xrt_mem_limits_default(struct xrt_mem_limits *limits);

#define XRT_MEM_RSS             (UINT64_C(1) << 0)
#define XRT_MEM_PSS             (UINT64_C(1) << 1)
#define XRT_MEM_ANONYMOUS       (UINT64_C(1) << 2)
#define XRT_MEM_ANON_HUGE       (UINT64_C(1) << 3)
#define XRT_MEM_FILE_PMD        (UINT64_C(1) << 4)
#define XRT_MEM_SHMEM_PMD       (UINT64_C(1) << 5)
#define XRT_MEM_SWAP            (UINT64_C(1) << 6)
#define XRT_MEM_LOCKED          (UINT64_C(1) << 7)
#define XRT_MEM_ELIGIBLE        (UINT64_C(1) << 8)
#define XRT_MEM_KERNEL_PAGE     (UINT64_C(1) << 9)
#define XRT_MEM_MMU_PAGE        (UINT64_C(1) << 10)
#define XRT_MEM_PRIVATE_HUGETLB (UINT64_C(1) << 11)
#define XRT_MEM_SHARED_HUGETLB  (UINT64_C(1) << 12)
#define XRT_MEM_VMFLAGS         (UINT64_C(1) << 13)

#define XRT_MEM_PATH_CUT 1u
#define XRT_MEM_NUMA_CUT 2u
#define XRT_MEM_BAD_METRIC 4u
#define XRT_MEM_VMA_HUGETLB 8u
#define XRT_MEM_VMA_SPECIAL 16u
struct xrt_mem_node { uint32_t node; uint64_t pages; };
struct xrt_mem_vma {
    uint64_t start, end, offset, inode;
    uint32_t dev_major, dev_minor, flags;
    char permissions[5];
    uint32_t path, path_length;
    uint64_t known;
    uint64_t rss, pss, anonymous, anon_huge, file_pmd, shmem_pmd;
    uint64_t swap, locked, kernel_page, mmu_page, private_hugetlb, shared_hugetlb;
    uint8_t thp_eligible, numa_count, numa_available;
    uint64_t numa_page_size; /* Bytes per reported NUMA page; zero when absent. */
    struct xrt_mem_node numa[16]; /* Per-VMA totals, not per-page locations. */
};

/* Common categories retain separate known bits. A clear unknown bit does not
 * mean false. HUGE means PMD-mapped THP or hugetlb, not all multi-size THP.
 * FILE in plain pagemap also includes shared anonymous pages. */
#define XRT_MEM_PAGE_PRESENT    (UINT64_C(1) << 0)
#define XRT_MEM_PAGE_SWAPPED    (UINT64_C(1) << 1)
#define XRT_MEM_PAGE_FILE       (UINT64_C(1) << 2)
#define XRT_MEM_PAGE_HUGE       (UINT64_C(1) << 3)
#define XRT_MEM_PAGE_WRITTEN    (UINT64_C(1) << 4)
#define XRT_MEM_PAGE_ZERO       (UINT64_C(1) << 5)
#define XRT_MEM_PAGE_EXCLUSIVE  (UINT64_C(1) << 6)
#define XRT_MEM_PAGE_SOFT_DIRTY (UINT64_C(1) << 7)
#define XRT_MEM_PAGE_WP_TRACKED (UINT64_C(1) << 8)
enum xrt_mem_backend { XRT_MEM_BACKEND_NONE, XRT_MEM_BACKEND_SCAN, XRT_MEM_BACKEND_PAGEMAP };
struct xrt_mem_range {
    uint64_t start, end, categories, known;
    uint32_t vma, backend;
};
struct xrt_mem_process {
    struct xrt_mem_status maps_status, pages_status, numa_status, rollup_status;
    int32_t pid;
    uint64_t start_ticks, started_ns, finished_ns, cpu_ns, page_size;
    char name[64];
    uint32_t vma_count, range_count, path_length;
    uint64_t range_start, range_end;
    uint64_t mapped_bytes, scanned_bytes, scan_resume;
    uint64_t rss, anonymous, anon_huge, swap, totals_known;
    uint64_t rollup_rss, rollup_anonymous, rollup_anon_huge, rollup_swap, rollup_known;
    /* Resident anonymous subtotals; not a coverage denominator. */
    uint64_t eligible_anonymous, eligible_anon_huge, unknown_eligibility_anonymous;
    uint64_t pmd_size, coverage_numerator, coverage_denominator;
    uint8_t pmd_size_known, coverage_numerator_known, coverage_denominator_known;
    struct xrt_mem_vma *vmas;
    struct xrt_mem_range *ranges;
    char *paths;
};

#define XRT_MEM_MAX_ORDERS 32u
struct xrt_mem_zone {
    uint32_t node, orders;
    char name[32];
    uint64_t blocks[XRT_MEM_MAX_ORDERS];
    uint64_t free_pages, free_blocks;
};
struct xrt_mem_counter {
    char name[64];
    uint64_t value, delta;
    uint8_t cumulative, delta_known, reset;
};
struct xrt_mem_setting {
    char name[96], value[160];
    struct xrt_mem_status status;
};
struct xrt_mem_system {
    struct xrt_mem_status buddy_status, vmstat_status, thp_status, zswap_status;
    uint64_t started_ns, finished_ns, cpu_ns, page_size;
    uint64_t delta_interval_ns; /* Successive publication starts; system-wide only. */
    uint32_t zone_count, counter_count, setting_count;
    struct xrt_mem_zone *zones;
    struct xrt_mem_counter *counters;
    struct xrt_mem_setting *settings;
};
struct xrt_mem_fragmentation {
    uint64_t suitable_blocks, suitable_pages;
    int32_t index_permille; /* Kernel formula; -1000 means a suitable block exists.
                            * A single smaller free block can also yield a negative index. */
    uint32_t unusable_permille; /* Free pages in smaller-than-requested blocks. */
};
/* Returns zero for invalid order or overflowing input. Zero free memory has
 * index 0; zone.free_pages distinguishes it from low fragmentation. */
int xrt_mem_fragmentation(const struct xrt_mem_zone *zone, uint32_t order,
                          struct xrt_mem_fragmentation *out);

/* A fixed virtual-address cell. Gaps retain their address and mapped_bytes=0;
 * mixed cells expose any/all separately. Unknown never means false. NUMA is
 * available only as the intersected VMAs' totals, not exact page locations.
 * Changes compare observations, not events: unmap/remap between polls can be
 * missed. Physical migration is never observable through this interface. */
struct xrt_mem_cell {
    uint64_t start, end, mapped_bytes, observed_bytes;
    uint64_t categories, categories_all, known, mixed;
    uint64_t changed_categories, change_known;
    uint64_t collapsed_bytes, split_bytes;
    uint8_t mapping_known, pmd_change_known, physical_change_known;
};
int xrt_mem_cell_read(const struct xrt_mem_process *current,
    const struct xrt_mem_process *previous, uint64_t start, uint64_t end,
    struct xrt_mem_cell *out);
/* Compare successive raw system snapshots. Missing/reset counters are unknown;
 * gauges have no delta. Neither client reads nor serialization move a baseline. */
void xrt_mem_system_delta(struct xrt_mem_system *current,
    const struct xrt_mem_system *previous);

/* The caller owns each returned snapshot and frees it with the matching
 * function. Failures of individual sources are represented in their status.
 * A zero expected_start binds the initial identity; the result records it.
 * Nonzero expected_start must match before and after the process observation. */
struct xrt_mem_process *xrt_mem_process_read(const struct xrt_mem_roots *roots,
    const struct xrt_mem_limits *limits, const struct xrt_mem_request *request);
void xrt_mem_process_free(struct xrt_mem_process *snapshot);
struct xrt_mem_system *xrt_mem_system_read(const struct xrt_mem_roots *roots,
    const struct xrt_mem_limits *limits);
void xrt_mem_system_free(struct xrt_mem_system *snapshot);

#endif
