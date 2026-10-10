/* Fast lane (<5 s). Only pathname selection is injected; candidate descriptors
 * and live VMA/device/inode validation are real, owned kernel objects. */
#define _GNU_SOURCE 1
#define _FILE_OFFSET_BITS 64
#include "target_internal.h"
#include "xrt_files.h"
#include "check.h"
#include <fcntl.h>
#include <stdarg.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>

static int image_fd, wrong_fd, selected, wrong_first, calls;
static char candidates[4][160];
static int fixture_open(const char *path, int flags, ...)
{
    CHECK(flags == (O_RDONLY | O_NONBLOCK | O_CLOEXEC));
    CHECK(calls < 4 && strcmp(path, candidates[calls]) == 0);
    const int attempt = calls++;
    if (attempt == selected || wrong_first)
        return fcntl(attempt == selected ? image_fd : wrong_fd, F_DUPFD_CLOEXEC, 0);
    errno = EACCES;
    return -1;
}
#define open fixture_open
#include "../src/runtime/files.c"
#undef open

/* The remote transport is outside this pathname fixture. Its source must be
 * labelled remote, never guessed from a local /proc path. */
enum xrt_status xrt_remote_file(const struct xrt_target *t, const struct xrt_file_request *r,
                                int *fd, struct xrt_file_identity *identity)
{
    (void)t;
    (void)r;
    *fd = fcntl(image_fd, F_DUPFD_CLOEXEC, 0);
    CHECK(*fd >= 0);
    return identity ? xrt_file_identity(*fd, identity) : XRT_OK;
}
int main(int argc, char **argv)
{
    const long page = sysconf(_SC_PAGESIZE);
    CHECK(page > 0);
    image_fd = memfd_create("file-path-fixture", MFD_CLOEXEC);
    wrong_fd = memfd_create("wrong-file-fixture", MFD_CLOEXEC);
    CHECK(image_fd >= 0 && wrong_fd >= 0);
    CHECK(ftruncate(image_fd, page) == 0 && ftruncate(wrong_fd, page) == 0);
    CHECK(pwrite(image_fd, "owned", 5, 0) == 5);
    void *address = mmap(NULL, (size_t)page, PROT_NONE, MAP_PRIVATE, image_fd, 0);
    CHECK(address != MAP_FAILED);
    struct stat st;
    CHECK(fstat(image_fd, &st) == 0);
    const struct xrt_file_request request = {.kind = XRT_FILE_MAPPED, .mapping = {
        .start = (uintptr_t)address, .end = (uintptr_t)address + (uint64_t)page,
        .inode = st.st_ino, .device_major = major(st.st_dev),
        .device_minor = minor(st.st_dev), .path = "/owned-container-library.so"}};
    snprintf(candidates[0], sizeof(candidates[0]), "/proc/%d/map_files/%llx-%llx", getpid(),
             (unsigned long long)request.mapping.start, (unsigned long long)request.mapping.end);
    snprintf(candidates[1], sizeof(candidates[1]), "/proc/%d/exe", getpid());
    snprintf(candidates[2], sizeof(candidates[2]), "/proc/%d/root%s", getpid(), request.mapping.path);
    snprintf(candidates[3], sizeof(candidates[3]), "%s", request.mapping.path);
    const enum xrt_file_source sources[] = {XRT_FILE_SOURCE_MAP_FILES, XRT_FILE_SOURCE_EXE,
        XRT_FILE_SOURCE_ROOT, XRT_FILE_SOURCE_HOST};
    struct xrt_target target = {.pid = getpid()};
    for (wrong_first = 0; wrong_first <= 1; ++wrong_first) {
        for (selected = 0; selected < 4; ++selected) {
            calls = 0;
            enum xrt_file_source source = XRT_FILE_SOURCE_UNKNOWN;
            struct xrt_file_identity identity;
            int fd = -1;
            CHECK(xrt_target_file_resolved(&target, &request, &fd, &identity, &source) == XRT_OK);
            CHECK(source == sources[selected] && calls == selected + 1);
            CHECK(identity.inode == (uint64_t)st.st_ino);
            char bytes[5];
            CHECK(pread(fd, bytes, sizeof(bytes), 0) == sizeof(bytes));
            CHECK(memcmp(bytes, "owned", sizeof(bytes)) == 0);
            CHECK(close(fd) == 0);
        }
    }
    /* Wrong inode at every fallback must publish neither fd nor provenance. */
    calls = 0;
    selected = -1;
    wrong_first = 1;
    int fd = -1;
    enum xrt_file_source source = XRT_FILE_SOURCE_UNKNOWN;
    CHECK(xrt_process_file_resolved(getpid(), &request, &fd, &source) == XRT_FILE_UNAVAILABLE);
    CHECK(fd == -1 && source == XRT_FILE_SOURCE_UNKNOWN && calls == 4);
    CHECK(munmap(address, (size_t)page) == 0);
    calls = 0;
    selected = 0;
    CHECK(xrt_process_file_resolved(getpid(), &request, &fd, &source) == XRT_FILE_UNAVAILABLE);
    CHECK(fd == -1 && source == XRT_FILE_SOURCE_UNKNOWN && calls == 4);
    target.connection = (void *)&target;
    calls = 0;
    CHECK(xrt_target_file_resolved(&target, &request, &fd, NULL, &source) == XRT_OK);
    CHECK(source == XRT_FILE_SOURCE_REMOTE && calls == 0);
    CHECK(close(fd) == 0);
    CHECK(close(wrong_fd) == 0 && close(image_fd) == 0);
    /* The acceptance runner plants this wrong expectation to prove CHECK is
     * active even with NDEBUG and release runtime headers. */
    if (argc == 2 && strcmp(argv[1], "--wrong-result") == 0)
        CHECK(source == XRT_FILE_SOURCE_ROOT);
    puts("file paths: four resolution sources, identity rejection, vanished VMA, remote label passed");
    return 0;
}
