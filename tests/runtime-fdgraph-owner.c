#define _GNU_SOURCE 1
#include "xrt_fdactivity.h"
#include "check.h"
#include <errno.h>
#include <stdatomic.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
/* Starting a graph publication must not itself enable tracing. UI activation
 * will be a separate explicit demand. Every target below is owned. */
enum xrt_status xrt_fdevent_open(const struct xrt_fdevent_options *o,struct xrt_fdevent **p,struct xrt_perf_failure *f)
{(void)o;(void)p;(void)f;CHECK(0);return XRT_INVALID_STATE;}
void xrt_fdevent_stop(struct xrt_fdevent *p) {(void)p;CHECK(0);}
void xrt_fdevent_close(struct xrt_fdevent *p) {CHECK(!p);}
enum xrt_status xrt_fdevent_drain(struct xrt_fdevent *p,struct xrt_fdevent_snapshot *s)
{(void)p;(void)s;CHECK(0);return XRT_INVALID_STATE;}
static _Atomic int freed;
static void *owned;
static void owned_free(void *p) {int done=p==owned;free(p);if (done) atomic_store(&freed,1);}
static uint64_t batch_deadline;
static unsigned batch_calls;
static int mock_batch;
static enum xrt_status checked_peers(uint32_t inode,uint32_t capacity,uint64_t deadline,struct xrt_unix_peers *out)
{
    if (!mock_batch) return xrt_unix_peers_read_until(inode,capacity,deadline,out);
    CHECK(deadline && capacity==1);
    if (!batch_calls++) {
        batch_deadline=deadline;
        out->rows=calloc(1,sizeof *out->rows);CHECK(out->rows);
        out->rows[0].inode=inode;out->count=out->capacity=1;out->complete=1;
        return XRT_OK;
    }
    CHECK(deadline==batch_deadline);
    /* Exercise the real expired-budget path without issuing a kernel query. */
    return xrt_unix_peers_read_until(inode,capacity,1,out);
}
#define xrt_unix_peers_read_until checked_peers
#define free owned_free
#include "../src/runtime/fdactivity.c"
#undef free
#undef xrt_unix_peers_read_until
static void peer_batch(int wrong)
{
    struct xrt_fd_process p={.pid=10,.start=1,.count=3};
    struct xrt_fd f[3]={
        {.kind=XRT_FD_SOCKET,.inode=10,.flags=XRT_FD_STAT},
        {.kind=XRT_FD_SOCKET,.inode=11,.flags=XRT_FD_STAT},
        {.kind=XRT_FD_SOCKET,.inode=12,.flags=XRT_FD_STAT}};
    struct xrt_fd_snapshot snapshot={.processes=&p,.process_count=1,.fds=f,.fd_count=3};
    struct xrt_unix_peers out={0};mock_batch=1;
    CHECK(scoped_peers(&snapshot,&out)==XRT_FILE_UNAVAILABLE);
    CHECK(out.error==ETIMEDOUT && !out.count && !out.complete && out.taken_ns);
    CHECK(batch_calls==(unsigned)(wrong ? 3 : 2)); /* Partial evidence must be withdrawn. */
    xrt_unix_peers_free(&out);mock_batch=0;
}
static uint64_t seconds(void) {struct timespec t;CHECK(!clock_gettime(CLOCK_MONOTONIC,&t));return (uint64_t)t.tv_sec;}
static uint64_t rss(void)
{
    FILE *f=fopen("/proc/self/statm","r");CHECK(f);unsigned long pages,resident;
    CHECK(fscanf(f,"%lu %lu",&pages,&resident)==2);CHECK(!fclose(f));
    return (uint64_t)resident*(uint64_t)sysconf(_SC_PAGESIZE);
}
static int accounted_read(pid_t pid)
{
    char path[64],text[512];snprintf(path,sizeof path,"/proc/%d/io",(int)pid);
    FILE *f=fopen(path,"r");CHECK(f);size_t got=fread(text,1,sizeof text-1,f);CHECK(!fclose(f));text[got]=0;
    const char *at=strstr(text,"rchar:");CHECK(at);return strtoull(at+6,NULL,10)!=0;
}
int main(int argc,char **argv)
{
    peer_batch(argc==2 && !strcmp(argv[1],"--wrong-batch"));
    if (argc==2 && !strcmp(argv[1],"--batch-only")) return 0;
    int wrong=argc==2 && !strcmp(argv[1],"--wrong-oracle");
    int quiet=argc==2 && !strcmp(argv[1],"--quiet-demand"),saw_quiet=0;
    /* Planted control: one byte read by the child between two samples must
     * abort at the idle-rate check below. */
    int late=argc==2 && !strcmp(argv[1],"--late-io");
    uint32_t interval=quiet || (argc==2 && !strcmp(argv[1],"--fast")) ? 250 : 1000;
    uint64_t rss_before=rss(),cpu_before=now_ns(CLOCK_PROCESS_CPUTIME_ID),wall_before=now_ns(CLOCK_MONOTONIC);
    uint64_t rss_after=0,cpu_after=0,wall_after=0,owner_cpu=0,graph_bytes=0;
    int pair[2],control[2],ready[2];CHECK(!socketpair(AF_UNIX,SOCK_STREAM|SOCK_CLOEXEC,0,pair));CHECK(!pipe(control) && !pipe(ready));
    pid_t child=fork();CHECK(child>=0);
    /* The child settles its descriptor table before the first sample, so the
     * idle-rate checks below cannot see its own startup close as churn. Its
     * ready signal is the last close itself, seen here as end of file: the
     * kernel drops the table entry before it releases the pipe, and a close
     * moves no bytes. A ready byte would not do. The parent can read it
     * before the kernel has added it to the child's /proc/PID/io wchar, so
     * that byte could land between the first two samples as a write rate. */
    if (!child) {
        close(control[1]);close(ready[0]);close(ready[1]);char ch;
        if (late && read(pair[1],&ch,1)!=1) _exit(1);
        ssize_t n=read(control[0],&ch,1);_exit(n==1 ? 0 : 1);
    }
    close(control[0]);close(ready[1]);int32_t pid=child;{char end;CHECK(read(ready[0],&end,1)==0);}
    close(ready[0]);
    struct xrt_fdactivity_options options={.pids=&pid,.pid_count=1};struct xrt_fdactivity *owner=NULL;
    CHECK(xrt_fdactivity_create_scoped(&options,&owner)==XRT_OK);owned=owner;
    struct xrt_fdactivity_request request={.interval_ms=interval,.graph=1,.poll_all=!quiet};
    uint64_t deadline=seconds()+15;int found=0;uint64_t first_sequence=0,quiet_sequence=0;
    do {
        enum xrt_status status=xrt_fdactivity_request(owner,&request);CHECK(status==XRT_OK || status==XRT_STALE_SNAPSHOT);
        struct xrt_fdactivity_view view;
        if (xrt_fdactivity_acquire(owner,&view)) {
            if (view.graph) {
                CHECK(view.poll && view.poll->process_count==1 && view.poll->processes[0].pid==child);
                CHECK(view.graph_status==XRT_OK && view.peer_status==XRT_OK);
                CHECK(view.graph->sequence==view.poll->sequence);
                const struct xrt_fd_process *process=&view.poll->processes[0];
                int is_quiet=!!(process->flags&XRT_FDP_QUIET);
                CHECK(view.graph->peer_edges==(is_quiet ? 0u : 1u));
                CHECK(view.graph->processes==1 && !view.event_requested && !view.event.running);
                owner_cpu=view.owner_cpu_ns;graph_bytes=view.graph->allocated_bytes;
                struct xrt_fdgraph *copy=xrt_fdgraph_copy(view.graph);CHECK(copy && copy->peer_edges==view.graph->peer_edges);
                xrt_fdgraph_free(copy);
                if (!first_sequence) {
                    first_sequence=view.poll->sequence;
                    /* Publication is held by this view; the next sample is a
                     * whole interval away. */
                    if (late) {
                        CHECK(write(pair[0],"w",1)==1);
                        while (!accounted_read(child)) {CHECK(seconds()<deadline);struct timespec wait={0,1000000};nanosleep(&wait,NULL);}
                    }
                }
                if (quiet && is_quiet && !saw_quiet) {
                    /* This is the actual quiet-cache condition behind the
                     * cards' missing rate interval, not an invented row. */
                    CHECK(process->flags&XRT_FDP_STALE);
                    CHECK(!process->interval_ns);
                    saw_quiet=1;quiet_sequence=view.poll->sequence;
                    request.poll_all=1;
                }
                if (view.poll->sequence>first_sequence &&
                    (!quiet || (saw_quiet && view.poll->sequence>quiet_sequence))) {
                    CHECK(!(process->flags&(XRT_FDP_STALE|XRT_FDP_NO_IO)));
                    CHECK(process->interval_ns && !process->read_rate && !process->write_rate && !process->churn_rate);
                    int saw_cached=0;
                    for (uint32_t i=0;i<view.poll->fd_count;++i) {
                        const struct xrt_fd *f=&view.poll->fds[i];
                        if (f->kind==XRT_FD_SOCKET && (f->flags&XRT_FD_STAT_STALE)) {
                            CHECK(xrt_fd_identity_current(view.poll,&view.poll->processes[0],f));saw_cached=1;
                        }
                    }
                    CHECK(saw_cached);found=1;
                }
            }
            xrt_fdactivity_release(owner);
        }
        if (!found) {struct timespec wait={0,1000000};nanosleep(&wait,NULL);}
    } while (!found && seconds()<deadline);
    rss_after=rss();cpu_after=now_ns(CLOCK_PROCESS_CPUTIME_ID);wall_after=now_ns(CLOCK_MONOTONIC);
    xrt_fdactivity_destroy(owner);
    while (!atomic_load(&freed) && seconds()<deadline) {struct timespec wait={0,1000000};nanosleep(&wait,NULL);}
    CHECK(write(control[1],"q",1)==1);close(control[1]);int status;CHECK(waitpid(child,&status,0)==child && WIFEXITED(status) && !WEXITSTATUS(status));
    close(pair[0]);close(pair[1]);CHECK(found && atomic_load(&freed));
    CHECK(!quiet || saw_quiet);
    CHECK(!wrong);
    printf("{\"interval_ms\":%u,\"rss_before\":%llu,\"rss_after\":%llu,\"cpu_ns\":%llu,\"wall_ns\":%llu,\"owner_cpu_ns\":%llu,\"graph_bytes\":%llu}\n",interval,(unsigned long long)rss_before,(unsigned long long)rss_after,(unsigned long long)(cpu_after-cpu_before),(unsigned long long)(wall_after-wall_before),(unsigned long long)owner_cpu,(unsigned long long)graph_bytes);
    puts("descriptor graph owner: scoped poll, UNIX peers, coherent publication, no implicit capture and cleanup PASS");return 0;
}
