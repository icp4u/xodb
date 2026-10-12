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

struct debug_object {
    struct xmo_job *job;
    struct xrt_file_identity identity;
    int fd;
    enum xmo_status status;
    struct xmo_object_map *map;
    struct xmo_dwarf dwarf;
};
struct xmo_job {
    pthread_t thread;
    struct xmo_job_options options;
    char *executable, *basename, *roots[16];
    struct xmo_job_snapshot snapshot;
    struct xmo_image *image;
    struct xrt_file_identity identity;
    struct xrt_file_identity debug_identity;
    struct xmo_dwarf debug, unwind;
    enum xmo_debug_status debug_status;
    unsigned char *compact;
    size_t compact_size;
    struct xmu_table *compact_table;
    enum xmo_status compact_status;
    int debug_fd;
    struct debug_object objects[XMO_MAX_DEBUG_OBJECTS];
    uint32_t object_count;
    struct xmo_debug_map debug_map;
    enum xmo_status map_status;
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
static enum xmo_status read_file(struct xmo_job *j, int fd,
    const struct xrt_file_identity *identity, uint64_t at, void *out, size_t size) {
    enum xmo_status status = active(j);
    if (status != XMO_OK) return status;
    if (size > XMO_MAX_READ_BYTES-j->snapshot.source_bytes || j->snapshot.source_reads >= XMO_MAX_READS) return XMO_LIMIT;
    if (xrt_file_unchanged(fd, identity) != XRT_OK) return XMO_CHANGED;
    size_t done = 0;
    while (done < size) {
        ssize_t n = pread(fd, (unsigned char *)out+done, size-done, (off_t)(at+done));
        if (n < 0 && errno == EINTR) { if ((status = active(j)) != XMO_OK) return status; continue; }
        if (n <= 0) return XMO_IO;
        done += (size_t)n;
    }
    ++j->snapshot.source_reads; j->snapshot.source_bytes += size;
    return xrt_file_unchanged(fd, identity) == XRT_OK ? XMO_OK : XMO_CHANGED;
}
static enum xmo_status read_source(void *context, uint64_t at, void *out, size_t size) {
    struct xmo_job *j=context;
    return read_file(j,j->fd,&j->identity,at,out,size);
}
static enum xmo_status read_debug(void *context, uint64_t at, void *out, size_t size) {
    struct xmo_job *j=context;
    return read_file(j,j->debug_fd,&j->debug_identity,at,out,size);
}
static enum xmo_status read_object(void *context, uint64_t at, void *out, size_t size) {
    struct debug_object *object=context;
    return read_file(object->job,object->fd,&object->identity,at,out,size);
}
static int regular(int fd) {
    struct stat st; struct statfs fs;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || fstatfs(fd, &fs)) return 0;
    unsigned long type = (unsigned long)fs.f_type;
    return type != PROC_SUPER_MAGIC && type != SYSFS_MAGIC && type != DEBUGFS_MAGIC &&
           type != TRACEFS_MAGIC && type != CGROUP2_SUPER_MAGIC;
}
static uint64_t retained(const struct xmo_job *j) {
    uint64_t bytes=xmo_info(j->image)->retained_bytes+j->debug.size+j->unwind.size+j->compact_size+xmu_bytes(j->compact_table);
    for (uint32_t i=0;i<j->object_count;++i) bytes+=j->objects[i].dwarf.size+xmo_object_map_bytes(j->objects[i].map);
    return bytes;
}
static uint64_t available(const struct xmo_job *j) {
    uint64_t used=retained(j);
    return used<j->options.allowance ? j->options.allowance-used : 0;
}
static enum xmo_debug_status debug_failure(enum xmo_status status) {
    if (status==XMO_LIMIT || status==XMO_NOMEM) return XMO_DEBUG_LIMIT;
    if (status==XMO_CHANGED) return XMO_DEBUG_CHANGED;
    if (status==XMO_NOT_FOUND || status==XMO_UNAVAILABLE) return XMO_DEBUG_MISSING;
    return XMO_DEBUG_REFUSED;
}
/* The root is user-selected; every derived path component is pinned without
 * following symlinks. No name read from a Mach-O file is opened here. */
