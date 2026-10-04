#include <unistd.h>
volatile long result;
static __attribute__((always_inline)) inline long inside(long seed) {
    long derived=seed*3;
    __asm__ volatile(".globl inline_stop\ninline_stop:\nnop" : "+r"(derived));
    return derived+1;
}
static __attribute__((always_inline)) inline long middle(long input) {
    return inside(input+7);
}
__attribute__((noinline)) long outer(long input) {
    long answer=middle(input);
    result=answer;
    return answer;
}
int main(void) {
    alarm(10);
    return outer(10)==52 ? 0:1;
}
