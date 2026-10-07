#include <signal.h>
#include <unistd.h>
#include <string.h>
volatile int answer;
__attribute__((noinline)) int recurse(int depth) {
    volatile int copy = depth;
    if (depth) return recurse(depth - 1) + copy;
    return copy; /* LEAF_STOP */
}
__attribute__((noinline)) void finished(void) { answer += 0; }
__attribute__((noinline)) unsigned fib(unsigned n) {
    return n < 2 ? n : fib(n - 1) + fib(n - 2);
}
__attribute__((noinline)) void wait_seven(void) { sleep(7); }
int main(int argc, char **argv) {
    alarm(60);
    if (argc == 2 && !strcmp(argv[1], "fib")) { answer = (int)fib(13); finished(); return 0; }
    if (argc == 2 && !strcmp(argv[1], "sleep")) { wait_seven(); finished(); return 0; }
    answer = recurse(5);
    finished();
    return answer == 15 ? 0 : 1;
}
