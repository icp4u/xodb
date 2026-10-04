/* Owned prefork capacity fixture: at most 129 children, all reaped by parent. */
#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

volatile unsigned worker_number;
__attribute__((noinline)) void capacity_ready(void) { __asm__ volatile("" ::: "memory"); }
__attribute__((noinline)) void capacity_worker(unsigned number) {
    worker_number = number;
    __asm__ volatile("" ::: "memory");
}
int main(void) {
    pid_t children[129];
    unsigned count = 0;
    int result = 0;
    alarm(60);
    capacity_ready();
    for (; count < 129; ++count) {
        pid_t child = fork();
        if (child < 0) { result = 90; break; }
        if (child == 0) { capacity_worker(count + 1); _exit(0); }
        children[count] = child;
    }
    for (unsigned i = 0; i < count; ++i) {
        int status = 0;
        pid_t got;
        do { got = waitpid(children[i], &status, 0); } while (got < 0 && errno == EINTR);
        if (got != children[i] || !WIFEXITED(status) || WEXITSTATUS(status)) result = 91;
    }
    return result;
}
