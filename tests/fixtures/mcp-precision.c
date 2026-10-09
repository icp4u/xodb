/* These synthetic pointer bits are never dereferenced. */
#include <stdint.h>
__attribute__((noinline)) static void precision_stop(void) {
    volatile uintptr_t wide = UINT64_C(0x20000000000001);
    void *volatile pointer = (void *)(uintptr_t)UINT64_MAX;
    volatile intptr_t negative = INT64_MIN;
    __asm__ volatile("" : : "m"(wide), "m"(pointer), "m"(negative) : "memory"); /* PRECISION_STOP */
}
int main(void) { precision_stop(); return 0; }
