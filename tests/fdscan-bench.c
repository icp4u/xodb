/* Owned mixed-descriptor scanner benchmark. Performance evidence, not a gate.
 * Usage: fdscan-bench WORKDIR exact|adaptive|quiet|focused 1000 10000 90000
 * The fixture reports ready before measuring. CPU/load and each sample are
 * emitted so busy-host results need not be mistaken for a regression. */
#define _GNU_SOURCE 1
#include "../src/runtime/xrt_fdscan.h"
#include <assert.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
static void fixture(unsigned n, int ready, const char *directory)
{
    char path[1024];
    for (unsigned made=0;made<n;) {
        unsigned kind=made%10; int pair[2],fd;
        if(kind<4) {
            snprintf(path,sizeof path,"%s/file-%u",directory,made%8);
            fd=open(path,O_CREAT|O_RDWR,0644);assert(fd>=0);++made;
        } else if(kind==4) {assert(open(directory,O_RDONLY|O_DIRECTORY)>=0);++made;}
        else if(kind<7) {assert(pipe(pair)==0);made+=2;}
        else if(kind<9) {assert(socketpair(AF_UNIX,SOCK_STREAM,0,pair)==0);made+=2;}
        else {assert(eventfd(0,0)>=0);++made;}
    }
    assert(write(ready,"r",1)==1);
    char tick;
    while(read(ready,&tick,1)==1) assert(write(ready,"r",1)==1);
}
int main(int argc,char **argv)
{
    assert(argc>=4);setvbuf(stdout,NULL,_IOLBF,0);
    struct rlimit limit;assert(getrlimit(RLIMIT_NOFILE,&limit)==0);
    limit.rlim_cur=limit.rlim_max;assert(setrlimit(RLIMIT_NOFILE,&limit)==0);
    unsigned adaptive=strcmp(argv[2],"exact")!=0;
    int quiet=!strcmp(argv[2],"quiet"), focused=!strcmp(argv[2],"focused");
    for(int arg=3;arg<argc;++arg) {
        unsigned n=(unsigned)strtoul(argv[arg],NULL,10);assert(n>=100 && n+64<limit.rlim_cur);
        int ready[2];assert(socketpair(AF_UNIX,SOCK_STREAM,0,ready)==0);pid_t pid=fork();assert(pid>=0);
        if(!pid){close(ready[0]);fixture(n,ready[1],argv[1]);_exit(0);}
        close(ready[1]);char byte;assert(read(ready[0],&byte,1)==1);
        int32_t target=pid;struct xrt_fdscan_options options={.pids=&target,.pid_count=1};
#ifdef XRT_FD_INFO_STALE
        options.adaptive=(int)adaptive;
#else
        assert(!adaptive);
#endif
        struct xrt_fdscan *scan=NULL;assert(xrt_fdscan_create(&options,&scan)==XRT_OK);
#ifdef XRT_FD_INFO_STALE
        if(focused) assert(xrt_fdscan_interest(scan,&target,1,0)==XRT_OK);
#else
        (void)focused;
#endif
        for(unsigned sample=0;sample<10;++sample) {
            if(!quiet){assert(write(ready[0],"t",1)==1);assert(read(ready[0],&byte,1)==1);}
            double load[3]={0};assert(getloadavg(load,3)==3);
            struct xrt_fd_snapshot view;assert(xrt_fdscan_poll(scan,&view)==XRT_OK);
            assert(view.process_count==1 && view.processes[0].pid==pid && view.fd_count>=n);
            printf("{\"requested_fds\":%u,\"fds\":%u,\"sample\":%u,\"adaptive\":%u,\"stale\":%u,\"wall_ns\":%llu,\"cpu_ns\":%llu,\"load\":%.2f,\"cpus\":%ld}\n",n,view.fd_count,sample,adaptive,view.stale,(unsigned long long)view.scan_ns,(unsigned long long)view.scan_cpu_ns,load[0],sysconf(_SC_NPROCESSORS_ONLN));
        }
        xrt_fdscan_destroy(scan);close(ready[0]);assert(kill(pid,SIGKILL)==0);assert(waitpid(pid,NULL,0)==pid);
    }
    for(unsigned i=0;i<8;++i){char path[1024];snprintf(path,sizeof path,"%s/file-%u",argv[1],i);unlink(path);}
    return 0;
}
