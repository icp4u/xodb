/* Inspect and fuzz the bounded local-file symbol/debug worker. The file
 * identity functions are linked from the production runtime. All mutations
 * stay in a caller-owned work file; no target-supplied path is opened. */
#define _GNU_SOURCE 1
#include "../src/binary/macho_job.h"
#include "check.h"
#include "../src/runtime/xrt_files.h"
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
static int hexv(int c) { return c>='0'&&c<='9'?c-'0':c>='a'&&c<='f'?c-'a'+10:c>='A'&&c<='F'?c-'A'+10:-1; }
static uint64_t rng_state = 88172645463325252ull;
static uint64_t rng(void) { rng_state ^= rng_state<<13; rng_state ^= rng_state>>7; rng_state ^= rng_state<<17; return rng_state; }
static struct xmo_job *run(const char *file, const unsigned char uuid[16], uint32_t cpu, uint32_t sub, struct xmo_job_snapshot *snap, uint64_t allowance) {
    const char *fixed = getenv("XMO_FIXED_EXE");
    struct xmo_job_options o = {.executable = fixed ? fixed : file, .basename = "x", .cputype = cpu, .cpusubtype = sub, .allowance = allowance};
    memcpy(o.uuid, uuid, 16);
    struct xmo_job *j = NULL;
    *snap=(struct xmo_job_snapshot){.state=XMO_JOB_FAILED,.status=XMO_UNAVAILABLE};
    if (xmo_job_start(&o, &j) != XMO_OK) { snap->state = XMO_JOB_FAILED; return NULL; }
    const struct timespec pause = {.tv_nsec = 200000};
    while (xmo_job_join(j) == 0) nanosleep(&pause, NULL);
    xmo_job_poll(j, snap);
    return j;
}
int main(int argc, char **argv) {
    if (argc < 6 || strlen(argv[3]) != 32) return 2;
    unsigned char uuid[16];
    for (int i=0;i<16;++i) uuid[i] = (unsigned char)(hexv(argv[3][2*i])*16+hexv(argv[3][2*i+1]));
    uint32_t cpu = (uint32_t)strtoul(argv[4],NULL,0), sub = (uint32_t)strtoul(argv[5],NULL,0);
    static char name[XMO_MAX_NAME+1];
    if (!strcmp(argv[1],"one")) {
        struct xmo_job_snapshot s;
        uint64_t allowance = getenv("ALLOWANCE") ? strtoull(getenv("ALLOWANCE"),NULL,0) : XMO_MAX_RETAINED_BYTES;
        struct timespec a,b; clock_gettime(CLOCK_MONOTONIC,&a);
        struct xmo_job *j = run(argv[2], uuid, cpu, sub, &s, allowance);
        clock_gettime(CLOCK_MONOTONIC,&b);
        printf("state=%d failure=%d status=%s reads=%llu bytes=%llu retained=%llu ms=%.1f\n", s.state, s.failure, xmo_status_name(s.status),
            (unsigned long long)s.source_reads,(unsigned long long)s.source_bytes,(unsigned long long)s.retained_bytes,
            (b.tv_sec-a.tv_sec)*1e3+(b.tv_nsec-a.tv_nsec)/1e6);
        for (int i=6;i<argc;++i) {
            uint64_t value=0,size=0,address=strtoull(argv[i],NULL,0);
            enum xmo_status st = xmo_job_symbol(j,address,name,sizeof name,&value,&size);
            printf("0x%llx -> %s %s value=0x%llx size=0x%llx\n",(unsigned long long)address,xmo_status_name(st),name,(unsigned long long)value,(unsigned long long)size);
        }
        xmo_job_destroy(j);
        return 0;
    }
    if (argc < 8) return 2;
    if (argc > 8) rng_state = strtoull(argv[8],NULL,0)|1;
    FILE *f = fopen(argv[2],"rb"); if (!f) return 2;
    static unsigned char seed[8<<20], work[8<<20];
    size_t n = fread(seed,1,sizeof seed,f); fclose(f);
    if (!n) return 2;
    time_t end = time(NULL)+atoi(argv[6]);
    unsigned long runs=0, ready=0, names=0, hist[12]={0};
    while (time(NULL) < end) {
        memcpy(work,seed,n);
        size_t size = n;
        unsigned edits = 1+(unsigned)(rng()%8);
        for (unsigned e=0;e<edits;++e) {
            /* Bias towards the header, load commands and the symbol table region. */
            size_t limit = rng()%4 ? (n < 4096 ? n : 4096) : n;
            size_t at = (size_t)(rng()%limit);
            switch (rng()%6) {
            case 0: work[at] = (unsigned char)rng(); break;
            case 1: work[at] ^= (unsigned char)(1u<<(rng()%8)); break;
            case 2: if (at+4<=n) { uint32_t v = (uint32_t[]){0,1,0x7fffffff,0x80000000,0xffffffff,0xfffffff0,(uint32_t)n,(uint32_t)n-1,(uint32_t)n+1,0x10000}[rng()%10]; memcpy(work+at,&v,4); } break;
            case 3: if (at+8<=n) { uint64_t v = (uint64_t[]){0,~0ull,0x8000000000000000ull,0x7fffffffffffffffull,0xfffffffffffff000ull,(uint64_t)n}[rng()%6]; memcpy(work+at,&v,8); } break;
            case 4: size = (size_t)(rng()%(n+1)); break;
            case 5: if (at+16<=n) memset(work+at, (int)(rng()&0xff), 16); break;
            }
        }
        int fd = open(argv[7],O_WRONLY|O_CREAT|O_TRUNC,0644);
        if (fd<0 || write(fd,work,size)!=(ssize_t)size) return 3;
        close(fd);
        struct xmo_job_snapshot s;
        struct xmo_job *j = run(argv[7], uuid, cpu, sub, &s, (rng()&3) ? XMO_MAX_RETAINED_BYTES : 1+(rng()%65536));
        ++runs;
        if (s.state == XMO_JOB_READY) {
            ++ready;
            const struct xmo_info *info = xmo_job_info(j);
            if (!info) __builtin_trap();
            CHECK(s.retained_bytes <= XMO_MAX_RETAINED_BYTES);
            const struct xmo_dwarf *debug = NULL;
            enum xmo_debug_status ds = xmo_job_debug(j, &debug);
            CHECK((ds == XMO_DEBUG_READY) == (debug != NULL));
            if (debug) CHECK(debug->bytes && debug->size <= s.retained_bytes);
            uint64_t base = info->text_vmaddr;
            for (unsigned k=0;k<400;++k) {
                uint64_t address = k<300 ? base+(rng()%0x10000) : rng(), value, sz;
                uint32_t object = 0;uint64_t object_pc = 0,back = 0;
                const struct xmo_dwarf *dwarf = NULL;
                enum xmo_status os = xmo_job_object(j,address,&object,&object_pc,&dwarf);
                if (os == XMO_OK) {
                    CHECK(dwarf && dwarf->bytes && dwarf->size <= s.retained_bytes);
                    CHECK(xmo_job_object_address(j,object,object_pc,&back) == XMO_OK && back == address);
                }
                struct xmu_row row;
                enum xmo_status us = xmo_job_compact(j,address,&row);
                if (us == XMO_OK) CHECK(address >= base+row.start && address < base+row.end);
                enum xmo_status st = xmo_job_symbol(j,address,name,sizeof name,&value,&sz);
                if (st==XMO_OK) { ++names; if (strlen(name)>XMO_MAX_NAME || value>address || address-value>=sz) __builtin_trap(); }
                if ((unsigned)st<12) ++hist[st];
            }
        }
        if ((unsigned)s.failure<12) ++hist[0]; /* keep the counter live */
        xmo_job_destroy(j);
    }
    printf("runs=%lu ready=%lu names=%lu lookup ok=%lu notfound=%lu unavailable=%lu other=%lu\n",runs,ready,names,hist[XMO_OK],hist[XMO_NOT_FOUND],hist[XMO_UNAVAILABLE],hist[XMO_MALFORMED]+hist[XMO_LIMIT]+hist[XMO_CHANGED]);
    return 0;
}
