/* Fast lane (<5s): real owned procfs polling, fake capture, exact binding oracle.
 * Treemap flow demand must bind descriptors without building a graph/UNIX_DIAG.
 * CHECK remains active with NDEBUG; --wrong-oracle plants a wrong held fd. */
#define _GNU_SOURCE 1
#include "check.h"
#include "xrt_fdactivity.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>
#include <string.h>
#include <signal.h>
#include <sys/prctl.h>
#include <sys/wait.h>
static _Atomic unsigned binds,freed,enabled,stops;
static int32_t own_pid;
static int held_fd,wrong;
static void *owned;
struct xrt_fdflow_owner { int unused; };
static void owner_free(void *p) {int done=p==owned;free(p);if (done) atomic_store(&freed,1);}
enum xrt_status xrt_fdflow_owner_create(const int32_t *p,uint32_t n,struct xrt_fdflow_owner **out)
{CHECK(n==1 && p[0]==own_pid);*out=calloc(1,sizeof **out);return *out?XRT_OK:XRT_OUT_OF_MEMORY;}
void xrt_fdflow_owner_destroy(struct xrt_fdflow_owner *p) {free(p);}
enum xrt_status xrt_fdflow_owner_request(struct xrt_fdflow_owner *p,int on)
{CHECK(p);atomic_store(&enabled,on);if (!on) atomic_fetch_add(&stops,1);return XRT_OK;}
enum xrt_status xrt_fdflow_owner_bind(struct xrt_fdflow_owner *p,struct xrt_fdflow_bindings *b)
{
    CHECK(p && b);int found=0;
    for (uint32_t i=0;i<b->count;++i) {
        CHECK(b->rows[i].pid==own_pid && b->rows[i].start);
        if (b->rows[i].fd==held_fd+(wrong?10000:0)) found=1;
    }
    xrt_fdflow_bindings_free(b);if (found) atomic_fetch_add(&binds,1);return XRT_OK;
}
int xrt_fdflow_owner_acquire(struct xrt_fdflow_owner *p,struct xrt_fdflow_live *v)
{CHECK(p);memset(v,0,sizeof *v);v->status=XRT_OK;v->requested=atomic_load(&enabled);return 1;}
void xrt_fdflow_owner_release(struct xrt_fdflow_owner *p) {CHECK(p);}
enum xrt_status xrt_fdevent_open(const struct xrt_fdevent_options *o,struct xrt_fdevent **p,struct xrt_perf_failure *f)
{(void)o;(void)p;(void)f;CHECK(0);return XRT_INVALID_STATE;}
void xrt_fdevent_stop(struct xrt_fdevent *p) {(void)p;CHECK(0);}
void xrt_fdevent_close(struct xrt_fdevent *p) {CHECK(!p);}
enum xrt_status xrt_fdevent_drain(struct xrt_fdevent *p,struct xrt_fdevent_snapshot *s)
{(void)p;(void)s;CHECK(0);return XRT_INVALID_STATE;}
#ifndef FDACTIVITY_SOURCE
#define FDACTIVITY_SOURCE "../src/runtime/fdactivity.c"
#endif
#define free owner_free
#include FDACTIVITY_SOURCE
#undef free
static uint64_t clock_ns(void) {struct timespec ts;CHECK(!clock_gettime(CLOCK_MONOTONIC,&ts));return (uint64_t)ts.tv_sec*1000000000u+ts.tv_nsec;}
static void pending(void) {struct timespec ts={0,1000000};nanosleep(&ts,NULL);}
int main(int argc,char **argv)
{
    wrong=argc==2 && !strcmp(argv[1],"--wrong-oracle");int pipefd[2];CHECK(!pipe(pipefd));held_fd=pipefd[0];
    pid_t parent=getpid();own_pid=fork();CHECK(own_pid>=0);
    if (!own_pid) {
        CHECK(!prctl(PR_SET_PDEATHSIG,SIGKILL) && getppid()==parent);
        close(pipefd[1]);char byte;_exit(read(pipefd[0],&byte,1)==1?0:1);
    }
    CHECK(!close(pipefd[0]));
    struct xrt_fdactivity_options o={.pids=&own_pid,.pid_count=1};struct xrt_fdactivity *ctx=NULL;
    CHECK(xrt_fdactivity_create_scoped(&o,&ctx)==XRT_OK);owned=ctx;
    struct xrt_fdactivity_request request={.interval_ms=250,.poll_all=1,.flow=1};
    uint64_t until=clock_ns()+4000000000u;int observed=0;
    do {
        enum xrt_status r=xrt_fdactivity_request(ctx,&request);CHECK(r==XRT_OK || r==XRT_STALE_SNAPSHOT);
        struct xrt_fdactivity_view v;
        if (xrt_fdactivity_acquire(ctx,&v)) {
            CHECK(!v.graph); /* No unrelated topology/UNIX_DIAG work. */
            if (v.poll && v.poll->process_count) {CHECK(v.poll->process_count==1 && v.poll->processes[0].pid==own_pid);observed=atomic_load(&binds)>0;}
            xrt_fdactivity_release(ctx);
        }
        if (!observed) pending();
    } while (!observed && clock_ns()<until);
    int was_enabled=atomic_load(&enabled);until=clock_ns()+4000000000u;
    request.flow=0;request.stop_flow=1;
    do {
        enum xrt_status r=xrt_fdactivity_request(ctx,&request);CHECK(r==XRT_OK || r==XRT_STALE_SNAPSHOT);
        if (r==XRT_OK) break;
        CHECK(clock_ns()<until);pending();
    } while (1);
    CHECK(!atomic_load(&enabled) && atomic_load(&stops));
    xrt_fdactivity_destroy(ctx);
    while (!atomic_load(&freed)) {CHECK(clock_ns()<until);pending();}
    CHECK(write(pipefd[1],"q",1)==1 && !close(pipefd[1]));int status;CHECK(waitpid(own_pid,&status,0)==own_pid && status==0);
    CHECK(observed && was_enabled);
    puts("treemap owner: explicit flow binds owned descriptors without graph demand, stop and cleanup PASS");return 0;
}
