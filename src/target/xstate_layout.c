/* Live-host XSAVE component layout; no target actions or state changes. */
#include <stdint.h>
#include <cpuid.h>
uint64_t xodb_xstate_features(void) {
    unsigned a,b,c,d;
    if (!__get_cpuid(1,&a,&b,&c,&d) || !(c & bit_OSXSAVE)) return 3;
    unsigned lo,hi;
    __asm__ volatile("xgetbv" : "=a"(lo), "=d"(hi) : "c"(0));
    return ((uint64_t)hi << 32) | lo;
}
int xodb_xstate_component(unsigned component, unsigned *offset, unsigned *size) {
    unsigned a,b,c,d;
    if (!__get_cpuid_count(0x0d,component,&a,&b,&c,&d) || !a) return 0;
    *offset=b; *size=a;
    return 1;
}