static int bundle_file(int root, const char *name, int inside) {
    int fd=fcntl(root,F_DUPFD_CLOEXEC,0);
    char bundle[262];
    if (snprintf(bundle,sizeof bundle,"%s.dSYM",name)>=(int)sizeof bundle) { if (fd>=0) close(fd);return -1; }
    const char *parts[]={bundle,"Contents","Resources","DWARF",name};
    for (size_t i=inside ? 1 : 0;i<5 && fd>=0;++i) {
        int next=openat(fd,parts[i],O_PATH|O_CLOEXEC|O_NOFOLLOW|(i<4 ? O_DIRECTORY : 0));
        int saved_errno=errno;
        close(fd);fd=next;
        if (fd<0) errno=saved_errno;
    }
    return fd;
}
static enum xmo_debug_status debug_candidate(struct xmo_job *j, int fd) {
    if (!regular(fd) || xrt_file_identity(fd,&j->debug_identity)!=XRT_OK || j->debug_identity.size<0) {
        close(fd);return XMO_DEBUG_REFUSED;
    }
    char descriptor[64];snprintf(descriptor,sizeof descriptor,"/proc/self/fd/%d",fd);
    j->debug_fd=open(descriptor,O_RDONLY|O_NONBLOCK|O_NOCTTY|O_CLOEXEC);close(fd);
    if (j->debug_fd<0) return XMO_DEBUG_REFUSED;
    uint64_t allowance=available(j);
    enum xmo_status status=XMO_LIMIT;
    enum xmo_debug_status result=XMO_DEBUG_LIMIT;
    struct xmo_image *image=NULL;
    if (allowance) {
        const struct xmo_source source={j,(uint64_t)j->debug_identity.size,XMO_FILE,read_debug};
        const struct xmo_options options={.cputype=j->options.cputype,.cpusubtype=j->options.cpusubtype,
            .match_subtype=1,.max_retained_bytes=allowance};
        status=xmo_load(&source,&options,&image);
        result=debug_failure(status);
        if (status==XMO_OK) {
            const struct xmo_info *info=xmo_info(image);
            if (info->cputype!=j->options.cputype || (info->cpusubtype&XMO_CPU_SUBTYPE_MASK)!=(j->options.cpusubtype&XMO_CPU_SUBTYPE_MASK)) result=XMO_DEBUG_ARCH;
            else if (info->filetype!=XMO_MH_DSYM) result=XMO_DEBUG_REFUSED;
            else if (!info->has_uuid || memcmp(info->uuid,j->options.uuid,16)) result=XMO_DEBUG_UUID;
            else if (info->retained_bytes>=allowance) result=XMO_DEBUG_LIMIT;
            else {
                status=xmo_dwarf_build(image,allowance-info->retained_bytes,&j->debug);
                result=status==XMO_OK && j->debug.debug_sections ? XMO_DEBUG_READY : debug_failure(status);
                if (result==XMO_DEBUG_READY && xrt_file_unchanged(j->debug_fd,&j->debug_identity)!=XRT_OK) result=XMO_DEBUG_CHANGED;
            }
        }
    }
    xmo_destroy(image);
    if (result!=XMO_DEBUG_READY) { xmo_dwarf_free(&j->debug);close(j->debug_fd);j->debug_fd=-1; }
    return result;
}
static void object_release(struct debug_object *object) {
    xmo_object_map_free(object->map);object->map=NULL;
    xmo_dwarf_free(&object->dwarf);
    if (object->fd>=0) close(object->fd);
    object->fd=-1;
}
static int object_file(int root, const char *path, int basename_only) {
    if (!path[0] || strlen(path)>XMO_MAX_PATH || strchr(path,'\\') || strchr(path,'(')) return -1;
    char copy[XMO_MAX_PATH+1];memcpy(copy,path,strlen(path)+1);
    /* Absolute build paths are display-only. A basename may be searched in
     * an explicit root, but traversal components never nominate a file. */
    char *save=NULL,*part=strtok_r(copy,"/",&save),*last=NULL;
    while (part) {
        if (!strcmp(part,"..") || !strcmp(part,".")) return -1;
        last=part;part=strtok_r(NULL,"/",&save);
    }
    if (!last || (!basename_only && path[0]=='/')) return -1;
    if (basename_only) return openat(root,last,O_PATH|O_CLOEXEC|O_NOFOLLOW);
    memcpy(copy,path,strlen(path)+1);save=NULL;part=strtok_r(copy,"/",&save);
    int fd=fcntl(root,F_DUPFD_CLOEXEC,0);
    while (part && fd>=0) {
        char *next_part=strtok_r(NULL,"/",&save);
        int next=openat(fd,part,O_PATH|O_CLOEXEC|O_NOFOLLOW|(next_part ? O_DIRECTORY : 0));
        close(fd);fd=next;part=next_part;
    }
    return fd;
}
static enum xmo_status object_candidate(struct xmo_job *j, uint32_t index, int fd) {
    struct debug_object *object=&j->objects[index];
    const struct xmo_debug_object *owner=&j->debug_map.objects[index];
    if (!regular(fd) || xrt_file_identity(fd,&object->identity)!=XRT_OK || object->identity.size<0) {
        close(fd);return XMO_IO;
    }
    if (owner->mtime && (object->identity.mtime_sec<0 || owner->mtime!=(uint64_t)object->identity.mtime_sec)) {
        close(fd);return XMO_CHANGED;
    }
    char descriptor[64];snprintf(descriptor,sizeof descriptor,"/proc/self/fd/%d",fd);
    object->fd=open(descriptor,O_RDONLY|O_NONBLOCK|O_NOCTTY|O_CLOEXEC);close(fd);
    if (object->fd<0) return XMO_IO;
    uint64_t allowance=available(j);
    enum xmo_status status=XMO_LIMIT;
    struct xmo_image *image=NULL;
    if (!allowance) goto done;
    const struct xmo_source source={object,(uint64_t)object->identity.size,XMO_FILE,read_object};
    const struct xmo_options options={.cputype=j->options.cputype,.cpusubtype=j->options.cpusubtype,
        .match_subtype=1,.max_retained_bytes=allowance};
    status=xmo_load(&source,&options,&image);
    if (status!=XMO_OK) goto done;
    if (xmo_info(image)->filetype!=XMO_MH_OBJECT) { status=XMO_UNSUPPORTED;goto done; }
    status=xmo_prepare_labels(image);
    if (status!=XMO_OK) goto done;
    const struct xmo_symbol *unused=NULL;
    status=xmo_symbol_unique(image,"__debug_index_prepare__",&unused);
    if (status!=XMO_OK && status!=XMO_NOT_FOUND) goto done;
    uint64_t parser=xmo_info(image)->retained_bytes;
    allowance=available(j);
    if (parser>=allowance) { status=XMO_LIMIT;goto done; }
    status=xmo_object_map_create(j->image,image,index,allowance-parser,&object->map);
    if (status!=XMO_OK) goto done;
    allowance=available(j);
    if (parser>=allowance) { status=XMO_LIMIT;goto done; }
    status=xmo_dwarf_build_object(image,allowance-parser,xmo_object_external,NULL,&object->dwarf);
    if (status==XMO_OK && xrt_file_unchanged(object->fd,&object->identity)!=XRT_OK) status=XMO_CHANGED;
done:
    xmo_destroy(image);
    if (status!=XMO_OK) object_release(object);
    return status;
}
static void load_objects(struct xmo_job *j, int root) {
    if (j->map_status!=XMO_OK) return;
    if (j->debug_map.object_count>XMO_MAX_DEBUG_OBJECTS) { j->map_status=XMO_LIMIT;return; }
    j->object_count=j->debug_map.object_count;
    for (uint32_t index=0;index<j->object_count;++index) {
        struct debug_object *object=&j->objects[index];
        object->job=j;object->fd=-1;object->status=XMO_NOT_FOUND;
    }
    for (uint32_t index=0;index<j->object_count;++index) {
        struct debug_object *object=&j->objects[index];
        char path[XMO_MAX_PATH+1];
        object->status=xmo_string(j->image,j->debug_map.objects[index].path,path,sizeof path);
        if (object->status!=XMO_OK) continue;
        object->status=XMO_NOT_FOUND;
        for (size_t i=0;i<=j->options.root_count;++i) {
            enum xmo_status active_status=active(j);
            if (active_status!=XMO_OK) { object->status=active_status;break; }
            int dir=i ? open(j->roots[i-1],O_PATH|O_DIRECTORY|O_CLOEXEC) : (root>=0 ? fcntl(root,F_DUPFD_CLOEXEC,0) : -1);
            if (dir<0) continue;
            for (unsigned basename_only=0;basename_only<2;++basename_only) {
                int fd=object_file(dir,path,(int)basename_only);
                if (fd<0) continue;
                object->status=object_candidate(j,index,fd);
                if (object->status==XMO_OK || object->status==XMO_LIMIT || object->status==XMO_CANCELLED) break;
            }
            close(dir);
            if (object->status==XMO_OK || object->status==XMO_LIMIT || object->status==XMO_CANCELLED) break;
        }
    }
}
static void load_debug(struct xmo_job *j, int root, const char *name) {
    j->debug_status=XMO_DEBUG_MISSING;
    /* Prepare every primary-file index before retaining companion buffers,
     * so the parser's allowance cannot overlap memory already held by them. */
    j->map_status=xmo_debug_map(j->image,&j->debug_map);
    if (j->map_status==XMO_OK && j->debug_map.function_count>XMO_MAX_OBJECT_SYMBOLS) j->map_status=XMO_LIMIT;
    if (j->map_status==XMO_OK && j->debug_map.object_count) {
        const struct xmo_symbol *unused=NULL;
        enum xmo_status prepared=xmo_symbol_unique(j->image,"__debug_index_prepare__",&unused);
        if (prepared!=XMO_OK && prepared!=XMO_NOT_FOUND) j->map_status=prepared;
    }
    uint64_t allowance=available(j);
    enum xmo_status status=allowance ? xmo_dwarf_build(j->image,allowance,&j->unwind) : XMO_LIMIT;
    if (status==XMO_OK && j->unwind.debug_sections) {
        j->debug=j->unwind;memset(&j->unwind,0,sizeof j->unwind);
        j->debug_status=XMO_DEBUG_READY;
    }
    const struct xmo_section *section=xmo_find_section(j->image,"__TEXT","__unwind_info");
    allowance=available(j);
    j->compact_status=section && section->size ? XMO_LIMIT : XMO_UNAVAILABLE;
    if (section && section->size && section->size<=allowance && section->size<=16*1024*1024) {
        j->compact=malloc((size_t)section->size);
        if (j->compact) {
            j->compact_status=XMO_OK;
            j->compact_size=(size_t)section->size;
            for (size_t at=0;at<j->compact_size;) {
                size_t n=j->compact_size-at>XMO_MAX_CHUNK ? XMO_MAX_CHUNK : j->compact_size-at;
                j->compact_status=xmo_read_section(j->image,section,at,j->compact+at,n);
                if (j->compact_status!=XMO_OK) break;
                at+=n;
            }
            if (j->compact_status==XMO_OK) j->compact_status=xmu_create(j->compact,j->compact_size,available(j),&j->compact_table);
            free(j->compact);j->compact=NULL;j->compact_size=0;
        }
    }
    if (j->debug_status==XMO_DEBUG_READY) return;
    /* Adjacent dSYM first, then explicit debug directories or dSYM bundles. */
    for (size_t i=0;i<=j->options.root_count;++i) {
        if (active(j)!=XMO_OK) { j->debug_status=XMO_DEBUG_LIMIT;break; }
        int dir=i ? open(j->roots[i-1],O_PATH|O_DIRECTORY|O_CLOEXEC) : (root>=0 ? fcntl(root,F_DUPFD_CLOEXEC,0) : -1);
        if (dir<0) continue;
        for (unsigned inside=0;inside<2;++inside) {
            int fd=bundle_file(dir,name,(int)inside);
            if (fd<0) {
                if (errno!=ENOENT) j->debug_status=XMO_DEBUG_REFUSED;
                continue;
            }
            j->debug_status=debug_candidate(j,fd);
            if (j->debug_status==XMO_DEBUG_READY || j->debug_status==XMO_DEBUG_LIMIT) break;
        }
        close(dir);
        if (j->debug_status==XMO_DEBUG_READY || j->debug_status==XMO_DEBUG_LIMIT) break;
    }
    if (j->debug_status==XMO_DEBUG_MISSING) load_objects(j,root);
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
        if (status==XMO_OK) {
            char *parent=strdup(j->executable);
            if (parent) {
                char *slash=strrchr(parent,'/');const char *name=slash ? slash+1 : j->executable;
                if (slash) *slash=0;
                int dir=open(slash ? (parent[0] ? parent : "/") : ".",O_PATH|O_DIRECTORY|O_CLOEXEC);
                load_debug(j,dir,name);if (dir>=0) close(dir);free(parent);
            } else j->debug_status=XMO_DEBUG_LIMIT;
        }
    } else for (size_t i = 0; i < j->options.root_count; ++i) {
        if ((status = active(j)) != XMO_OK) break;
        int root = open(j->roots[i], O_PATH|O_DIRECTORY|O_CLOEXEC);
        if (root < 0) { status = XMO_NOT_FOUND; continue; }
        int fd = openat(root, j->basename, O_PATH|O_CLOEXEC|O_NOFOLLOW);
        if (fd < 0) { close(root);status = XMO_NOT_FOUND; continue; }
        status = candidate(j, fd);
        if (status==XMO_OK) load_debug(j,root,j->basename);
        close(root);
        if (status == XMO_OK || status == XMO_CANCELLED || status == XMO_LIMIT) break;
    }
    if (status==XMO_OK) j->snapshot.retained_bytes=retained(j);
    j->snapshot.status = status;
    j->snapshot.state = status == XMO_OK ? XMO_JOB_READY : XMO_JOB_FAILED;
    __atomic_store_n(&j->done, 1, __ATOMIC_RELEASE);
    return NULL;
}
static void release(struct xmo_job *j) {
    if (!j) return;
    xmo_destroy(j->image);
    xmo_dwarf_free(&j->debug);xmo_dwarf_free(&j->unwind);free(j->compact);
    xmu_destroy(j->compact_table);
    for (uint32_t i=0;i<j->object_count;++i) object_release(&j->objects[i]);
    if (j->fd >= 0) close(j->fd);
    if (j->debug_fd >= 0) close(j->debug_fd);
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
    j->fd=-1;j->debug_fd=-1;j->debug_status=XMO_DEBUG_MISSING;j->options=*o;j->snapshot.state=XMO_JOB_PENDING;
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
enum xmo_debug_status xmo_job_debug(struct xmo_job *j, const struct xmo_dwarf **out) {
    if (!out) return XMO_DEBUG_REFUSED;
    *out=NULL;
    if (!xmo_job_info(j)) return XMO_DEBUG_MISSING;
    if (xrt_file_unchanged(j->fd,&j->identity)!=XRT_OK ||
        (j->debug_fd>=0 && xrt_file_unchanged(j->debug_fd,&j->debug_identity)!=XRT_OK)) return XMO_DEBUG_CHANGED;
    if (j->debug_status==XMO_DEBUG_READY) *out=&j->debug;
    return j->debug_status;
}
enum xmo_status xmo_job_unwind(struct xmo_job *j, const struct xmo_dwarf **out) {
    if (!out) return XMO_MALFORMED;
    *out=NULL;
    if (!xmo_job_info(j)) return XMO_UNAVAILABLE;
    if (xrt_file_unchanged(j->fd,&j->identity)!=XRT_OK) return XMO_CHANGED;
    if (j->unwind.eh_frame) *out=&j->unwind;
    else if (j->debug.eh_frame) *out=&j->debug;
    return *out ? XMO_OK : XMO_UNAVAILABLE;
}
enum xmo_status xmo_job_compact(struct xmo_job *j, uint64_t pc, struct xmu_row *out) {
    const struct xmo_info *info=xmo_job_info(j);
    if (!info || !out) return XMO_UNAVAILABLE;
    if (xrt_file_unchanged(j->fd,&j->identity)!=XRT_OK) return XMO_CHANGED;
    if (j->compact_status!=XMO_OK) return j->compact_status;
    if (!info->has_text || pc<info->text_vmaddr) return XMO_NOT_FOUND;
    return xmu_lookup(j->compact_table,pc-info->text_vmaddr,out);
}
enum xmo_status xmo_job_object(struct xmo_job *j, uint64_t linked, uint32_t *index,
                             uint64_t *pc, const struct xmo_dwarf **out) {
    if (!index || !pc || !out) return XMO_MALFORMED;
    *out=NULL;*index=0;*pc=0;
    if (!xmo_job_info(j)) return XMO_UNAVAILABLE;
    if (xrt_file_unchanged(j->fd,&j->identity)!=XRT_OK) return XMO_CHANGED;
    if (j->map_status!=XMO_OK) return j->map_status;
    const struct xmo_debug_function *found=NULL;
    for (uint32_t i=0;i<j->debug_map.function_count;++i) {
        const struct xmo_debug_function *f=&j->debug_map.functions[i];
        if (linked<f->address || linked-f->address>=f->size) continue;
        if (found) return XMO_UNAVAILABLE;
        found=f;
    }
    if (!found || found->object>=j->object_count) return XMO_NOT_FOUND;
    struct debug_object *object=&j->objects[found->object];
    if (object->status!=XMO_OK) return object->status;
    if (xrt_file_unchanged(object->fd,&object->identity)!=XRT_OK) return XMO_CHANGED;
    enum xmo_status status=xmo_object_pc(object->map,linked,pc);
    if (status==XMO_OK) { *out=&object->dwarf;*index=found->object; }
    return status;
}
enum xmo_status xmo_job_object_address(struct xmo_job *j, uint32_t index,
                                     uint64_t object, uint64_t *linked) {
    if (!xmo_job_info(j) || index>=j->object_count || j->objects[index].status!=XMO_OK) return XMO_UNAVAILABLE;
    if (xrt_file_unchanged(j->fd,&j->identity)!=XRT_OK ||
        xrt_file_unchanged(j->objects[index].fd,&j->objects[index].identity)!=XRT_OK) return XMO_CHANGED;
    return xmo_object_address(j->objects[index].map,object,linked);
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
