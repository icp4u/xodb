#include <unistd.h>
struct Pair { long first, second; };
struct Doubles { double first, second; };
volatile long result;
__attribute__((noinline, noipa)) long pieces(struct Pair pair, struct Doubles scale) {
    asm volatile(".globl pieces_stop\npieces_stop:\nnop" :
                 : "r"(pair.first), "r"(pair.second), "x"(scale.first), "x"(scale.second));
    return pair.first + pair.second + (long)scale.first + (long)scale.second;
}
int main(void) {
    alarm(10);
    result = pieces((struct Pair){ 123, -456 }, (struct Doubles){ 6.25, -3.5 });
    return 0;
}
