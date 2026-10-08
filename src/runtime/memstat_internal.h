#ifndef XODB_MEMSTAT_INTERNAL_H
#define XODB_MEMSTAT_INTERNAL_H
#include "xrt_memstat.h"
#include <time.h>

uint64_t xrt_mem_clock(clockid_t clock);
void xrt_mem_status(struct xrt_mem_status *status, uint32_t state, int error,
                    const char *reason);
void xrt_mem_error(struct xrt_mem_status *status, int error, const char *source);
int xrt_mem_limits_valid(const struct xrt_mem_limits *limits);
char *xrt_mem_text(int root, const char *name, size_t cap, size_t *length,
                   struct xrt_mem_status *status);
void *xrt_mem_grow(void *storage, uint32_t *capacity, uint32_t count,
                   uint32_t limit, size_t size);
void *xrt_mem_trim(void *storage, size_t bytes);
int xrt_mem_u64(const char *text, uint64_t *value);
int xrt_mem_add(uint64_t a, uint64_t b, uint64_t *out);
void xrt_mem_pages(struct xrt_mem_process *snapshot, int pid_dir,
                   const struct xrt_mem_limits *limits);
#endif
