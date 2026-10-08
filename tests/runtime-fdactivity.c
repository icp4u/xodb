/* Real shared polling owner; event-entry stubs abort to prove polling demand
 * cannot start privileged capture. Only the two owned children are asserted. */
#define _GNU_SOURCE 1
#include "xrt_fdactivity.h"
#include <assert.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
enum xrt_status xrt_fdevent_open(const struct xrt_fdevent_options *o,struct xrt_fdevent **p,struct xrt_perf_failure *f)
{ (void)o;(void)p;(void)f;abort(); }
void xrt_fdevent_stop(struct xrt_fdevent *p) { (void)p;abort(); }
void xrt_fdevent_close(struct xrt_fdevent *p) { assert(!p); }
enum xrt_status xrt_fdevent_drain(struct xrt_fdevent *p,struct xrt_fdevent_snapshot *s)
{ (void)p;(void)s;abort(); }
static pid_t children[2];
/* Exercise the production owner against only our two fixtures. Unrelated
 * process count must not turn every budgeted revisit into a periodic full
 * refresh and conceal a broken foreground-demand union. */
static enum xrt_status owned_scanner(const struct xrt_fdscan_options *options,struct xrt_fdscan **out);
#define xrt_fdscan_create owned_scanner
#include "../src/runtime/fdactivity.c"
#undef xrt_fdscan_create
static enum xrt_status owned_scanner(const struct xrt_fdscan_options *options,struct xrt_fdscan **out)
{
    struct xrt_fdscan_options scoped=*options;
    int32_t pids[2]={children[0],children[1]};
    scoped.pids=pids;scoped.pid_count=2;
    return xrt_fdscan_create(&scoped,out);
}
static int held;
static const char *replacement;
static void replace(int sig)
{
    (void)sig;
    int fd=open(replacement,O_RDONLY);
    if(fd<0 || dup2(fd,held)!=held) _exit(3);
    if(fd!=held) close(fd);
}
static void cleanup(void)
{
    for(unsigned i=0;i<2;++i) if(children[i]>0) {
        kill(children[i],SIGKILL);
        while(waitpid(children[i],NULL,0)<0 && errno==EINTR) {}
    }
}
static uint64_t now(void)
{
    struct timespec t;assert(clock_gettime(CLOCK_MONOTONIC,&t)==0);
    return (uint64_t)t.tv_sec*1000000000u+(uint64_t)t.tv_nsec;
}
static int spawn(unsigned index,const char *file)
{
    int ready[2];assert(pipe(ready)==0);
    pid_t parent=getpid();
    children[index]=fork();assert(children[index]>=0);
    if(!children[index]) {
        assert(prctl(PR_SET_PDEATHSIG,SIGKILL)==0);
        if(getppid()!=parent)_exit(0);
        close(ready[0]);held=open(file,O_RDONLY);assert(held>=0);
        struct sigaction a={.sa_handler=replace};sigemptyset(&a.sa_mask);
        assert(sigaction(SIGUSR1,&a,NULL)==0);
        assert(write(ready[1],&held,sizeof held)==sizeof held);close(ready[1]);
        for(;;)pause();
    }
    close(ready[1]);int fd;assert(read(ready[0],&fd,sizeof fd)==sizeof fd);close(ready[0]);return fd;
}
static void request(struct xrt_fdactivity *owner,const struct xrt_fdactivity_request *r)
{
    uint64_t deadline=now()+1000000000u;
    for(;;) {
        enum xrt_status status=xrt_fdactivity_request(owner,r);
        if(status==XRT_OK)return;
        assert(status==XRT_STALE_SNAPSHOT && now()<deadline);usleep(1000);
    }
}
struct observation { struct xrt_fd_process process; struct xrt_fd fd; uint64_t sequence; };
static int observe(struct xrt_fdactivity *owner,unsigned child,int number,struct observation *o)
{
    struct xrt_fdactivity_view view;int found=0;
    if(!xrt_fdactivity_acquire(owner,&view))return 0;
    assert(!view.event.running && !view.event_requested);
    if(view.poll)for(uint32_t i=0;i<view.poll->process_count;++i) {
        const struct xrt_fd_process *p=&view.poll->processes[i];
        if(p->pid!=children[child])continue;
        for(uint32_t j=0;j<p->count;++j) {
            const struct xrt_fd *f=&view.poll->fds[p->first+j];
            if(f->fd==number){o->process=*p;o->fd=*f;o->sequence=view.poll->sequence;found=1;break;}
        }
    }
    xrt_fdactivity_release(owner);return found;
}
int main(void)
{
    if(getenv("XODB_TEST_NO_LIVE")){puts("fdactivity demand: live disabled");return 0;}
    atexit(cleanup);
    const char *base=getenv("TMPDIR");char dir[1024],a[1100],b[1100];
    snprintf(dir,sizeof dir,"%s/fd-demand.XXXXXX",base?base:"/tmp");assert(mkdtemp(dir));assert(chmod(dir,0755)==0);
    snprintf(a,sizeof a,"%s/first",dir);snprintf(b,sizeof b,"%s/second",dir);replacement=b;
    int file=open(a,O_CREAT|O_RDWR,0644);assert(file>=0);close(file);
    file=open(b,O_CREAT|O_RDWR,0644);assert(file>=0);struct stat wanted;assert(fstat(file,&wanted)==0);close(file);
    int numbers[2]={spawn(0,a),spawn(1,a)};
    struct xrt_fdactivity *owner;assert(xrt_fdactivity_create(&owner)==XRT_OK);
    struct xrt_fdactivity_request invalid={.interval_ms=250,.poll_pid_count=1};
    assert(xrt_fdactivity_request(owner,&invalid)==XRT_INVALID_ARGUMENT);
    int32_t copied;
    struct xrt_fdactivity_request focus={.interval_ms=250,.poll_pids=&copied,.poll_pid_count=1};
    struct xrt_fdactivity_request background={.interval_ms=250};
    struct observation o[2];uint64_t deadline=now()+30000000000ull;
    /* Independent callers renew disjoint demands. The copied input may be
     * reused immediately, and neither client replaces the other's interest. */
    for(;;) {
        for(unsigned i=0;i<2;++i){copied=children[i];request(owner,&focus);copied=-1;}
        int good=1;
        for(unsigned i=0;i<2;++i)good &= observe(owner,i,numbers[i],&o[i]) &&
            !(o[i].process.flags & XRT_FDP_STALE) && !(o[i].fd.flags & (XRT_FD_LINK_STALE|XRT_FD_INFO_STALE));
        if(good)break;
        assert(now()<deadline);usleep(10000);
    }
    /* A cold or periodic full scan would make even a broken demand union
     * look fresh once. Keep both demands through later publications: a process
     * the budget has not reached may be stale, but must not use the quiet hint
     * once the owner has received demand. Each fixture must be revisited. */
    uint64_t initial_sequence=o[0].sequence>o[1].sequence?o[0].sequence:o[1].sequence;
    uint64_t initial_sample[2]={o[0].process.sampled_ns,o[1].process.sampled_ns};
    deadline=now()+30000000000ull;
    for(;;) {
        for(unsigned i=0;i<2;++i){copied=children[i];request(owner,&focus);copied=-1;}
        int good=1;
        for(unsigned i=0;i<2;++i) {
            if(!observe(owner,i,numbers[i],&o[i]) || o[i].sequence<=initial_sequence+2){good=0;continue;}
            assert(!(o[i].process.flags & XRT_FDP_QUIET));
            good &= o[i].process.sampled_ns>initial_sample[i] && !(o[i].process.flags & XRT_FDP_STALE);
        }
        if(good)break;
        assert(now()<deadline);usleep(10000);
    }
    /* Keep generic polling alive while foreground demand expires naturally. */
    deadline=now()+30000000000ull;
    for(;;) {
        request(owner,&background);
        if(observe(owner,0,numbers[0],&o[0]) && (o[0].process.flags & XRT_FDP_QUIET))break;
        assert(now()<deadline);usleep(10000);
    }
    assert(o[0].process.flags & XRT_FDP_STALE);
    assert(o[0].fd.flags & XRT_FD_LINK_STALE);
    uint64_t sequence=o[0].sequence;
    /* Signal handler swaps onto the same number without changing /proc/io. */
    assert(kill(children[0],SIGUSR1)==0);
    char link[96];snprintf(link,sizeof link,"/proc/%d/fd/%d",children[0],numbers[0]);
    deadline=now()+30000000000ull;
    struct stat actual;
    while(stat(link,&actual) || actual.st_ino!=wanted.st_ino){assert(now()<deadline);usleep(1000);}
    for(;;) {
        request(owner,&background);
        if(observe(owner,0,numbers[0],&o[0]) && o[0].sequence>sequence)break;
        assert(now()<deadline);usleep(10000);
    }
    /* A periodic refresh may already have found the change. Otherwise the
     * old inode MUST be labelled stale; it is never a fresh identity claim. */
    if(o[0].fd.inode!=(uint64_t)wanted.st_ino)
        assert((o[0].process.flags & XRT_FDP_STALE) && (o[0].fd.flags & XRT_FD_STAT_STALE));
    deadline=now()+30000000000ull;
    for(;;) {
        copied=children[0];request(owner,&focus);copied=-1;
        if(observe(owner,0,numbers[0],&o[0]) && o[0].fd.inode==(uint64_t)wanted.st_ino &&
           !(o[0].process.flags & XRT_FDP_STALE) && !(o[0].fd.flags & (XRT_FD_LINK_STALE|XRT_FD_INFO_STALE)))break;
        assert(now()<deadline);usleep(10000);
    }
    xrt_fdactivity_destroy(owner);
    /* The public destructor is asynchronous. Wait only for this test's one
     * owner thread to leave before returning through the sanitizer runtime. */
    deadline=now()+30000000000ull;
    for(;;) {
        DIR *tasks=opendir("/proc/self/task");assert(tasks);unsigned count=0;
        for(struct dirent *e;(e=readdir(tasks));) if(e->d_name[0]!='.')++count;
        closedir(tasks);if(count==1)break;
        assert(now()<deadline);usleep(1000);
    }
    cleanup();children[0]=children[1]=0;
    unlink(a);unlink(b);rmdir(dir);
    puts("fdactivity demand: copied/merged scopes, expiry, same-count replacement freshness and no event capture passed");
    return 0;
}
