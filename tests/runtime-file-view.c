#define _GNU_SOURCE 1
#define _FILE_OFFSET_BITS 64
#include "../src/runtime/xrt_files.h"
#include "../src/runtime/xrt_remote.h"
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>

static void one(const char *agent)
{
    const uint64_t tail = UINT64_C(5) * 1024 * 1024 * 1024;
    int fd = memfd_create("ranged-fixture", MFD_CLOEXEC);
    assert(fd >= 0 && ftruncate(fd, (off_t)(tail + 65536)) == 0);
    unsigned char data[65536], output[65536];
    for (size_t i = 0; i < sizeof(data); ++i) data[i] = (unsigned char)(i * 17 + 5);
    assert(pwrite(fd, data, sizeof(data), (off_t)tail) == sizeof(data));
    struct stat st; assert(fstat(fd, &st) == 0);
    char path[96]; snprintf(path, sizeof(path), "/proc/%d/fd/%d", getpid(), fd);
    struct xrt_file_request request = {.kind = XRT_FILE_MAPPED,
        .mapping = {.start = 4096, .end = 8192, .device_major = major(st.st_dev),
                    .device_minor = minor(st.st_dev), .inode = st.st_ino, .path = path}};
    struct xrt_target *target = NULL;
    if (agent) {
        const char *argv[] = {agent, "--stdio", NULL};
        assert(xrt_target_remote(argv, &target) == XRT_OK);
    } else target = xrt_target_create();
    assert(target);
    struct xrt_file_view *view = NULL;
    assert(xrt_target_file_view_open(target, &request, &view) == XRT_OK);
    assert(xrt_file_view_identity(view)->size == (int64_t)(tail + 65536));
    assert(xrt_file_view_validate(view) == XRT_OK);
    assert(xrt_file_view_read(view, tail, output, sizeof(output)) == XRT_OK);
    assert(!memcmp(data, output, sizeof(data)));
    assert(xrt_file_view_read(view, tail + sizeof(data), NULL, 0) == XRT_OK);
    memset(output, 0xa5, sizeof(output));
    assert(xrt_file_view_read(view, UINT64_MAX, output, 1) == XRT_INVALID_ARGUMENT);
    assert(xrt_file_view_read(view, tail, output, sizeof(output) + 1) == XRT_INVALID_ARGUMENT);
    for (size_t i = 0; i < sizeof(output); ++i) assert(output[i] == 0xa5);
    assert(xrt_file_view_validate(view) == XRT_OK); /* Bad request does not poison. */
    if (agent) assert(xrt_target_destroy(target) == XRT_INVALID_STATE);
    else { assert(xrt_target_destroy(target) == XRT_OK); target = NULL; }
    /* The pinned descriptor remains independent of any pathname lookup. A
     * size change permanently poisons both uncached and cached-use validation. */
    assert(ftruncate(fd, (off_t)(tail + 32768)) == 0);
    assert(xrt_file_view_validate(view) == XRT_FILE_CHANGED);
    assert(xrt_file_view_read(view, tail, output, 1) == XRT_FILE_CHANGED);
    assert(output[0] == 0xa5);
    assert(ftruncate(fd, (off_t)(tail + 65536)) == 0);
    assert(xrt_file_view_validate(view) == XRT_FILE_CHANGED);
    enum xrt_status closed = xrt_file_view_close(view);
    assert(closed == (agent ? XRT_FILE_CHANGED : XRT_OK));
    if (target) assert(xrt_target_destroy(target) == XRT_OK);
    assert(close(fd) == 0);
    puts(agent ? "remote ranged file: >5GiB, exact bytes, bounds, lifetime and permanent identity refusal passed" :
                 "local ranged file: >5GiB, exact bytes, bounds, independent lifetime and permanent identity refusal passed");
}
int main(int argc, char **argv)
{
    assert(argc == 1 || argc == 2);
    setvbuf(stdout, NULL, _IONBF, 0);
    assert(prctl(PR_SET_PTRACER, PR_SET_PTRACER_ANY) == 0);
    one(NULL);
    if (argc == 2) one(argv[1]);
    return 0;
}
