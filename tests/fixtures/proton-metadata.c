#define _GNU_SOURCE 1
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include "../check.h"

__attribute__((noinline)) void metadata_ready(void) { __asm__ volatile("" ::: "memory"); }
int main(int argc, char **argv)
{
    CHECK(argc == 3);
    for (int i = 1; i < argc; ++i) {
        int fd = open(argv[i], O_RDONLY | O_CLOEXEC);
        CHECK(fd >= 0);
        CHECK(mmap(0, 4096, PROT_READ | PROT_EXEC, MAP_PRIVATE, fd, 0) != MAP_FAILED);
        close(fd);
    }
    metadata_ready();
    for (;;) pause();
}
