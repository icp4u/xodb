/* Owned, command-driven syscall byte oracle for passive event collection. */
#define _GNU_SOURCE 1
#include <assert.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/prctl.h>
#include <unistd.h>
int main(int argc, char **argv)
{
    assert(argc == 2);
    prctl(PR_SET_PDEATHSIG, SIGKILL);
    assert(prctl(PR_SET_PTRACER, (unsigned long)strtoul(argv[1], NULL, 10), 0, 0, 0) == 0);
    int fd = open("events.data", O_RDWR | O_CREAT | O_TRUNC, 0600);
    assert(fd >= 0);
    assert(write(fd, "abcdefgh", 8) == 8);
    assert(lseek(fd, 0, SEEK_SET) == 0);
    int seed = open("other.data", O_RDWR | O_CREAT | O_TRUNC, 0600);
    assert(seed >= 0);
    assert(write(seed, "different file", 14) == 14);
    close(seed);
    printf("ready %d %d\n", (int)getpid(), fd);
    fflush(stdout);
    char buf[64];
    assert(read(0, buf, 1) == 1);
    assert(read(fd, buf, 3) == 3);
    assert(pread(fd, buf, 4, 3) == 4);
    assert(read(fd, buf, 64) == 5);
    assert(read(fd, buf, 1) == 0);
    assert(write(fd, "12345", 5) == 5);
    assert(pwrite(fd, "xy", 2, 0) == 2);
    assert(read(-1, buf, 1) == -1);
    int dupfd = dup(fd);
    assert(dupfd >= 0);
    assert(close(dupfd) == 0);
    assert(close(fd) == 0);
    int next = open("other.data", O_RDWR);
    assert(next == fd);
    assert(read(next, buf, 1) == 1);
    assert(write(next, "ZZ", 2) == 2);
    puts("done");
    fflush(stdout);
    assert(read(0, buf, 1) == 1);
    while (buf[0] == 'p' || buf[0] == 'b') {
        const int paced = buf[0] == 'p';
        const int first = paced ? 1000 : 2000;
        /* More than one maximum MCP page, with an idle tail for pagination. */
        for (int i = 0; i < 600; ++i) {
            int pagefd = fcntl(next, F_DUPFD_CLOEXEC, first + i);
            assert(pagefd == first + i);
            assert(pwrite(pagefd, "P", 1, 0) == 1);
            assert(close(pagefd) == 0);
            if (paced) usleep(1000); /* b deliberately overflows a small perf ring */
        }
        puts(paced ? "paged" : "burst");
        fflush(stdout);
        assert(read(0, buf, 1) == 1);
    }
    close(next);
    return 0;
}
