#define _GNU_SOURCE 1
#define _FILE_OFFSET_BITS 64
#include "xrt_files.h"
#include <sys/stat.h>
#ifdef __APPLE__
#define st_mtim st_mtimespec
#define st_ctim st_ctimespec
#endif
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
