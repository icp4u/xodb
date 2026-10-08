#define _GNU_SOURCE 1
#include "xrt_remote.h"
#include "xrt_source.h"
#include "source_budget.h"
#include "remote_internal.h"
#include <time.h>
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
static void check(enum xrt_status status)
{
    if (status != XRT_OK) { fprintf(stderr,"source runtime status: %d\n",status); abort(); }
}
int main(int argc, char **argv)
{
    struct xrt_source_budget rate = {0};
    for (unsigned i=0; i<XRT_SOURCE_REQUESTS; ++i) assert(xrt_source_budget_take(&rate,10));
    assert(!xrt_source_budget_take(&rate,10));
    assert(!xrt_source_budget_take(&rate,10+XRT_SOURCE_WINDOW_NS-1));
    assert(xrt_source_budget_take(&rate,10+XRT_SOURCE_WINDOW_NS));
    assert(rate.requests==1);
    assert(argc==4 || (argc==3 && !strcmp(argv[2],"old-agent")));
    setvbuf(stdout,NULL,_IONBF,0);
    struct xrt_target *t=NULL;
    const char *agent[]={argv[1],"--stdio",NULL};
    check(xrt_target_remote(agent,&t));
    if (argc==3) {
        assert(!xrt_target_source_capable(t));
        struct xrt_source_file old;
        struct xrt_file_request request={.kind=XRT_FILE_MAPPED};
        assert(xrt_source_open(t,&request,"/synthetic/source.c",&old)==XRT_FILE_UNAVAILABLE && old.reason==XRT_SOURCE_AGENT_UPDATE);
        check(xrt_target_destroy(t));
        puts("pass: old agent remains usable and source fetch requests an update");
        return 0;
    }
    assert(xrt_target_source_capable(t));
    const char *child[]={argv[2],NULL}; check(xrt_target_launch(t,child));
    int maps=-1;
    check(xrt_target_file(t,&(struct xrt_file_request){.kind=XRT_FILE_MAPS},&maps));
    FILE *f=fdopen(maps,"r"); assert(f);
    char line[16384], image[8192]={0};
    struct xrt_file_request request={.kind=XRT_FILE_MAPPED};
    while (fgets(line,sizeof line,f)) {
        unsigned long long start,end,offset,ino; unsigned ma,mi; char mode[5],path[8192];
        if (sscanf(line,"%llx-%llx %4s %llx %x:%x %llu %8191[^\n]",&start,&end,mode,&offset,&ma,&mi,&ino,path)!=8 || strcmp(path,argv[2])) continue;
        strcpy(image,path);
        request.mapping=(struct xrt_mapping){start,end,offset,ma,mi,ino,image}; break;
    }
    fclose(f); assert(image[0]);
    int original=open(argv[3],O_RDONLY|O_CLOEXEC); assert(original>=0);
    char bytes[XRT_SOURCE_MAX]; ssize_t count=read(original,bytes,sizeof bytes); assert(count>0); close(original);
    struct xrt_source_file meta;
    check(xrt_source_open(t,&request,argv[3],&meta));
    assert(meta.reason==XRT_SOURCE_READY && meta.identity.size==count && meta.build_id_size);
    char *got=malloc((size_t)count); assert(got);
    check(xrt_source_read(t,&meta,0,got,(size_t)count)); assert(!memcmp(got,bytes,(size_t)count));
    check(xrt_source_read(t,&meta,(uint64_t)count,NULL,0));
    assert(xrt_source_read(t,&meta,(uint64_t)count,got,1)==XRT_INVALID_ARGUMENT);
    size_t returned = 0;
    assert(xrt_remote_call(t,&(struct xrt_call){.op=XRT_RPC_FILE_READ,
        .args={meta.handle,(uint64_t)count,1},.out=got,.capacity=1,.length=&returned})==XRT_INVALID_ARGUMENT && !returned);
    assert(xrt_remote_call(t,&(struct xrt_call){.op=XRT_RPC_FILE_READ,
        .args={meta.handle,0,(uint64_t)count+1},.out=bytes,.capacity=sizeof bytes,.length=&returned})==XRT_INVALID_ARGUMENT && !returned);
    check(xrt_source_close(t,&meta)); free(got);
    puts("pass: verified source metadata and exact transfer");
    char unrelated[8192]; assert(snprintf(unrelated,sizeof unrelated,"%s.unrelated",argv[3])<(int)sizeof unrelated);
    assert(xrt_source_open(t,&request,unrelated,&meta)==XRT_FILE_UNAVAILABLE && meta.reason==XRT_SOURCE_NOT_LISTED);
    request.mapping.inode++;
    assert(xrt_source_open(t,&request,argv[3],&meta)!=XRT_OK && meta.reason==XRT_SOURCE_DEBUG_UNAVAILABLE);
    request.mapping.inode--;
    puts("pass: unrelated source and forged mapping refused");
    check(xrt_source_open(t,&request,argv[3],&meta));
    int edit=open(argv[3],O_WRONLY|O_CLOEXEC); assert(edit>=0); assert(!ftruncate(edit,0));
    assert(xrt_source_read(t,&meta,0,bytes,1)==XRT_FILE_CHANGED);
    assert(xrt_source_close(t,&meta)==XRT_FILE_CHANGED);
    assert(!ftruncate(edit,XRT_SOURCE_MAX+1));
    assert(xrt_source_open(t,&request,argv[3],&meta)==XRT_FILE_LIMIT && meta.reason==XRT_SOURCE_TOO_LARGE);
    assert(!ftruncate(edit,0)); assert(write(edit,bytes,(size_t)count)==count); close(edit);
    puts("pass: mutation and source size cap");
    char backup[8192]; assert(snprintf(backup,sizeof backup,"%s.saved",argv[3])<(int)sizeof backup);
    assert(!rename(argv[3],backup)); assert(!mkfifo(argv[3],0600));
    assert(xrt_source_open(t,&request,argv[3],&meta)==XRT_FILE_UNAVAILABLE && meta.reason==XRT_SOURCE_UNAVAILABLE);
    assert(!unlink(argv[3])); assert(!rename(backup,argv[3]));
    puts("pass: named FIFO refused without blocking");
    check(xrt_source_open(t,&request,argv[3],&meta)); check(xrt_source_close(t,&meta));
    unsigned successes=0, refusals=0;
    while (successes < XRT_SOURCE_REQUESTS+16) {
        enum xrt_status s=xrt_source_open(t,&request,argv[3],&meta);
        if (meta.reason==XRT_SOURCE_COUNT_LIMIT) {
            assert(s==XRT_FILE_LIMIT && ++refusals<=4);
            struct timespec pause={.tv_sec=1,.tv_nsec=10000000}; nanosleep(&pause,NULL);
            continue;
        }
        check(s); check(xrt_source_close(t,&meta)); ++successes;
    }
    puts("pass: deterministic window limit and more than 1024 live authorizations with expiry recovery");
    check(xrt_target_destroy(t)); return 0;
}
