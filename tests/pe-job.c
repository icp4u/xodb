/* Fast component lane. Real owned file/mapping identity, no target execution. */
#define _GNU_SOURCE 1
#include "../src/binary/pe_job.h"
#include "../src/runtime/target_internal.h"
#include "check.h"
#include <fcntl.h>
#include <pthread.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <time.h>
static pthread_mutex_t gate = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static int hold, entered, released;
enum xrt_status __real_xrt_file_view_read(struct xrt_file_view *,uint64_t,void *,size_t);
enum xrt_status __wrap_xrt_file_view_read(struct xrt_file_view *view,uint64_t at,void *out,size_t size) {
    CHECK(!pthread_mutex_lock(&gate));
    if (hold) {
        entered=1;CHECK(!pthread_cond_broadcast(&changed));
        while (!released) CHECK(!pthread_cond_wait(&changed,&gate));
        hold=0;
    }
    CHECK(!pthread_mutex_unlock(&gate));
    return __real_xrt_file_view_read(view,at,out,size);
}
static void wait_job(struct xpe_job *job) {
    int joined;
    while ((joined=xpe_job_join(job))==0) {
        struct xpe_job_snapshot snapshot;xpe_job_poll(job,&snapshot);
        const struct timespec pause={.tv_nsec=1000000};nanosleep(&pause,NULL);
    }
    CHECK(joined==1);
}
int main(int argc,char **argv) {
    CHECK(argc==3);
    char *path=realpath(argv[1],NULL);CHECK(path);
    int fd=open(path,O_RDONLY|O_CLOEXEC);CHECK(fd>=0);
    struct stat st;CHECK(!fstat(fd,&st) && st.st_size>0);
    long page=sysconf(_SC_PAGESIZE);CHECK(page>0);
    size_t mapped=((size_t)st.st_size+(size_t)page-1)/(size_t)page*(size_t)page;
    void *bytes=mmap(NULL,mapped,PROT_READ,MAP_PRIVATE,fd,0);CHECK(bytes!=MAP_FAILED);
    struct xrt_target target={.pid=getpid()};
    const struct xrt_file_request request={.kind=XRT_FILE_MAPPED,.mapping={
        .start=(uintptr_t)bytes,.end=(uintptr_t)bytes+mapped,.offset=0,
        .device_major=major(st.st_dev),.device_minor=minor(st.st_dev),.inode=st.st_ino,.path=path}};
    struct xrt_file_view *view=NULL;CHECK(xrt_target_file_view_open(&target,&request,&view)==XRT_OK);
    hold=!strcmp(argv[2],"barrier");
    struct xpe_job *job=NULL;CHECK(xpe_job_start(view,&job)==XPE_OK);
    if (hold) {
        CHECK(!pthread_mutex_lock(&gate));
        while (!entered) CHECK(!pthread_cond_wait(&changed,&gate));
        struct xpe_job_snapshot snapshot;xpe_job_poll(job,&snapshot);
        CHECK(snapshot.state==XPE_JOB_PENDING && snapshot.source_reads==0);
        CHECK(xpe_job_join(job)==0);
        xpe_job_cancel(job);xpe_job_poll(job,&snapshot);
        CHECK(snapshot.state==XPE_JOB_FAILED && snapshot.status==XPE_CANCELLED);
        CHECK(xpe_job_join(job)==0); /* Cancellation cannot release a borrowed target. */
        released=1;CHECK(!pthread_cond_broadcast(&changed));CHECK(!pthread_mutex_unlock(&gate));
    }
    if (!strcmp(argv[2],"cancel") || !strcmp(argv[2],"barrier")) {
        xpe_job_cancel(job);struct xpe_job_snapshot snapshot;xpe_job_poll(job,&snapshot);
        CHECK(snapshot.state==XPE_JOB_FAILED && snapshot.status==XPE_CANCELLED);
        wait_job(job);CHECK(!xpe_job_image(job) && xpe_job_validate(job)==XPE_CANCELLED);
    } else {
        wait_job(job);struct xpe_job_snapshot snapshot;xpe_job_poll(job,&snapshot);
        CHECK(snapshot.state==XPE_JOB_READY && snapshot.status==XPE_OK);
        struct xpe_image *image=xpe_job_image(job);CHECK(image);
        const struct xpe_export *symbol=xpe_find_export(image,"pe_inner");
        CHECK(symbol && symbol->ordinal==(!strcmp(argv[2],"wrong-result")?8u:7u));
        CHECK(xpe_job_validate(job)==XPE_OK);
        unsigned char mz[2];CHECK(xpe_read_rva(image,0,mz,2)==XPE_OK && mz[0]=='M' && mz[1]=='Z');
        CHECK(snapshot.source_bytes && snapshot.source_reads);
        if (!strcmp(argv[2],"mutation")) {
            struct timespec times[]={st.st_atim,st.st_mtim};++times[1].tv_sec;CHECK(!futimens(fd,times));
            CHECK(xpe_job_validate(job)==XPE_CHANGED && !xpe_job_image(job));
            times[1]=st.st_mtim;CHECK(!futimens(fd,times));
            CHECK(xpe_job_validate(job)==XPE_CHANGED && !xpe_job_image(job));
        }
    }
    xpe_job_destroy(job);CHECK(!munmap(bytes,mapped));CHECK(!close(fd));free(path);
    puts("PE job: pinned mapping, parsed export, publication, cancellation/identity checks passed");
    return 0;
}
