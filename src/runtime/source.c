#define _GNU_SOURCE 1
#define _FILE_OFFSET_BITS 64
#include "xrt_source.h"
#include "target_internal.h"
#include "wire_target.h"
#include "../debug/source_paths.h"
#include <fcntl.h>
#include <linux/magic.h>
#include <linux/openat2.h>
#include <stdlib.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <sys/syscall.h>

/* The path is already lexically normalized. Virtual filesystem prefixes
 * remain forbidden even when the request used redundant or parent segments. */
static int safe_path(const char *path)
{
    int first = 1;
    while (*path) {
        while (*path == '/') ++path;
        const char *begin = path;
        while (*path && *path != '/') ++path;
        size_t n = (size_t)(path-begin);
        if (!n || (n == 1 && begin[0] == '.')) continue;
        if (first && ((n == 4 && !memcmp(begin,"proc",4)) ||
                      (n == 3 && (!memcmp(begin,"sys",3) || !memcmp(begin,"dev",3))))) return 0;
        first = 0;
    }
    return !first;
}
static enum xrt_status open_source(int32_t pid, const char *path, int *out,
                                    struct xrt_source_file *meta)
{
    char name[64];
    snprintf(name,sizeof name,"/proc/%d/root",pid);
    int root = open(name,O_PATH|O_DIRECTORY|O_CLOEXEC);
    if (root < 0) return XRT_FILE_UNAVAILABLE;
    /* O_PATH avoids invoking device/FIFO open handlers before type checking.
     * Every untrusted component is resolved beneath the target's actual root. */
    const struct open_how how = {.flags=O_PATH|O_NOFOLLOW|O_CLOEXEC,
        .resolve=RESOLVE_IN_ROOT|RESOLVE_NO_MAGICLINKS|RESOLVE_NO_SYMLINKS};
#ifdef SYS_openat2
    int pin = (int)syscall(SYS_openat2,root,path,&how,sizeof how);
#else
    (void)how;
    int pin = -1; errno = ENOSYS;
#endif
    int error = errno;
    close(root);
    if (pin < 0) {
        if (error == ENOSYS || error == EINVAL) meta->reason=XRT_SOURCE_KERNEL_UNSUPPORTED;
        else if (error == ELOOP || error == EXDEV) meta->reason=XRT_SOURCE_PATH_UNSAFE;
        return XRT_FILE_UNAVAILABLE;
    }
    enum xrt_status status = XRT_FILE_UNAVAILABLE;
    struct stat st;
    if (fstat(pin,&st)) goto done;
    if (S_ISLNK(st.st_mode)) { meta->reason=XRT_SOURCE_PATH_UNSAFE; goto done; }
    if (!S_ISREG(st.st_mode)) goto done;
    struct statfs fs;
    if (fstatfs(pin,&fs)) goto done;
    if ((unsigned long)fs.f_type == PROC_SUPER_MAGIC || (unsigned long)fs.f_type == SYSFS_MAGIC ||
        (unsigned long)fs.f_type == DEVPTS_SUPER_MAGIC || (unsigned long)fs.f_type == DEBUGFS_MAGIC ||
        (unsigned long)fs.f_type == TRACEFS_MAGIC || (unsigned long)fs.f_type == CGROUP2_SUPER_MAGIC) {
        meta->reason=XRT_SOURCE_FILESYSTEM_UNSUPPORTED; goto done;
    }
    status=xrt_file_identity(pin,&meta->identity);
    if (status != XRT_OK) goto done;
    if (meta->identity.size < 0 || meta->identity.size > XRT_SOURCE_MAX) {
        meta->reason=XRT_SOURCE_TOO_LARGE; status=XRT_FILE_LIMIT; goto done;
    }
    /* Only this checked, still-owned regular fd is reopened. The untrusted
     * pathname is never looked up again, so a rename cannot substitute a
     * device or escape the root between the type check and the read open. */
    snprintf(name,sizeof name,"/proc/self/fd/%d",pin);
    int fd=open(name,O_RDONLY|O_NONBLOCK|O_NOCTTY|O_CLOEXEC);
    if (fd < 0) { status=XRT_FILE_UNAVAILABLE; goto done; }
    status=xrt_file_unchanged(fd,&meta->identity);
    if (status == XRT_OK) *out=fd;
    else { close(fd); meta->reason=XRT_SOURCE_CHANGED; }
done:
    close(pin); return status;
}

