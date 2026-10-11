/* Real compiler CFI: a dynamically aligned bridge saves rbp/rbx/r14 using
 * DW_CFA_expression; its caller needs rbp to compute the next CFA. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include "check.h"

static uintptr_t truth[6];
static const char *oracle_path;

__attribute__((noinline,noclone)) void unwind_realign_stop(void) {
    __asm__ volatile("" ::: "memory");
}

__attribute__((noinline,noclone)) static uintptr_t inner(long a,long b,long c,long d,long e,long f,long g) {
    _Alignas(64) volatile unsigned char aligned[128];
    aligned[0]=(unsigned char)(a+b+c+d+e+f+g);
    truth[0]=(uintptr_t)__builtin_return_address(0);
    FILE *out=fopen(oracle_path,"w");CHECK(out);
    for(unsigned i=0;i<6;i++)CHECK(fprintf(out,"%llx\n",(unsigned long long)truth[i])>0);
    CHECK(fclose(out)==0);
    unwind_realign_stop();
    __asm__ volatile("" : : "r"(aligned) : "memory");
    return aligned[0];
}

__attribute__((force_align_arg_pointer,noinline,noclone)) static uintptr_t bridge(long n) {
    register uintptr_t b __asm__("rbx")=(uintptr_t)n*11;
    register uintptr_t r __asm__("r14")=(uintptr_t)n*17;
    __asm__ volatile("" : "+r"(b),"+r"(r) : : "memory");
    truth[1]=(uintptr_t)__builtin_return_address(0);
    uintptr_t answer=inner(n,2,3,4,5,6,7);
    __asm__ volatile("" : "+r"(b),"+r"(r) : : "memory");
    return answer+b+r;
}

__attribute__((noinline,noclone,optimize("no-omit-frame-pointer"))) static uintptr_t outer(long n) {
    register uintptr_t b __asm__("rbx")=UINT64_C(0x123456789abcdef0);
    register uintptr_t r __asm__("r14")=UINT64_C(0x76543210fedcba98);
    __asm__ volatile("" : "+r"(b),"+r"(r) : : "memory");
    truth[2]=(uintptr_t)__builtin_return_address(0);
    __asm__ volatile("movq %%rbp,%0" : "=r"(truth[3]));
    truth[4]=b;truth[5]=r;
    uintptr_t answer=bridge(n);
    __asm__ volatile("" : "+r"(b),"+r"(r) : : "memory");
    return answer+b+r;
}
int main(int argc,char **argv) {
    CHECK(argc==2);oracle_path=argv[1];
    volatile uintptr_t result=outer(argc);
    (void)result;return 0;
}
