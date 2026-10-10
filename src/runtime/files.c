#define _GNU_SOURCE 1
#define _FILE_OFFSET_BITS 64
#include "xrt_files.h"
#include "target_internal.h"
#include "mapped_file.h"
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>
static int matching(const char *path, int32_t pid, const struct xrt_mapping *m,
                    const struct xodb_maps *maps)
{
    int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0)
        return -1;
    if (xodb_mapped_file_matches_in(fd, pid, maps, m->start, m->end, m->device_major,
                                    m->device_minor, m->inode, 0) == 1)
        return fd;
    close(fd);
    return -1;
}
static enum xrt_status mapped(int32_t pid, const struct xrt_mapping *m, int *out,
                              enum xrt_file_source *source, const struct xodb_maps *maps)
{
    if (!m->inode || !m->path || m->path[0] != '/' || m->start >= m->end)
        return XRT_FILE_UNAVAILABLE;
    const size_t length = strnlen(m->path, 8192);
    if (length >= 8192)
        return XRT_FILE_UNAVAILABLE;
    char *path = malloc(length + 96);
    if (!path)
        return XRT_OUT_OF_MEMORY;
    int fd = -1;
    enum xrt_file_source selected = XRT_FILE_SOURCE_MAP_FILES;
    if (pid > 0) {
        snprintf(path, length + 96, "/proc/%d/map_files/%llx-%llx", pid,
                 (unsigned long long)m->start, (unsigned long long)m->end);
        fd = matching(path, pid, m, maps);
        if (fd < 0) {
            selected = XRT_FILE_SOURCE_EXE;
            snprintf(path, length + 96, "/proc/%d/exe", pid);
            fd = matching(path, pid, m, maps);
        }
        if (fd < 0) {
            selected = XRT_FILE_SOURCE_ROOT;
            snprintf(path, length + 96, "/proc/%d/root%s", pid, m->path);
            fd = matching(path, pid, m, maps);
        }
    }
    if (fd < 0) {
        selected = XRT_FILE_SOURCE_HOST;
        fd = matching(m->path, pid, m, maps);
    }
    free(path);
    if (fd < 0)
        return XRT_FILE_UNAVAILABLE;
    *out = fd;
    if (source)
        *source = selected;
    return XRT_OK;
}
enum xrt_status xrt_process_file(int32_t pid, const struct xrt_file_request *r, int *out)
{
    return xrt_process_file_resolved(pid, r, out, NULL);
}
static enum xrt_status process_file(int32_t pid, const struct xrt_file_request *r, int *out,
                                    enum xrt_file_source *source, const struct xodb_maps *maps)
{
    if (!r || !out)
        return XRT_INVALID_ARGUMENT;
    if (r->kind == XRT_FILE_MAPPED)
        return mapped(pid, &r->mapping, out, source, maps);
    char path[96];
    switch (r->kind) {
    case XRT_FILE_MAPS:
    case XRT_FILE_AUXV:
        if (pid <= 0)
            return XRT_INVALID_PID;
        snprintf(path, sizeof(path), "/proc/%d/%s", pid,
                 r->kind == XRT_FILE_MAPS ? "maps" : "auxv");
        break;
    case XRT_FILE_THREAD_STAT:
    case XRT_FILE_THREAD_COMM:
        if (pid <= 0 || r->tid <= 0)
            return XRT_INVALID_PID;
        snprintf(path, sizeof(path), "/proc/%d/task/%d/%s", pid, r->tid,
                 r->kind == XRT_FILE_THREAD_STAT ? "stat" : "comm");
        break;
    case XRT_FILE_BOOT_ID:
        strcpy(path, "/proc/sys/kernel/random/boot_id");
        break;
    case XRT_FILE_MAPPED:
        return XRT_INVALID_ARGUMENT;
    default:
        return XRT_INVALID_ARGUMENT;
    }
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0)
        return XRT_FILE_UNAVAILABLE;
    *out = fd;
    if (source)
        *source = XRT_FILE_SOURCE_UNKNOWN;
    return XRT_OK;
}
enum xrt_status xrt_process_file_resolved(int32_t pid, const struct xrt_file_request *r,
                                          int *out, enum xrt_file_source *source)
{
    return process_file(pid, r, out, source, NULL);
}
enum xrt_status xrt_target_file(const struct xrt_target *t, const struct xrt_file_request *r,
                                int *fd)
{
    return xrt_target_file_open(t, r, fd, NULL);
}
enum xrt_status xrt_target_file_open(const struct xrt_target *t, const struct xrt_file_request *r,
                                     int *fd, struct xrt_file_identity *identity)
{
    return xrt_target_file_resolved(t, r, fd, identity, NULL);
}
/* One maps read serves every mapped-file open of a stop. Each event, resume
 * and mutation advances the generation, and a stopped address space that no
 * vfork relative shares cannot drop a mapping in between. Owner thread only. */