enum xrt_status xrt_source_local(const struct xrt_target *t, const struct xrt_file_request *request,
                                 const char *path, int *out, struct xrt_source_file *meta)
{
    if (!meta) return XRT_INVALID_ARGUMENT;
    *meta = (struct xrt_source_file){.reason=XRT_SOURCE_INVALID_REQUEST};
    if (!t || !request || !out || !path || path[0] != '/' ||
        strnlen(path, XDW_SOURCE_PATH_MAX) >= XDW_SOURCE_PATH_MAX ||
        request->kind != XRT_FILE_MAPPED || t->connection || t->pid <= 0 || t->core)
        return XRT_INVALID_ARGUMENT;
    *out = -1;
    char normalized[XDW_SOURCE_PATH_MAX];
    if (xdw_source_normalize(path, normalized) != XBO_OK || !safe_path(normalized)) {
        meta->reason=XRT_SOURCE_PATH_UNSAFE; return XRT_FILE_UNAVAILABLE;
    }
    int image = -1, source_fd = -1;
    enum xrt_status status = xrt_target_file(t, request, &image);
    meta->reason = XRT_SOURCE_DEBUG_UNAVAILABLE;
    if (status != XRT_OK) return status;
    struct xbo_local local = {image}; struct xbo_source source = xbo_local_source(&local);
    struct xbo_object *object = NULL;
    struct xbo_budget budget = {.bytes_left=64*1024*1024, .reads_left=65536,
        .deadline_ns=xbo_now_ns()+UINT64_C(250000000)};
    enum xbo_status s = xbo_create(&source, &object);
    if (s == XBO_OK) s = xbo_prepare(object, &budget);
    if (s == XBO_OK) s = xdw_source_path(object, normalized, &budget);
    if (s != XBO_OK) {
        status = XRT_FILE_UNAVAILABLE;
        if (s == XBO_NOT_FOUND) meta->reason = XRT_SOURCE_NOT_LISTED;
        else if (s == XBO_AGAIN || s == XBO_LIMIT) meta->reason = XRT_SOURCE_DEBUG_LIMIT;
        else if (s == XBO_CHANGED) { meta->reason = XRT_SOURCE_CHANGED; status = XRT_FILE_CHANGED; }
        else if (s == XBO_NOMEM) status = XRT_OUT_OF_MEMORY;
        goto done;
    }
    size_t id_size = 0;
    const unsigned char *id = xbo_build_id(object, &id_size);
    if (!id || !id_size || id_size > sizeof meta->build_id) { status=XRT_FILE_UNAVAILABLE; goto done; }
    memcpy(meta->build_id, id, id_size); meta->build_id_size = (uint32_t)id_size;
    /* Resolve in the target's filesystem namespace. Do not fall back to an
     * agent-host pathname if that namespace is inaccessible. */
    int32_t pid = t->pid;
    for (size_t i = 0; i < t->thread_count; ++i)
        if (t->threads[i].state != XRT_EXITED) { pid=t->threads[i].tid; break; }
    meta->reason = XRT_SOURCE_UNAVAILABLE;
    if (xbo_now_ns() >= budget.deadline_ns) {
        meta->reason=XRT_SOURCE_DEBUG_LIMIT; status=XRT_FILE_LIMIT; goto done;
    }
    status = open_source(pid,normalized,&source_fd,meta);
    if (status != XRT_OK) goto done;
    s = xbo_validate(object, &budget);
    if (s != XBO_OK) {
        meta->reason = s == XBO_AGAIN || s == XBO_LIMIT ? XRT_SOURCE_DEBUG_LIMIT : XRT_SOURCE_CHANGED;
        status = meta->reason == XRT_SOURCE_DEBUG_LIMIT ? XRT_FILE_LIMIT : XRT_FILE_CHANGED;
        goto done;
    }
    meta->reason=XRT_SOURCE_READY; *out=source_fd; source_fd=-1; status=XRT_OK;
done:
    if (source_fd >= 0) close(source_fd);
    xbo_destroy(object); close(image); return status;
}
enum xrt_status xrt_source_open(const struct xrt_target *t, const struct xrt_file_request *request,
                                const char *path, struct xrt_source_file *meta)
{
    if (!meta) return XRT_INVALID_ARGUMENT;
    *meta = (struct xrt_source_file){.reason=XRT_SOURCE_INVALID_REQUEST};
    if (!t || !request || request->kind != XRT_FILE_MAPPED || !path || path[0] != '/') return XRT_INVALID_ARGUMENT;
    if (!t->connection) { meta->reason=XRT_SOURCE_NOT_REMOTE; return XRT_INVALID_ARGUMENT; }
    if (!xrt_target_source_capable(t)) { meta->reason=XRT_SOURCE_AGENT_UPDATE; return XRT_FILE_UNAVAILABLE; }
    size_t length = strnlen(path, XDW_SOURCE_PATH_MAX);
    if (length == XDW_SOURCE_PATH_MAX) return XRT_FILE_LIMIT;
    unsigned char *data = malloc(XRT_RPC_DATA_MAX);
    if (!data) return XRT_OUT_OF_MEMORY;
    struct xrt_codec wire = xrt_codec(data, XRT_RPC_DATA_MAX, false);
    struct xrt_file_request copy = *request;
    xrt_wire_file_request(&wire, &copy, NULL, 0);
    xrt_codec_bytes(&wire, (void *)path, length+1);
    if (!wire.ok) { free(data); return XRT_INVALID_ARGUMENT; }
    unsigned char reply[160]; size_t size=0;
    enum xrt_status status = xrt_remote_call(t, &(struct xrt_call){.op=XRT_RPC_SOURCE_OPEN,
        .args={t->image_epoch},
        .data=data, .size=wire.at, .value=&meta->handle, .out=reply, .capacity=sizeof reply, .length=&size});
    free(data);
    if (!size) { meta->reason=XRT_SOURCE_UNAVAILABLE; return status==XRT_OK ? xrt_remote_fail(t,XRT_PROTOCOL_ERROR) : status; }
    struct xrt_codec in = xrt_codec(reply,size,true); uint32_t reason=0;
    xrt_codec_u32(&in,&reason);
    if (reason > XRT_SOURCE_FILESYSTEM_UNSUPPORTED || (status==XRT_OK) != (reason==XRT_SOURCE_READY))
        return xrt_remote_fail(t,XRT_PROTOCOL_ERROR);
    meta->reason=(enum xrt_source_reason)reason;
    if (status == XRT_OK) {
        xrt_wire_file_identity(&in,&meta->identity);
        xrt_codec_u32(&in,&meta->build_id_size);
        if (!meta->build_id_size || meta->build_id_size>sizeof meta->build_id)
            return xrt_remote_fail(t,XRT_PROTOCOL_ERROR);
        xrt_codec_bytes(&in,meta->build_id,meta->build_id_size);
        if (!meta->handle || meta->handle>UINT32_MAX || meta->identity.size<0 ||
            meta->identity.size>XRT_SOURCE_MAX || meta->identity.mtime_ns<0 ||
            meta->identity.mtime_ns>=1000000000 || meta->identity.ctime_ns<0 ||
            meta->identity.ctime_ns>=1000000000) return xrt_remote_fail(t,XRT_PROTOCOL_ERROR);
    }
    if (!in.ok || in.at!=in.size) return xrt_remote_fail(t,XRT_PROTOCOL_ERROR);
    return status;
}
enum xrt_status xrt_source_read(const struct xrt_target *t, const struct xrt_source_file *meta,
                                uint64_t offset, void *out, size_t size)
{
    if (!t || !t->connection || !meta || !meta->handle || meta->identity.size<0 ||
        size>XRT_RPC_DATA_MAX || offset>(uint64_t)meta->identity.size ||
        size>(uint64_t)meta->identity.size-offset || (size&&!out)) return XRT_INVALID_ARGUMENT;
    size_t got=0;
    enum xrt_status status=xrt_remote_call(t,&(struct xrt_call){.op=XRT_RPC_FILE_READ,
        .args={meta->handle,offset,size},.out=out,.capacity=size,.length=&got});
    return status!=XRT_OK ? status : got==size ? XRT_OK : XRT_FILE_CHANGED;
}
enum xrt_status xrt_source_close(const struct xrt_target *t, struct xrt_source_file *meta)
{
    if (!t || !t->connection || !meta || !meta->handle) return XRT_INVALID_ARGUMENT;
    enum xrt_status status=xrt_remote_call(t,&(struct xrt_call){.op=XRT_RPC_FILE_CLOSE,.args={meta->handle}});
    meta->handle=0; return status;
}
