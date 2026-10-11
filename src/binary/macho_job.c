#define _GNU_SOURCE 1
#include "macho_job.h"
#include "../runtime/xrt_files.h"
#include <errno.h>
#include <fcntl.h>
#include <linux/magic.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <time.h>
#include <unistd.h>

struct xmo_job {
    pthread_t thread;
    struct xmo_job_options options;
    char *executable, *basename, *roots[16];
    struct xmo_job_snapshot snapshot;
    struct xmo_image *image;
    struct xrt_file_identity identity;
    int fd, joined;
    unsigned cancel, done;
    uint64_t deadline;
};
static uint64_t now(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t)) return UINT64_MAX;
    return (uint64_t)t.tv_sec*UINT64_C(1000000000)+(uint64_t)t.tv_nsec;
}
static enum xmo_status active(struct xmo_job *j) {
    if (__atomic_load_n(&j->cancel, __ATOMIC_ACQUIRE)) return XMO_CANCELLED;
    return now() >= j->deadline ? XMO_LIMIT : XMO_OK;
}
static enum xmo_status read_source(void *context, uint64_t at, void *out, size_t size) {
    struct xmo_job *j = context;
    enum xmo_status status = active(j);
    if (status != XMO_OK) return status;
    if (size > XMO_MAX_READ_BYTES-j->snapshot.source_bytes || j->snapshot.source_reads >= XMO_MAX_READS) return XMO_LIMIT;
    if (xrt_file_unchanged(j->fd, &j->identity) != XRT_OK) return XMO_CHANGED;
    size_t done = 0;
    while (done < size) {
        ssize_t n = pread(j->fd, (unsigned char *)out+done, size-done, (off_t)(at+done));
        if (n < 0 && errno == EINTR) { if ((status = active(j)) != XMO_OK) return status; continue; }
        if (n <= 0) return XMO_IO;
        done += (size_t)n;
    }
    ++j->snapshot.source_reads; j->snapshot.source_bytes += size;
    return xrt_file_unchanged(j->fd, &j->identity) == XRT_OK ? XMO_OK : XMO_CHANGED;
}
static int regular(int fd) {
    struct stat st; struct statfs fs;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || fstatfs(fd, &fs)) return 0;
    unsigned long type = (unsigned long)fs.f_type;
    return type != PROC_SUPER_MAGIC && type != SYSFS_MAGIC && type != DEBUGFS_MAGIC &&
           type != TRACEFS_MAGIC && type != CGROUP2_SUPER_MAGIC;
}
static enum xmo_status candidate(struct xmo_job *j, int fd) {
    if (!regular(fd) || xrt_file_identity(fd, &j->identity) != XRT_OK || j->identity.size < 0) {
        j->snapshot.failure = XMO_JOB_FILE; close(fd); return XMO_IO;
    }
    /* Pin and reject special files before a read-open can reach a device.
     * The proc descriptor name refers only to our own verified regular file. */
    char descriptor[64];
    snprintf(descriptor,sizeof descriptor,"/proc/self/fd/%d",fd);
    int readable=open(descriptor,O_RDONLY|O_NONBLOCK|O_NOCTTY|O_CLOEXEC);
    close(fd);fd=readable;
    if (fd<0 || xrt_file_unchanged(fd,&j->identity)!=XRT_OK) {
        if (fd>=0) close(fd);
        j->snapshot.failure=XMO_JOB_CHANGED;return XMO_CHANGED;
    }
    j->fd = fd;
    const struct xmo_source source = {j, (uint64_t)j->identity.size, XMO_FILE, read_source};
    const struct xmo_options options = {.cputype=j->options.cputype, .cpusubtype=j->options.cpusubtype,
        .match_subtype=1, .max_retained_bytes=j->options.allowance};
    enum xmo_status status = xmo_load(&source, &options, &j->image);
    j->snapshot.failure = XMO_JOB_PARSE;
    if (status == XMO_OK) {
        const struct xmo_info *info = xmo_info(j->image);
        if (info->cputype != j->options.cputype || (info->cpusubtype & XMO_CPU_SUBTYPE_MASK) != (j->options.cpusubtype & XMO_CPU_SUBTYPE_MASK)) {
            status = XMO_UNSUPPORTED; j->snapshot.failure = XMO_JOB_ARCH;
        } else if (!info->has_uuid || memcmp(info->uuid, j->options.uuid, 16)) {
            status = XMO_CHANGED; j->snapshot.failure = XMO_JOB_UUID;
        } else if (info->filetype != XMO_MH_EXECUTE && info->filetype != XMO_MH_DYLIB && info->filetype != XMO_MH_DYLINKER && info->filetype != XMO_MH_BUNDLE) {
            status = XMO_UNSUPPORTED;
        } else status = xmo_prepare_labels(j->image);
    }
    if (status == XMO_OK && xrt_file_unchanged(fd, &j->identity) != XRT_OK) {
        status = XMO_CHANGED; j->snapshot.failure = XMO_JOB_CHANGED;
    }
    if (status == XMO_OK) {
        j->snapshot.failure = XMO_JOB_NONE;
        j->snapshot.retained_bytes = xmo_info(j->image)->retained_bytes;
    } else { xmo_destroy(j->image); j->image = NULL; close(j->fd); j->fd = -1; }
    return status;
}
static void *worker(void *context) {
    struct xmo_job *j = context;
    enum xmo_status status = XMO_NOT_FOUND;
    j->snapshot.failure = XMO_JOB_MISSING;
    if (j->executable) {
        int fd = open(j->executable, O_PATH|O_CLOEXEC|O_NOFOLLOW);
        if (fd >= 0) status = candidate(j, fd);
    } else for (size_t i = 0; i < j->options.root_count; ++i) {
        if ((status = active(j)) != XMO_OK) break;
        int root = open(j->roots[i], O_PATH|O_DIRECTORY|O_CLOEXEC);
        if (root < 0) { status = XMO_NOT_FOUND; continue; }
        int fd = openat(root, j->basename, O_PATH|O_CLOEXEC|O_NOFOLLOW);
        close(root);
        if (fd < 0) { status = XMO_NOT_FOUND; continue; }
        status = candidate(j, fd);
        if (status == XMO_OK || status == XMO_CANCELLED || status == XMO_LIMIT) break;
    }
    j->snapshot.status = status;
    j->snapshot.state = status == XMO_OK ? XMO_JOB_READY : XMO_JOB_FAILED;
    __atomic_store_n(&j->done, 1, __ATOMIC_RELEASE);
    return NULL;
}
static void release(struct xmo_job *j) {
    if (!j) return;
    xmo_destroy(j->image);
    if (j->fd >= 0) close(j->fd);
    free(j->executable); free(j->basename);
    for (size_t i = 0; i < j->options.root_count; ++i) free(j->roots[i]);
    free(j);
}
enum xmo_status xmo_job_start(const struct xmo_job_options *o, struct xmo_job **out) {
    if (!o || !out || !o->basename || !o->basename[0] || strlen(o->basename)>255 ||
        strchr(o->basename,'/') || strchr(o->basename,'\\') || !strcmp(o->basename,".") || !strcmp(o->basename,"..") ||
        o->root_count>16 || (o->root_count && !o->roots) || !o->allowance || o->allowance>XMO_MAX_RETAINED_BYTES) return XMO_MALFORMED;
    *out=NULL;
    struct xmo_job *j=calloc(1,sizeof *j);
    if (!j) return XMO_NOMEM;
    j->fd=-1;j->options=*o;j->snapshot.state=XMO_JOB_PENDING;
    j->deadline=now()+UINT64_C(10000000000);
    if (o->executable) {
        if (strlen(o->executable)>4096) { release(j);return XMO_LIMIT; }
        j->executable=strdup(o->executable);
        if (!j->executable) { release(j);return XMO_NOMEM; }
    }
    j->basename=strdup(o->basename);
    if (!j->basename) { release(j);return XMO_NOMEM; }
    for (size_t i=0;i<o->root_count;++i) {
        if (!o->roots[i] || strlen(o->roots[i])>4096) { release(j);return XMO_LIMIT; }
        j->roots[i]=strdup(o->roots[i]);
        if (!j->roots[i]) { release(j);return XMO_NOMEM; }
    }
    if (pthread_create(&j->thread,NULL,worker,j)) { release(j);return XMO_NOMEM; }
    *out=j;return XMO_OK;
}
void xmo_job_poll(struct xmo_job *j, struct xmo_job_snapshot *out) {
    if (!j || !out) return;
    *out=__atomic_load_n(&j->done,__ATOMIC_ACQUIRE) ? j->snapshot : (struct xmo_job_snapshot){.state=XMO_JOB_PENDING};
}
void xmo_job_cancel(struct xmo_job *j) { if (j) __atomic_store_n(&j->cancel,1,__ATOMIC_RELEASE); }
int xmo_job_join(struct xmo_job *j) {
    if (!j) return -1;
    if (j->joined) return 1;
    if (!__atomic_load_n(&j->done,__ATOMIC_ACQUIRE)) return 0;
    if (pthread_join(j->thread,NULL)) return -1;
    j->joined=1;return 1;
}
const struct xmo_info *xmo_job_info(struct xmo_job *j) {
    return j && j->joined && j->snapshot.state==XMO_JOB_READY ? xmo_info(j->image) : NULL;
}
enum xmo_status xmo_job_symbol(struct xmo_job *j, uint64_t address, char *name, size_t capacity, uint64_t *value, uint64_t *size) {
    if (!j || !name || !capacity || !value || !size || !xmo_job_info(j)) return XMO_UNAVAILABLE;
    name[0]=0;*value=0;*size=0;
    if (__atomic_load_n(&j->cancel,__ATOMIC_ACQUIRE)) return XMO_CANCELLED;
    if (xrt_file_unchanged(j->fd,&j->identity)!=XRT_OK) return XMO_CHANGED;
    const struct xmo_symbol *symbol=NULL;
    enum xmo_status status=xmo_symbol_at(j->image,address,&symbol,size);
    if (status!=XMO_OK) return status;
    const struct xmo_section *section=xmo_section(j->image,symbol->sect-1);
    const struct xmo_segment *segment=xmo_segment(j->image,section->segment_index);
    if (!(segment->initprot & 4) || !(section->flags & 0x80000400u)) return XMO_NOT_FOUND;
    status=xmo_string(j->image,symbol->strx,name,capacity);
    if (status==XMO_OK) *value=symbol->value;
    return status;
}
void xmo_job_destroy(struct xmo_job *j) {
    if (!j) return;
    xmo_job_cancel(j);
    if (!j->joined) {
        /* Completion publishes the final snapshot and ends all job accesses.
         * A failed join must not free storage still used by the worker. */
        if (pthread_join(j->thread,NULL)) {
            const struct timespec pause={.tv_nsec=1000000};
            while (!__atomic_load_n(&j->done,__ATOMIC_ACQUIRE)) nanosleep(&pause,NULL);
        }
    }
    release(j);
}
