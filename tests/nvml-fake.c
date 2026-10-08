/* Owned test library implementing the tiny NVML ABI used by the observer. */
#define _DEFAULT_SOURCE 1
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
struct utilization { unsigned gpu, memory; };
struct memory { unsigned long long total, free, used; };
int nvmlInit_v2(void) { return getenv("XODB_TEST_NVML_INIT_FAIL") ? 4 : 0; }
int nvmlShutdown(void) { return 0; }
int nvmlDeviceGetHandleByPciBusId_v2(const char *pci, void **out) { (void)pci; *out=(void *)1; return 0; }
int nvmlDeviceGetUtilizationRates(void *device, struct utilization *out) {
    (void)device;
    if (getenv("XODB_TEST_NVML_SLOW")) usleep(600000);
    out->gpu=37; out->memory=22; return 0;
}
int nvmlDeviceGetPowerUsage(void *device, unsigned *out) { (void)device; *out=12345; return getenv("XODB_TEST_NVML_DENY") ? 4 : 0; }
int nvmlDeviceGetTemperature(void *device, unsigned kind, unsigned *out) { (void)device; (void)kind; *out=54; return 0; }
int nvmlDeviceGetMemoryInfo(void *device, struct memory *out) { (void)device; *out=(struct memory){1024,768,256}; return 0; }
int nvmlDeviceGetClockInfo(void *device, unsigned kind, unsigned *out) { (void)device; *out=kind==2 ? 3000 : 1200; return 0; }
int nvmlDeviceGetName(void *device, char *out, unsigned size) { (void)device; if (size<15) return 2; strcpy(out,"Synthetic GPU"); return 0; }

#ifndef XODB_TEST_NVML_LEGACY
struct memory_v2 { unsigned version; unsigned long long total, reserved, free, used; };
int nvmlDeviceGetMemoryInfo_v2(void *device, struct memory_v2 *out) {
    (void)device;
    if (out->version != ((unsigned)sizeof(*out) | (2u << 24))) return 25;
    *out=(struct memory_v2){(unsigned)sizeof(*out) | (2u << 24),1024,64,768,192};
    return 0;
}
#endif