static const struct xodb_maps *stopped_maps(const struct xrt_target *target, int32_t pid)
{
    struct xrt_target *t = (struct xrt_target *)target;
    if (t->state != XRT_STOPPED || t->vfork_parent)
        return NULL;
    for (size_t i = 0; i < XRT_MAX_THREADS; ++i)
        if (t->vfork_children[i])
            return NULL;
    for (size_t i = 0; i < t->thread_count; ++i)
        if (t->threads[i].state != XRT_STOPPED && t->threads[i].state != XRT_EXITED)
            return NULL;
    if (!t->maps_valid || t->maps_generation != t->generation || t->maps_pid != pid) {
        xodb_maps_free(&t->maps);
        t->maps_valid = xodb_maps_read(pid, &t->maps) == 1;
        t->maps_generation = t->generation;
        t->maps_pid = pid;
    }
    return t->maps_valid ? &t->maps : NULL;
}
enum xrt_status xrt_target_file_resolved(const struct xrt_target *t, const struct xrt_file_request *r,
        int *fd, struct xrt_file_identity *identity, enum xrt_file_source *source)
{
    return xrt_target_file_owner(t, r, fd, identity, source, 0);
}
enum xrt_status xrt_target_file_owner(const struct xrt_target *t, const struct xrt_file_request *r,
        int *fd, struct xrt_file_identity *identity, enum xrt_file_source *source, int owner)
{
    if (!t || !r || !fd)
        return XRT_INVALID_ARGUMENT;
    if (t->connection) {
        enum xrt_status status = xrt_remote_file(t, r, fd, identity);
        if (status == XRT_OK && source)
            *source = XRT_FILE_SOURCE_REMOTE;
        return status;
    }
    if (t->core)
        return XRT_READ_ONLY_CORE;
    /* /proc/<leader>/maps and exe disappear when the leader exits before
     * its workers. Use a surviving TID from the owned process. */
    int32_t pid = t->pid;
    for (size_t i = 0; i < t->thread_count; ++i)
        if (t->threads[i].state != XRT_EXITED) {
            pid = t->threads[i].tid;
            break;
        }
    int opened = -1;
    enum xrt_file_source selected;
    const struct xodb_maps *maps =
        owner && r->kind == XRT_FILE_MAPPED ? stopped_maps(t, pid) : NULL;
    enum xrt_status status = process_file(pid, r, &opened, &selected, maps);
    if (status != XRT_OK)
        return status;
    if (identity) {
        *identity = (struct xrt_file_identity){0};
        if (r->kind == XRT_FILE_MAPPED)
            status = xrt_file_identity(opened, identity);
    }
    if (status != XRT_OK) {
        close(opened);
        return status;
    }
    *fd = opened;
    if (source)
        *source = selected;
    return XRT_OK;
}
enum xrt_status xrt_file_identity(int fd, struct xrt_file_identity *out)
{
    struct stat s;
    if (!out)
        return XRT_INVALID_ARGUMENT;
    if (fstat(fd, &s) || !S_ISREG(s.st_mode))
        return XRT_FILE_UNAVAILABLE;
    *out = (struct xrt_file_identity){.device = s.st_dev,
                                      .inode = s.st_ino,
                                      .size = s.st_size,
                                      .mtime_sec = s.st_mtim.tv_sec,
                                      .mtime_ns = s.st_mtim.tv_nsec,
                                      .ctime_sec = s.st_ctim.tv_sec,
                                      .ctime_ns = s.st_ctim.tv_nsec};
    return XRT_OK;
}

enum xrt_status xrt_file_unchanged(int fd, const struct xrt_file_identity *before)
{
    struct xrt_file_identity now;
    if (xrt_file_identity(fd, &now) != XRT_OK)
        return XRT_FILE_CHANGED;
    return now.device == before->device && now.inode == before->inode && now.size == before->size &&
                   now.mtime_sec == before->mtime_sec && now.mtime_ns == before->mtime_ns &&
                   now.ctime_sec == before->ctime_sec && now.ctime_ns == before->ctime_ns
               ? XRT_OK
               : XRT_FILE_CHANGED;
}
