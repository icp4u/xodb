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
static int matching(const char *path, int32_t pid, const struct xrt_mapping *m)
{
    int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0)
        return -1;
    if (xodb_mapped_file_matches(fd, pid, m->start, m->end, m->device_major, m->device_minor,
                                 m->inode, 0) == 1)
        return fd;
    close(fd);
    return -1;
}
static enum xrt_status mapped(int32_t pid, const struct xrt_mapping *m, int *out)
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
    if (pid > 0) {
        snprintf(path, length + 96, "/proc/%d/map_files/%llx-%llx", pid,
                 (unsigned long long)m->start, (unsigned long long)m->end);
        fd = matching(path, pid, m);
        if (fd < 0) {
            snprintf(path, length + 96, "/proc/%d/exe", pid);
            fd = matching(path, pid, m);
        }
        if (fd < 0) {
            snprintf(path, length + 96, "/proc/%d/root%s", pid, m->path);
            fd = matching(path, pid, m);
        }
    }
    if (fd < 0)
        fd = matching(m->path, pid, m);
    free(path);
    if (fd < 0)
        return XRT_FILE_UNAVAILABLE;
    *out = fd;
    return XRT_OK;
}
enum xrt_status xrt_process_file(int32_t pid, const struct xrt_file_request *r, int *out)
{
    if (!r || !out)
        return XRT_INVALID_ARGUMENT;
    if (r->kind == XRT_FILE_MAPPED)
        return mapped(pid, &r->mapping, out);
    char path[96];
    switch (r->kind) {
    case XRT_FILE_MAPS:
        if (pid <= 0)
            return XRT_INVALID_PID;
        snprintf(path, sizeof(path), "/proc/%d/maps", pid);
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
    return XRT_OK;
}
enum xrt_status xrt_target_file(const struct xrt_target *t, const struct xrt_file_request *r,
                                int *fd)
{
    return xrt_target_file_open(t, r, fd, NULL);
}
enum xrt_status xrt_target_file_open(const struct xrt_target *t, const struct xrt_file_request *r,
                                     int *fd, struct xrt_file_identity *identity)
{
    if (!t || !r || !fd)
        return XRT_INVALID_ARGUMENT;
    if (t->connection)
        return xrt_remote_file(t, r, fd, identity);
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
    enum xrt_status status = xrt_process_file(pid, r, &opened);
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
