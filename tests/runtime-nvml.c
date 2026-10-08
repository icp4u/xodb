#define _DEFAULT_SOURCE 1
#include "sysstat_nvml.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
static int64_t now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return (int64_t)t.tv_sec*1000000000+t.tv_nsec; }
int main(void) {
    struct xrt_sys_nvml *worker=NULL;
    struct xrt_sys_power power={0}; struct xrt_sys_group group={0};
    char pci[XRT_SYS_MAX_GPUS][32]={{"0000:01:00.0"}};
    power.gpu_count=1; strcpy(power.gpu[0].card,"card0"); strcpy(power.gpu[0].driver,"nvidia");
    power.gpu[0].busy_pct.st=XRT_SYS_UNAVAILABLE; power.gpu[0].busy_pct.why=XRT_SYS_WHY_NOT_SUPPORTED;
    power.gpu[0].vram_used.st=power.gpu[0].vram_total.st=XRT_SYS_UNAVAILABLE;
    const int absent=getenv("XODB_TEST_NVML_ABSENT")!=NULL || getenv("XODB_TEST_NVML_INIT_FAIL")!=NULL, slow=getenv("XODB_TEST_NVML_SLOW")!=NULL;
    const int64_t start=now(); int timeout_seen=0;
    while (now()-start < 1500000000) {
        strcpy(group.detail,"RAPL permission denied");
        const int64_t t=now(); xrt_sys_nvml_collect(&worker,&power,pci,&group,t);
        assert(now()-t < 20000000); /* caller never waits for a slow driver */
        if (strstr(group.detail,"exceeded 200 ms")) timeout_seen=1;
        if (power.gpu[0].busy_pct.st==XRT_SYS_OK || (absent && now()-start>100000000)) break;
        usleep(5000);
    }
    if (absent) {
        assert(power.gpu[0].busy_pct.st==XRT_SYS_UNAVAILABLE && power.gpu[0].busy_pct.why==XRT_SYS_WHY_NOT_SUPPORTED);
        assert(strstr(group.detail,"RAPL permission denied"));
        const char *reason = getenv("XODB_TEST_NVML_INIT_FAIL") ? "initialization failed (code 4)" : getenv("XODB_TEST_NVML_LOAD_FAIL") ? "not loadable" : "required ABI missing";
        assert(strstr(group.detail, reason));
    }
    else {
        assert(power.gpu[0].busy_pct.v==37 && power.gpu[0].temp_c.v==54);
        assert(power.gpu[0].vram_used.v==(getenv("XODB_TEST_NVML_LEGACY") ? 256 : 192) && power.gpu[0].vram_total.v==1024);
        if (getenv("XODB_TEST_NVML_LEGACY")) assert(strstr(group.detail,"includes reserved"));
        assert(power.gpu[0].graphics_mhz.v==1200 && power.gpu[0].memory_mhz.v==3000);
        if (getenv("XODB_TEST_NVML_DENY")) assert(power.gpu[0].power_w.st==XRT_SYS_UNAVAILABLE && power.gpu[0].power_w.why==XRT_SYS_WHY_NEEDS_PRIVILEGE);
        else assert(power.gpu[0].power_w.v>12.344 && power.gpu[0].power_w.v<12.346);
    }
    if (slow) assert(timeout_seen);
    if (!absent) {
        group.detail[0]=0;
        xrt_sys_nvml_collect(&worker,&power,pci,&group,now()+4000000000);
        assert(power.gpu[0].busy_pct.st==XRT_SYS_OK);
        group.detail[0]=0;
        xrt_sys_nvml_collect(&worker,&power,pci,&group,now()+6100000000);
        assert(power.gpu[0].busy_pct.st==XRT_SYS_STALE);
    }
    const int64_t t=now();xrt_sys_nvml_close(worker);assert(now()-t<20000000);
    usleep(1100000); /* let the detached worker observe shutdown, for leak checks */
    puts("NVML: values/units, unavailable fields, deadline and shutdown pass");
}
