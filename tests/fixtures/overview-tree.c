/* Owned synthetic application for the headless overview test: a process
 * group of one parent and N children that all hold both ends of one unix
 * socketpair. Child 0 burns CPU; the others sleep. Prints "ready" once every
 * child exists and exits (with its group) when stdin closes.
 * usage: overview-tree N */
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

volatile unsigned long spin;

int main(int argc, char **argv)
{
    int n = argc > 1 ? atoi(argv[1]) : 3;
    int pair[2];
    if (n < 1 || n > 64 || setpgid(0, 0) != 0 || socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0) return 2;
    int ready[2];
    if (pipe(ready) != 0) return 2;
    for (int i = 0; i < n; ++i) {
        pid_t pid = fork();
        if (pid < 0) return 2;
        if (pid == 0) {
            close(ready[0]);
            if (write(ready[1], "x", 1) != 1) _exit(2);
            close(ready[1]);
            if (i == 0) for (;;) spin++;
            for (;;) pause();
        }
    }
    close(ready[1]);
    char c;
    for (int i = 0; i < n; ++i)
        if (read(ready[0], &c, 1) != 1) return 2;
    printf("ready %d\n", (int)getpid());
    fflush(stdout);
    while (read(0, &c, 1) > 0) {}
    signal(SIGTERM, SIG_IGN);
    kill(0, SIGTERM);
    while (wait(NULL) > 0) {}
    return 0;
}
