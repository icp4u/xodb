#define _GNU_SOURCE 1
#include "xrt_fdactivity.h"
#include "check.h"
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
#define free owned_free
#include "../src/runtime/fdactivity.c"
#undef free
static uint64_t seconds(void) {struct timespec t;CHECK(!clock_gettime(CLOCK_MONOTONIC,&t));return (uint64_t)t.tv_sec;}
static uint64_t rss(void)
{
    FILE *f=fopen("/proc/self/statm","r");CHECK(f);unsigned long pages,resident;
    CHECK(fscanf(f,"%lu %lu",&pages,&resident)==2);CHECK(!fclose(f));
    return (uint64_t)resident*(uint64_t)sysconf(_SC_PAGESIZE);
}
int main(int argc,char **argv)
{
    int wrong=argc==2 && !strcmp(argv[1],"--wrong-oracle");
    int quiet=argc==2 && !strcmp(argv[1],"--quiet-demand"),saw_quiet=0;
    uint32_t interval=quiet || (argc==2 && !strcmp(argv[1],"--fast")) ? 250 : 1000;
    uint64_t rss_before=rss(),cpu_before=now_ns(CLOCK_PROCESS_CPUTIME_ID),wall_before=now_ns(CLOCK_MONOTONIC);
    uint64_t rss_after=0,cpu_after=0,wall_after=0,owner_cpu=0,graph_bytes=0;
    int pair[2],control[2];CHECK(!socketpair(AF_UNIX,SOCK_STREAM|SOCK_CLOEXEC,0,pair));CHECK(!pipe(control));
    pid_t child=fork();CHECK(child>=0);
    if (!child) {close(control[1]);char ch;ssize_t n=read(control[0],&ch,1);_exit(n==1 ? 0 : 1);}
    close(control[0]);int32_t pid=child;
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
                if (!first_sequence) first_sequence=view.poll->sequence;
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
