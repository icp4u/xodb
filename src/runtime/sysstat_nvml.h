#ifndef XODB_SYSSTAT_NVML_H
#define XODB_SYSSTAT_NVML_H
#include "xrt_sysstat.h"
struct xrt_sys_nvml;
/* Nonblocking owner-side interface. One detached worker owns all NVML calls;
 * a stuck driver cannot stall sampling or shutdown, or create more workers.
 * The worker owns its allocation until it observes shutdown. */
void xrt_sys_nvml_collect(struct xrt_sys_nvml **, struct xrt_sys_power *,
                          const char pci[XRT_SYS_MAX_GPUS][32], struct xrt_sys_group *, int64_t now);
uint64_t xrt_sys_nvml_cpu(struct xrt_sys_nvml *); /* completed worker CPU since last read */
void xrt_sys_nvml_close(struct xrt_sys_nvml *);
#endif
