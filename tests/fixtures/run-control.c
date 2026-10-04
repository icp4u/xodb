#include <signal.h>
#include <unistd.h>
volatile int answer;
__attribute__((noinline)) int recurse(int depth) {
    volatile int copy = depth;
    if (depth) return recurse(depth - 1) + copy;
    return copy; /* LEAF_STOP */
}
__attribute__((noinline)) void finished(void) { answer += 0; }
int main(void) {
    alarm(15);
    answer = recurse(5);
    finished();
    return answer == 15 ? 0 : 1;
}
