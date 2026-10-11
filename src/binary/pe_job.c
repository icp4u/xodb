#define _GNU_SOURCE 1
#include "pe_job.h"
#include <errno.h>
#include <fcntl.h>
#include <linux/openat2.h>
#include <linux/magic.h>
#include <pthread.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <time.h>

struct xpe_job {
    pthread_t thread;
    pthread_mutex_t mutex;
    struct xrt_file_view *view;
    struct xpe_image *image;
    struct xpe_job_snapshot snapshot;
    unsigned cancel;
    unsigned released;
    int joined;
    uint64_t deadline, allowance;
    unsigned budget_exhausted;
    int root_fd, pdb_fd;
    char *mapped_path;
    struct xpdb *pdb;
    struct xrt_file_identity pdb_identity;
    const char *pdb_status;
};
static uint64_t now(void) {
    struct timespec stamp;
    if (clock_gettime(CLOCK_MONOTONIC, &stamp)) return UINT64_MAX;
    return (uint64_t)stamp.tv_sec * UINT64_C(1000000000) + (uint64_t)stamp.tv_nsec;
}
static enum xpe_status converted(enum xrt_status status) {
    if (status == XRT_OK) return XPE_OK;
    if (status == XRT_FILE_CHANGED) return XPE_CHANGED;
    if (status == XRT_DISCOVERY_CANCELLED) return XPE_CANCELLED;
    if (status == XRT_FILE_LIMIT || status == XRT_DISCOVERY_BUDGET) return XPE_LIMIT;
    if (status == XRT_OUT_OF_MEMORY) return XPE_NOMEM;
    return XPE_IO;
}
static enum xpe_status operation(struct xpe_job *job, uint64_t at, void *out, size_t size, int validate) {
    for (;;) {
        if (__atomic_load_n(&job->cancel, __ATOMIC_ACQUIRE)) return XPE_CANCELLED;
        if (now() >= job->deadline) return XPE_LIMIT;
        enum xrt_status runtime = validate ? xrt_file_view_validate(job->view) : xrt_file_view_read(job->view, at, out, size);
        pthread_mutex_lock(&job->mutex);
        job->snapshot.runtime_status = runtime;
        if (runtime == XRT_OK && !validate) {
            ++job->snapshot.source_reads;
            job->snapshot.source_bytes += size;
        }
        pthread_mutex_unlock(&job->mutex);
        if (runtime != XRT_DISCOVERY_PENDING) return converted(runtime);
        /* Foreground RPCs get priority. Retry on the worker only. */
        const struct timespec pause = {.tv_nsec = 1000000};
        nanosleep(&pause, NULL);
    }
}
static enum xpe_status read_source(void *context, uint64_t at, void *out, size_t size) {
    struct xpe_job *job = context;
    if (!job->joined) return operation(job, at, out, size, 0);
    if (__atomic_load_n(&job->cancel, __ATOMIC_ACQUIRE)) return XPE_CANCELLED;
    if (job->snapshot.state != XPE_JOB_READY) return job->snapshot.status;
    /* Later unwind reads belong to the owner. Never spin behind a foreground
     * RPC, and never apply the construction deadline to cached metadata. */
    enum xrt_status runtime = xrt_file_view_read(job->view, at, out, size);
    enum xpe_status status = converted(runtime);
    if (status != XPE_OK && runtime != XRT_DISCOVERY_PENDING) {
        pthread_mutex_lock(&job->mutex);
        job->snapshot.state = XPE_JOB_FAILED;
        job->snapshot.status = status;
        job->snapshot.runtime_status = runtime;
        pthread_mutex_unlock(&job->mutex);
    }
    return status;
}
static int cancelled(struct xpe_job *job) {
    return __atomic_load_n(&job->cancel,__ATOMIC_ACQUIRE) || now()>=job->deadline;
}
static void load_pdb(struct xpe_job *job) {
    if(xpe_info(job->image)->codeview_count==0)return;
    job->pdb_status="unavailable";
    if(job->root_fd<0 || !job->mapped_path || cancelled(job))return;
    if(xpe_info(job->image)->codeview_count!=1){job->pdb_status="ambiguous_codeview";return;}
    const struct xpe_codeview *cv=xpe_codeview(job->image,0);
    const char *name=cv->path;
    for(const char *at=name;*at;++at)if(*at=='/' || *at=='\\')name=at+1;
    size_t length=strlen(name);
    if(!length || length>255 || !strcmp(name,".") || !strcmp(name,"..") || strchr(name,':')) {
        job->pdb_status="unsafe_name";return;
    }
    const char *slash=strrchr(job->mapped_path,'/');
    if(!slash || job->mapped_path[0]!='/')return;
    size_t directory=(size_t)(slash-job->mapped_path)+1;
    char path[8192];if(directory+length>=sizeof path)return;
    memcpy(path,job->mapped_path,directory);memcpy(path+directory,name,length+1);
    /* Only the RSDS basename is used, beside the PE in its pinned target root.
     * O_PATH lets us reject devices/FIFOs/symlinks before any read-open. A
     * mapping's path is canonical, so a symlink anywhere in it was planted
     * after the maps read: refuse those too, not only a final one. */
    const struct open_how how={.flags=O_PATH|O_NOFOLLOW|O_CLOEXEC,
        .resolve=RESOLVE_IN_ROOT|RESOLVE_NO_MAGICLINKS|RESOLVE_NO_SYMLINKS};
#ifdef SYS_openat2
    int pin=(int)syscall(SYS_openat2,job->root_fd,path,&how,sizeof how);
#else
    (void)how;int pin=-1;
#endif
    if(pin<0)return;
    struct stat st;struct statfs fs;
    if(fstat(pin,&st) || !S_ISREG(st.st_mode) || fstatfs(pin,&fs) ||
        (unsigned long)fs.f_type==PROC_SUPER_MAGIC || (unsigned long)fs.f_type==SYSFS_MAGIC ||
        (unsigned long)fs.f_type==DEBUGFS_MAGIC || (unsigned long)fs.f_type==TRACEFS_MAGIC ||
        (unsigned long)fs.f_type==CGROUP2_SUPER_MAGIC) {close(pin);return;}
    if(xrt_file_identity(pin,&job->pdb_identity)!=XRT_OK){close(pin);return;}
    if(job->pdb_identity.size<0 || job->pdb_identity.size>XPDB_MAX_FILE_BYTES) {
        job->pdb_status="limit";close(pin);return;
    }
    char proc[64];snprintf(proc,sizeof proc,"/proc/self/fd/%d",pin);
    int fd=open(proc,O_RDONLY|O_NONBLOCK|O_NOCTTY|O_CLOEXEC);close(pin);
    if(fd<0)return;
    unsigned char *bytes=NULL;size_t size=(size_t)job->pdb_identity.size;
    if(xrt_file_unchanged(fd,&job->pdb_identity)!=XRT_OK){job->pdb_status="changed";goto done;}
    uint64_t available=job->allowance-xpe_info(job->image)->retained_bytes;
    size_t source_bytes=size?size:1;
    if(source_bytes>available){job->budget_exhausted=1;goto done;}
    bytes=malloc(size?size:1);if(!bytes){job->pdb_status="out_of_memory";goto done;}
    for(size_t at=0;at<size;) {
        if(cancelled(job)){job->pdb_status="cancelled";goto done;}
        size_t n=size-at;if(n>65536)n=65536;
        ssize_t got=pread(fd,bytes+at,n,(off_t)at);
        if(got<0 && errno==EINTR)continue;
        if(got<=0){job->pdb_status="io";goto done;}at+=(size_t)got;
    }
    struct xpdb_section sections[XPE_MAX_SECTIONS];unsigned count=xpe_info(job->image)->section_count;
    for(unsigned i=0;i<count;++i) {
        const struct xpe_section *s=xpe_section(job->image,i);
        sections[i]=(struct xpdb_section){s->rva,s->raw_size>s->virtual_size?s->raw_size:s->virtual_size};
    }
    enum xpdb_status status=xpdb_load_budget(bytes,size,cv->guid,cv->age,sections,count,
        available-source_bytes,&job->pdb);
    if(status==XPDB_BUDGET)job->budget_exhausted=1;
    job->pdb_status=xpdb_status_name(status);
    if(cancelled(job) || xrt_file_unchanged(fd,&job->pdb_identity)!=XRT_OK) {
        xpdb_destroy(job->pdb);job->pdb=NULL;job->pdb_status=cancelled(job)?"cancelled":"changed";
    }
    if(job->pdb){job->pdb_fd=fd;fd=-1;}
done:free(bytes);if(fd>=0)close(fd);
}
static void *worker(void *context) {
    struct xpe_job *job = context;
    const struct xrt_file_identity *identity = xrt_file_view_identity(job->view);
    const struct xpe_source source = {job, (uint64_t)identity->size, XPE_FILE, read_source};
    enum xpe_status status = xpe_load_budget(&source, job->allowance, &job->image);
    if(status==XPE_OK)load_pdb(job);
    if(job->budget_exhausted)status=XPE_BUDGET;
    if(job->root_fd>=0){close(job->root_fd);job->root_fd=-1;}
    free(job->mapped_path);job->mapped_path=NULL;
    if (status == XPE_OK) status = operation(job, 0, NULL, 0, 1);
    if (__atomic_load_n(&job->cancel, __ATOMIC_ACQUIRE)) status = XPE_CANCELLED;
    pthread_mutex_lock(&job->mutex);
    job->snapshot.status = status;
    job->snapshot.state = status == XPE_OK ? XPE_JOB_READY : XPE_JOB_FAILED;
    pthread_mutex_unlock(&job->mutex);
    /* Last access to job: even a failed OS join cannot leave ownership of
     * the source ambiguous or force a caller to publish unfinished data. */
    __atomic_store_n(&job->released, 1, __ATOMIC_RELEASE);
    return NULL;
}
enum xpe_status xpe_job_start(struct xrt_file_view *view, int32_t pid, const char *path, uint64_t allowance, struct xpe_job **out) {
    if (!out) return XPE_MALFORMED;
    *out = NULL;
    const struct xrt_file_identity *identity = xrt_file_view_identity(view);
    if (!view || !identity || identity->size <= 0) return XPE_MALFORMED;
    struct xpe_job *job = calloc(1, sizeof *job);
    if (!job) return XPE_NOMEM;
    job->allowance=allowance<XPE_JOB_MAX_BYTES?allowance:XPE_JOB_MAX_BYTES;
    job->root_fd=-1;job->pdb_fd=-1;job->pdb_status="absent";
    if(pid>0 && path && !xrt_file_view_remote(view)) {
        if(strnlen(path,4097)>4096){free(job);return XPE_LIMIT;}
        job->mapped_path=strdup(path);
        if(!job->mapped_path){free(job);return XPE_NOMEM;}
        char root[64];snprintf(root,sizeof root,"/proc/%d/root",pid);
        job->root_fd=open(root,O_PATH|O_DIRECTORY|O_CLOEXEC);
    }
    if (pthread_mutex_init(&job->mutex, NULL)) {
        if(job->root_fd>=0)close(job->root_fd);
        free(job->mapped_path);free(job);return XPE_NOMEM;
    }
    job->view = view;
    job->snapshot.state = XPE_JOB_PENDING;
    uint64_t start = now();
    if (start > UINT64_MAX-UINT64_C(30000000000)) {
        pthread_mutex_destroy(&job->mutex);
        if(job->root_fd>=0)close(job->root_fd);
        free(job->mapped_path);free(job);return XPE_IO;
    }
    job->deadline = start + UINT64_C(30000000000);
    xrt_file_view_background(view);
    if (pthread_create(&job->thread, NULL, worker, job)) {
        pthread_mutex_destroy(&job->mutex);
        if(job->root_fd>=0)close(job->root_fd);
        free(job->mapped_path);free(job);return XPE_NOMEM;
    }
    *out = job;
    return XPE_OK;
}
void xpe_job_poll(struct xpe_job *job, struct xpe_job_snapshot *out) {
    if (!out) return;
    if (!job) { *out = (struct xpe_job_snapshot){.state=XPE_JOB_FAILED,.status=XPE_MALFORMED}; return; }
    pthread_mutex_lock(&job->mutex);
    *out = job->snapshot;
    pthread_mutex_unlock(&job->mutex);
    if (__atomic_load_n(&job->cancel, __ATOMIC_ACQUIRE)) {
        out->state = XPE_JOB_FAILED;
        out->status = XPE_CANCELLED;
    }
}
void xpe_job_cancel(struct xpe_job *job) {
    if (job) __atomic_store_n(&job->cancel, 1, __ATOMIC_RELEASE);
}
int xpe_job_join(struct xpe_job *job) {
    if (!job) return -1;
    if (job->joined) return 1;
    if (!__atomic_load_n(&job->released, __ATOMIC_ACQUIRE)) return 0;
    int status = pthread_tryjoin_np(job->thread, NULL);
    if (status == EBUSY) return 0;
    job->joined = 1;
    if (status) {
        xpe_job_cancel(job);
        /* The worker no longer accesses job. A nonjoinable/already reaped
         * thread needs no join; detach any remaining joinable OS resource. */
        (void)pthread_detach(job->thread);
        return -1;
    }
    return 1;
}
struct xpe_image *xpe_job_image(struct xpe_job *job) {
    if (!job || !job->joined || __atomic_load_n(&job->cancel, __ATOMIC_ACQUIRE)) return NULL;
    return job->snapshot.state == XPE_JOB_READY ? job->image : NULL;
}
const struct xpdb *xpe_job_pdb(struct xpe_job *job) {
    if(!xpe_job_image(job) || !job->pdb || strcmp(job->pdb_status,"ok"))return NULL;
    if(xrt_file_unchanged(job->pdb_fd,&job->pdb_identity)!=XRT_OK) {
        job->pdb_status="changed";return NULL;
    }
    return job->pdb;
}
uint64_t xpe_job_retained_bytes(struct xpe_job *job) {
    struct xpe_image *image=xpe_job_image(job);
    if(!image)return 0;
    return xpe_info(image)->retained_bytes+(job->pdb?xpdb_info(job->pdb)->retained_bytes:0);
}
const char *xpe_job_pdb_status(struct xpe_job *job) {
    if(!xpe_job_image(job))return "pending";
    (void)xpe_job_pdb(job);return job->pdb_status;
}
enum xpe_status xpe_job_validate(struct xpe_job *job) {
    if (!job || !job->joined) return XPE_MALFORMED;
    if (__atomic_load_n(&job->cancel, __ATOMIC_ACQUIRE)) return XPE_CANCELLED;
    if (job->snapshot.state != XPE_JOB_READY) return job->snapshot.status;
    /* A completed image can be reused later; the parse deadline only bounds
     * construction, not its lifetime. Validation performs one bounded call. */
    enum xrt_status runtime = xrt_file_view_validate(job->view);
    if (runtime == XRT_DISCOVERY_PENDING) return XPE_IO;
    enum xpe_status status = converted(runtime);
    if (status != XPE_OK) {
        pthread_mutex_lock(&job->mutex);
        job->snapshot.state = XPE_JOB_FAILED;
        job->snapshot.status = status;
        job->snapshot.runtime_status = runtime;
        pthread_mutex_unlock(&job->mutex);
    }
    return status;
}
void xpe_job_destroy(struct xpe_job *job) {
    if (!job) return;
    xpe_job_cancel(job);
    if (!job->joined && pthread_join(job->thread, NULL)) {
        /* Destruction may wait; publication never does. A join failure must
         * not free a source the worker could still be reading. */
        while (!__atomic_load_n(&job->released, __ATOMIC_ACQUIRE)) {
            const struct timespec pause = {.tv_nsec = 1000000};
            nanosleep(&pause, NULL);
        }
        (void)pthread_detach(job->thread);
    }
    xpe_destroy(job->image);
    xpdb_destroy(job->pdb);
    if(job->pdb_fd>=0)close(job->pdb_fd);
    (void)xrt_file_view_close(job->view);
    pthread_mutex_destroy(&job->mutex);
    free(job);
}
