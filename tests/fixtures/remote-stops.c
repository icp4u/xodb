#define _GNU_SOURCE 1
#include <assert.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

volatile unsigned long hits;
__attribute__((noinline)) void remote_hit(void) { ++hits; }
__attribute__((noinline)) void remote_ready(void) { __asm__ volatile ("" ::: "memory"); }
static void *waiting_thread(void *unused)
{
    (void)unused;
    for (;;) usleep(1000);
    return NULL;
}
int main(int argc, char **argv)
{
    assert(argc == 2);
    for (unsigned i = 0; i < 200; ++i) {
        char path[4096];
        assert(snprintf(path, sizeof(path), "%s/lib-%03u.so", argv[1], i) < (int)sizeof(path));
        assert(dlopen(path, RTLD_NOW | RTLD_LOCAL));
    }
    char big_path[4096];
    assert(snprintf(big_path, sizeof(big_path), "%s/big.so", argv[1]) < (int)sizeof(big_path));
    void *big = dlopen(big_path, RTLD_NOW | RTLD_LOCAL);
    assert(big);
    void (*big_hit)(void) = (void (*)(void))dlsym(big, "remote_big_hit");
    assert(big_hit);
    for (unsigned i = 0; i < 20; ++i) {
        char path[4096];
        assert(snprintf(path, sizeof(path), "%s/map-%03u", argv[1], i) < (int)sizeof(path));
        int fd = open(path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0600);
        assert(fd >= 0 && !ftruncate(fd, 4 * 1024 * 1024));
        assert(mmap(NULL, 4 * 1024 * 1024, PROT_READ | (i & 1 ? PROT_EXEC : 0), MAP_PRIVATE, fd, 0) != MAP_FAILED);
        if (i == 19) assert(!unlink(path));
        close(fd);
    }
    int fd = memfd_create("owned-mapping", MFD_CLOEXEC);
    assert(fd >= 0 && !ftruncate(fd, 512 * 1024 * 1024));
    assert(mmap(NULL, 512 * 1024 * 1024, PROT_READ | PROT_EXEC, MAP_PRIVATE, fd, 0) != MAP_FAILED);
    close(fd);
    char huge_path[4096];
    assert(snprintf(huge_path, sizeof(huge_path), "%s/huge-cache", argv[1]) < (int)sizeof(huge_path));
    fd = open(huge_path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0600);
    assert(fd >= 0 && !ftruncate(fd, 64 * 1024 * 1024));
    assert(write(fd, "\177ELF", 4) == 4);
    assert(mmap(NULL, 64 * 1024 * 1024, PROT_READ | PROT_EXEC, MAP_PRIVATE, fd, 0) != MAP_FAILED);
    close(fd);
    pthread_t worker;
    assert(!pthread_create(&worker, NULL, waiting_thread, NULL));
    remote_ready();
    void (*late_hit)(void) = NULL;
    for (unsigned n = 0;; ++n) {
        remote_hit();
        big_hit();
        if (n == 30) {
            char late_path[4096];
            assert(snprintf(late_path, sizeof(late_path), "%s/late.so", argv[1]) < (int)sizeof(late_path));
            void *late = dlopen(late_path, RTLD_NOW | RTLD_LOCAL);
            assert(late);
            late_hit = (void (*)(void))dlsym(late, "remote_late_hit");
            assert(late_hit);
        }
        if (late_hit) late_hit();
        usleep(1000);
    }
}
