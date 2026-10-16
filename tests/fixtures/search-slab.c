/* A target with 1 GiB of readable memory already at its entry stop: .bss.
 * The page reads are cheap (the zero page), but a pattern of 0x00 bytes
 * ending in 0x01 never completes and keeps the KMP scan on every byte, so a
 * maximum-length search of the slab stays running for seconds. */
#include <unistd.h>
char slab[1 << 30];
int main(void) {
    for (;;) usleep(10000);
}
