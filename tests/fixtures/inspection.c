#define _GNU_SOURCE
#include <stdint.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
unsigned char *region, *arena;
unsigned char values[32] = {0x11, 0x22, 0x33, 0x44};
volatile int phase;
int vector_width=128;
__attribute__((noinline)) void inspect_ready(void) { __asm__ volatile ("" ::: "memory"); }
__attribute__((noinline)) void inspect_changed(void) { __asm__ volatile ("" ::: "memory"); }
__attribute__((target("avx512f"),noinline)) static void ready512(const float *p) {
    vector_width=512;
    __asm__ volatile("vmovups (%0), %%zmm0\n\tvmovups (%0), %%zmm31\n\tmov $0xa55a, %%eax\n\tkmovw %%eax, %%k1" :: "r"(p) : "eax", "zmm0", "zmm31", "k1");
    inspect_ready();
}
__attribute__((target("avx"),noinline)) static void ready256(const float *p) {
    vector_width=256;
    __asm__ volatile("vmovups (%0), %%ymm0" :: "r"(p) : "ymm0");
    inspect_ready();
}
int main(void) {
    alarm(20);
    region=mmap(0,12288,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);
    arena=mmap(0,64*1024*1024,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);
    if(region==MAP_FAILED || arena==MAP_FAILED) return 2;
    memcpy(region+4093,"ABABA",5);
    memcpy(region+8189,"ABABA",5);
    if(munmap(region+4096,4096)) return 3;
    memcpy(arena+4093,"ABABA",5);
    memcpy(arena+65534,"ABABA",5);
    const float floats[16]={1.25f,-2.5f,3.75f,4.5f,5.25f,6.25f,7.25f,8.25f,9.25f,10.25f,11.25f,12.25f,13.25f,14.25f,15.25f,16.25f};
    const long double ld=6.25L;
    __asm__ volatile ("movups %0, %%xmm0\n\tfldt %1" :: "m"(floats),"m"(ld) : "xmm0");
    if(__builtin_cpu_supports("avx512f")) ready512(floats);
    else if(__builtin_cpu_supports("avx")) ready256(floats);
    else inspect_ready();
    values[1]=0x99; values[17]=0x88; phase=1;
    __asm__ volatile ("pxor %%xmm0, %%xmm0\n\tfstp %%st(0)" ::: "xmm0");
    inspect_changed();
    sleep(5);
    return 0;
}
