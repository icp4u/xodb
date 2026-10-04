#include <stdint.h>
#include <unistd.h>
volatile int flow_result;
__attribute__((noinline)) int flow_helper(int n) { return n * 3; }
__attribute__((noinline)) int flow_fixture(int value) {
    int sum = 0;
    if (value < 0) sum = -value; /* NEGATIVE_PATH */
    else sum = value + 7;       /* POSITIVE_PATH */
    for (int i = 0; i < 4; ++i) {
        sum += flow_helper(i); /* LOOP_CALL */
        if (sum & 1) sum += 2;
    }
    return sum;                /* FLOW_RETURN */
}
int main(void) {
    flow_result = flow_fixture(5);
    while (1) usleep(10000);
}
