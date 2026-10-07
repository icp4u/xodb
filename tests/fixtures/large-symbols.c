#include <unistd.h>
/* Actual file contents, not BSS: ordinary snapshot APIs must keep their cap. */
const unsigned char large_data[300u * 1024 * 1024] = {1};
volatile unsigned reached;
__attribute__((noinline)) void large_symbol_hit(void) { ++reached; }
int main(void) {
    for (;;) { large_symbol_hit(); usleep(10000); }
}
