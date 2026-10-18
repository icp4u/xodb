#include <signal.h>
#include <time.h>
#include <unistd.h>
#include <string.h>
volatile int answer;
volatile unsigned wait_status = ~0u;
__attribute__((noinline)) int recurse(int depth) {
    volatile int copy = depth;
    if (depth) return recurse(depth - 1) + copy;
    return copy; /* LEAF_STOP */
}
__attribute__((noinline)) void finished(void) { answer += 0; }
__attribute__((noinline)) unsigned fib(unsigned n) {
    return n < 2 ? n : fib(n - 1) + fib(n - 2);
}
/* A step over the recursive call ends in this frame, and a step over a
 * straight-line block that moves the stack pointer still stops. */
__attribute__((noinline)) int nest(int depth) {
    int got = depth ? nest(depth - 1) : 0; /* NEST_CALL */
#if defined(__x86_64__)
    __asm__ volatile("push %%rax\n\tnop\n\tnop\n\tnop" ::: "memory"); /* NEST_PUSH */
    __asm__ volatile("pop %%rax\n\tnop\n\tnop\n\tnop" ::: "memory"); /* NEST_POP */
#endif
    return got + depth; /* NEST_DONE */
}
__attribute__((noinline)) void wait_seven(void) { const struct timespec delay = {7, 0}; wait_status = nanosleep(&delay, 0) != 0; }
int main(int argc, char **argv) {
    alarm(60);
    if (argc == 2 && !strcmp(argv[1], "fib")) { answer = (int)fib(13); finished(); return 0; }
    if (argc == 2 && !strcmp(argv[1], "step")) { answer = nest(3); finished(); return 0; }
    if (argc == 2 && !strcmp(argv[1], "sleep")) { wait_seven(); finished(); return 0; }
    answer = recurse(5);
    finished();
    return answer == 15 ? 0 : 1;
}
