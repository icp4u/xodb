#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>

/* Owned, bounded fixture. The harness checks progress after debugger detach. */
__attribute__((noinline)) uint64_t fixture_marker(uint64_t n) {
    volatile uint64_t value = n + 1;
    return value;
}
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    int fd = open(argv[1], O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return 3;
    alarm(120);
    uint64_t n = 0;
    const struct timespec pause = {0, 1000000};
    for (;;) {
        n = fixture_marker(n);
        if (pwrite(fd, &n, sizeof(n), 0) != sizeof(n)) return 4;
        nanosleep(&pause, NULL);
    }
}
