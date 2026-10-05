#define _GNU_SOURCE 1
#include "xrt_uprobes.h"
#include "xrt_remote.h"
#include "perf_remote.h"
#include <assert.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/perf_event.h>
#include <stdio.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#if defined(__x86_64__)
#include <asm/perf_regs.h>
#endif
#define OK(expr) do { enum xrt_status status_ = (expr); if (status_ != XRT_OK) { \
    fprintf(stderr, "%s:%d %s: %d\n", __FILE__, __LINE__, #expr, status_); abort(); } } while (0)
__attribute__((noinline)) static uint64_t observed(uint64_t a, uint64_t b, uint64_t c,
                                                  uint64_t d, uint64_t e, uint64_t f)
{
    __asm__ volatile("" : "+r"(a), "+r"(b), "+r"(c), "+r"(d), "+r"(e), "+r"(f));
    return a + 3*b + 5*c + 7*d + 11*e + 13*f;
}
static uint64_t argument(unsigned call, unsigned at)
{
    return UINT64_C(0x1234567800000000) + call * 101 + (at + 1) * 19;
}
static uint64_t expected(unsigned call)
{
    return argument(call,0) + 3*argument(call,1) + 5*argument(call,2) +
           7*argument(call,3) + 11*argument(call,4) + 13*argument(call,5);
}
static int fixture(void)
{
    for (unsigned i = 0; i < 8; ++i)
        assert(observed(argument(i,0), argument(i,1), argument(i,2), argument(i,3),
                        argument(i,4), argument(i,5)) == expected(i));
    return 0;
}
static struct xrt_target_view view(struct xrt_target *t)
{
    struct xrt_target_view v;
    xrt_target_view(t, &v);
    return v;
}
static size_t descriptors(void)
{
    DIR *d = opendir("/proc/self/fd");
    assert(d);
    size_t n = 0;
    struct dirent *e;
    while ((e = readdir(d)))
        if (e->d_name[0] != '.') ++n;
    closedir(d);
    return n;
}
static struct xrt_mapping mapping(struct xrt_target *t, const char *self)
{
    int fd;
    struct xrt_file_request r = {.kind = XRT_FILE_MAPS};
    OK(xrt_target_file(t, &r, &fd));
    FILE *f = fdopen(fd, "r");
    assert(f);
    char line[8192];
    struct xrt_mapping m = {0};
    const uint64_t address = (uintptr_t)observed;
    while (fgets(line, sizeof(line), f)) {
        unsigned long long start, end, offset, major, minor, inode;
        char permissions[5];
        if (sscanf(line, "%llx-%llx %4s %llx %llx:%llx %llu", &start, &end, permissions,
                   &offset, &major, &minor, &inode) != 7 || permissions[2] != 'x' ||
            address < start || address >= end)
            continue;
        m = (struct xrt_mapping){start,end,offset,major,minor,inode,self};
        break;
    }
    fclose(f);
    assert(m.inode);
    return m;
}
static bool cancelled(void *context)
{
    (void)context;
    return true;
}
static uint64_t u64(const unsigned char *p)
{
    uint64_t n;
    memcpy(&n, p, 8);
    return n;
}
struct evidence {
    unsigned entries, returns, metadata;
    int32_t pid;
    bool stacks;
    uint64_t entry_sp, caller, entry_time;
};
static struct xrt_perf_consumed decode(void *raw, const struct xrt_perf_ring *ring)
{
    struct evidence *e = raw;
    uint64_t used = 0;
    while (used < ring->head - ring->tail) {
        struct perf_event_header h;
        assert(xrt_perf_copy(ring->data, ring->size, ring->tail + used, &h, 8));
        assert(h.size >= 8 && !(h.size & 7) && h.size <= ring->head - ring->tail - used);
        unsigned char bytes[4096];
        assert(h.size <= sizeof(bytes));
        assert(xrt_perf_copy(ring->data, ring->size, ring->tail + used, bytes, h.size));
        used += h.size;
        if (h.type != PERF_RECORD_SAMPLE) {
            assert(h.type != PERF_RECORD_LOST && h.type != PERF_RECORD_LOST_SAMPLES);
            ++e->metadata;
            continue;
        }
        assert((h.misc & PERF_RECORD_MISC_CPUMODE_MASK) == PERF_RECORD_MISC_USER);
        assert(h.size >= 112);
        uint32_t pid,tid;
        memcpy(&pid,bytes+8,4); memcpy(&tid,bytes+12,4);
        assert(pid == (uint32_t)e->pid && tid == (uint32_t)ring->thread->tid);
        assert(ring->thread->event_count == 2);
        const uint64_t id = u64(bytes+24);
        bool returning = id == ring->thread->event_ids[1];
        assert(returning || id == ring->thread->event_ids[0]);
        size_t at = 32;
        if (e->stacks && !returning) {
            uint64_t count = u64(bytes+at);
            assert(count <= 34 && count <= (h.size-at-8)/8);
            at += 8 + count*8;
        }
        assert(at <= h.size && h.size-at >= 80 && u64(bytes+at) == PERF_SAMPLE_REGS_ABI_64);
        at += 8;
        uint64_t regs[9];
        memcpy(regs,bytes+at,sizeof(regs));
        at += sizeof(regs);
        if (e->stacks && !returning) {
            assert(h.size-at >= 8);
            const uint64_t size = u64(bytes+at);
            at += 8;
            assert(size == 0 || size == 8);
            e->caller = 0;
            if (size) {
                assert(h.size-at >= 16 && u64(bytes+at+8) <= size);
                if (u64(bytes+at+8) == 8) e->caller = u64(bytes+at);
                at += 16;
            }
        }
        assert(at == h.size);
        if (!returning) {
            assert(e->entries == e->returns && e->entries < 8);
            const unsigned order[] = {4,3,2,1,7,8};
            for (unsigned j=0;j<6;++j) assert(regs[order[j]] == argument(e->entries,j));
            assert(regs[6] == (uintptr_t)observed);
            e->entry_sp = regs[5]; e->entry_time = u64(bytes+16);
            if (!e->entries)
                printf("entry raw AX=%llx CX=%llx DX=%llx SI=%llx DI=%llx SP=%llx IP=%llx R8=%llx R9=%llx\n",
                       (unsigned long long)regs[0], (unsigned long long)regs[1], (unsigned long long)regs[2],
                       (unsigned long long)regs[3], (unsigned long long)regs[4], (unsigned long long)regs[5],
                       (unsigned long long)regs[6], (unsigned long long)regs[7], (unsigned long long)regs[8]);
            ++e->entries;
        } else {
            assert(e->entries == e->returns+1);
            assert(regs[0] == expected(e->returns));
            assert(regs[5] == e->entry_sp+8 && u64(bytes+16) >= e->entry_time);
            if (e->stacks) assert(e->caller && regs[6] == e->caller);
            if (!e->returns)
                printf("return AX=%llx SP=%llx IP=%llx; entry-SP=%llx saved-caller=%llx\n",
                       (unsigned long long)regs[0], (unsigned long long)regs[5],
                       (unsigned long long)regs[6], (unsigned long long)e->entry_sp,
                       (unsigned long long)e->caller);
            ++e->returns;
        }
    }
    return (struct xrt_perf_consumed){.bytes=used};
}
struct worker_open {
    const struct xrt_target *remote_target;
    const struct xrt_function_scope *scope;
    const struct xrt_function_config *config;
    const struct xrt_mapping *mapping;
    const char *helper;
    struct xrt_functions *result;
    struct xrt_perf_failure failure;
    atomic_bool done;
};
static void *worker_open(void *raw)
{
    struct worker_open *work = raw;
    work->result = xrt_functions_start_scoped(work->remote_target,work->scope,work->config,
                                              work->mapping,work->helper,&work->failure);
    atomic_store_explicit(&work->done,true,memory_order_release);
    return NULL;
}
static void run(const char *self, const char *helper, const char *agent, bool stacks)
{
    const size_t before = descriptors();
    struct xrt_target *t;
    if (agent) {
        const char *transport[] = {agent,"--stdio",NULL};
        OK(xrt_target_remote(transport,&t));
    } else {
        t = xrt_target_create();
        assert(t);
    }
    const char *args[] = {self,"--fixture",NULL};
    OK(xrt_target_launch(t,args));
    struct xrt_target_view v = view(t);
    assert(v.state == XRT_STOPPED && v.thread_count == 1);
    struct xrt_mapping m = mapping(t,self);
    struct xrt_file_request request = {.kind=XRT_FILE_MAPPED,.mapping=m};
    int fd;
    struct xrt_file_identity identity;
    OK(xrt_target_file_open(t,&request,&fd,&identity));
    struct xrt_function_source source = {.id=91,.fd=fd,
        .offset=(uintptr_t)observed-m.start+m.offset,.identity=identity};
    struct xrt_function_config c = {.pid=v.pid,.tids=&v.pid,.thread_count=1,
        .sources=&source,.source_count=1,.callstacks=stacks};
    struct xrt_perf_failure f = {0};
    c.cancelled=cancelled;
    assert(!xrt_functions_start_target(t,&c,&m,helper,&f) && f.error==ECANCELED);
    assert(f.syscall && !strstr(f.syscall,"allocations") && f.detail && !strstr(f.detail,"allocation "));
    c.cancelled=NULL;
    struct xrt_mapping wrong=m; ++wrong.start;
    assert(!xrt_functions_start_target(t,&c,&wrong,helper,&f));
    const uint64_t good=source.offset;
    source.offset=UINT64_MAX;
    assert(!xrt_functions_start_target(t,&c,&m,helper,&f));
    source.offset=good;
    uint64_t breakpoint = 0;
    OK(xrt_target_breakpoint_set(t,(uintptr_t)observed,false,&breakpoint));
    assert(!xrt_functions_start_target(t,&c,&m,helper,&f) && f.error==EBUSY);
    assert(f.syscall && !strcmp(f.syscall,agent ? "remote perf" : "functions.breakpoint"));
    struct xrt_function_scope scope;
    assert(xrt_functions_capture_scope(t,c.tids,c.thread_count,&scope,&f));
    assert(scope.pid==c.pid && scope.file_pid==c.tids[0] && scope.thread_count==1);
    assert(scope.breakpoint_count==1 && scope.breakpoint_addresses[0]==(uintptr_t)observed);
    OK(xrt_target_breakpoint_remove(t,breakpoint));
    if (!agent) {
        /* Setup consumes the captured value, never a freshly read target view. */
        assert(!xrt_functions_start_scoped(NULL,&scope,&c,&m,helper,&f) && f.error==EBUSY);
    }
    assert(xrt_functions_capture_scope(t,c.tids,c.thread_count,&scope,&f));
    assert(scope.breakpoint_count==0);
    struct worker_open work = {.remote_target=agent?t:NULL,.scope=&scope,.config=&c,
                                .mapping=&m,.helper=helper};
    atomic_init(&work.done,false);
    pthread_t worker;
    assert(!pthread_create(&worker,NULL,worker_open,&work));
    const uint64_t opened_deadline=xrt_now()+UINT64_C(10000000000);
    while (!atomic_load_explicit(&work.done,memory_order_acquire)) {
        assert(xrt_now()<opened_deadline);
        OK(xrt_target_poll(t));
        assert(view(t).state==XRT_STOPPED);
        usleep(1000);
    }
    assert(!pthread_join(worker,NULL));
    struct xrt_functions *owner=work.result;
    f=work.failure;
    if (!owner) {
        fprintf(stderr,"function start: %s errno=%d detail=%s\n",f.syscall,f.error,f.detail);
        abort();
    }
    close(fd);
    struct xrt_perf *perf=xrt_functions_perf(owner);
    struct xrt_perf_info info;
    xrt_perf_info(perf,&info);
    assert(info.threads==1 && !info.running);
    assert(xrt_functions_enable(owner,&f));
    OK(xrt_target_continue(t));
    struct evidence evidence={.pid=v.pid,.stacks=stacks};
    const uint64_t deadline=xrt_now()+UINT64_C(10000000000);
    do {
        assert(xrt_now()<deadline);
        OK(xrt_target_poll(t));
        enum xrt_perf_drain_status status=xrt_perf_drain(perf,decode,&evidence);
        assert(status==XRT_PERF_DRAIN_OK || status==XRT_PERF_DRAIN_CAPACITY);
        usleep(1000);
    } while(view(t).state!=XRT_EXITED);
    assert(xrt_perf_stop(perf,&f));
    assert(xrt_perf_drain(perf,decode,&evidence)==XRT_PERF_DRAIN_OK);
    assert(evidence.entries==8 && evidence.returns==8);
    xrt_functions_destroy(owner);
    OK(xrt_target_destroy(t));
    assert(descriptors()==before);
    printf("function probes passed: %s, stacks=%d, entries=%u returns=%u metadata=%u; no FD leak\n",
           agent?"agent":"native",stacks,evidence.entries,evidence.returns,evidence.metadata);
}
static void components(void)
{
#if defined(__x86_64__)
    uint64_t mask=(UINT64_C(1)<<PERF_REG_X86_AX)|(UINT64_C(1)<<PERF_REG_X86_CX)|
        (UINT64_C(1)<<PERF_REG_X86_DX)|(UINT64_C(1)<<PERF_REG_X86_SI)|
        (UINT64_C(1)<<PERF_REG_X86_DI)|(UINT64_C(1)<<PERF_REG_X86_SP)|
        (UINT64_C(1)<<PERF_REG_X86_IP)|(UINT64_C(1)<<PERF_REG_X86_R8)|
        (UINT64_C(1)<<PERF_REG_X86_R9);
    assert(mask==XRT_FUNCTION_REGISTER_MASK && __builtin_popcountll(mask)==9);
#endif
    struct xrt_perf_failure failure;
    assert(!xrt_functions_start_target(NULL,NULL,NULL,NULL,&failure));
    assert(failure.error==EINVAL);
    struct xrt_target *t=xrt_target_create(); assert(t);
    struct xrt_agent_perf *a=xrt_agent_perf_create(); assert(a);
    uint64_t args[3]={0},value;
    unsigned char bytes[128]={0}, out[65536];
    for(size_t n=0;n<sizeof(bytes);++n) {
        size_t size=sizeof(out);
        enum xrt_status status=xrt_agent_perf_dispatch(a,t,XRT_RPC_FUNCTION_START,args,
                                                       bytes,n,&value,out,&size);
        assert(status==XRT_OK && size>0 && out[0]==0);
    }
    xrt_agent_perf_destroy(a);
    OK(xrt_target_destroy(t));
    xrt_functions_destroy(NULL);
    puts("function probes component/config/malformed-start checks passed");
}
int main(int argc,char **argv)
{
    if(argc==2 && !strcmp(argv[1],"--fixture")) return fixture();
    components();
    if(argc==1) return 0;
    assert(argc==2 || argc==3);
    char *self=realpath(argv[0],NULL); assert(self);
    run(self,argv[1],argc==3?argv[2]:NULL,false);
    run(self,argv[1],argc==3?argv[2]:NULL,true);
    free(self);
    return 0;
}
