/* Owned native Android demo. No arguments, network, files or app interaction. */
#include <stdint.h>
#include <signal.h>
#include <sys/prctl.h>
#include <unistd.h>

struct State { int64_t value; int64_t writes; };
volatile struct State state = {7, 0};
__attribute__((noinline)) void change_value(volatile struct State *item, int64_t amount) {
    int64_t next = item->value + amount;
    item->value = next; /* WATCH_WRITE */
    item->writes += 1;
}
int main(void) {
    if (prctl(PR_SET_PDEATHSIG, SIGKILL) != 0 || getppid() == 1) return 2;
    alarm(300); /* Bound an interactive demo even after an explicit detach. */
    change_value(&state, 5); /* FIRST_CALL */
    change_value(&state, 9); /* SECOND_CALL */
    return state.value == 21 && state.writes == 2 ? 0 : 3;
}
