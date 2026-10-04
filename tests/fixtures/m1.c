#include <stdint.h>
#include <signal.h>
#include <stdlib.h>
#include <unistd.h>

struct State { int64_t value; int64_t writes; };
volatile struct State state = {7, 0};
__attribute__((noinline)) void change_value(volatile struct State *item, int64_t amount) {
    int64_t next = item->value + amount;
    item->value = next; /* WATCH_WRITE */
    item->writes += 1;
}
int main(int argc, char **argv) {
    if (argc > 1 && argv[1][0] == 'e') { execl("/bin/true", "true", (char *)0); return 4; }
    if (argc > 1 && argv[1][0] == 't') {
        /* Test rendezvous: rdi/rsi expose actual ASLR-adjusted data/code addresses. */
#if defined(__x86_64__)
        __asm__ volatile("int3" : : "D"(&state), "S"(change_value) : "memory");
#else
        raise(SIGTRAP);
#endif
    }
    change_value(&state, 5); /* FIRST_CALL */
    change_value(&state, 9); /* SECOND_CALL */
    if (argc > 1 && argv[1][0] == 'w') for (;;) usleep(10000);
    return state.value == 21 && state.writes == 2 ? 0 : 3;
}
