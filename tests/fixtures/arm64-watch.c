#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/prctl.h>
#include <sys/mman.h>
#include <signal.h>

volatile uint64_t data[4] __attribute__((aligned(8))) = {3,3,3,3};
volatile uint64_t *fault_data;
extern void harness_write(void), harness_fault(void);
__asm__(".text\n.global harness_write\nharness_write:\nstr x1, [x0]\nret\n.global harness_fault\nharness_fault:\nldr x3, [x2]\nret\n");
__attribute__((noinline)) void ready(void) { __asm__ volatile("" ::: "memory"); }
__attribute__((noinline)) void store(volatile uint64_t *p, uint64_t value) {
    __asm__ volatile(".global watch_store\nwatch_store:\nstr %1, [%0]" :: "r"(p), "r"(value) : "memory");
}
static uint64_t read_n(volatile void *p, unsigned n) {
    switch(n) { case 1:return *(volatile uint8_t*)p;case 2:return *(volatile uint16_t*)p;case 4:return *(volatile uint32_t*)p;default:return *(volatile uint64_t*)p; }
}
static void write_n(volatile void *p, unsigned n, uint64_t v) {
    switch(n) { case 1:*(volatile uint8_t*)p=v;break;case 2:*(volatile uint16_t*)p=v;break;case 4:*(volatile uint32_t*)p=v;break;default:store(p,v); }
}
static void *worker(void *arg) { (void)arg;store(data,7);store(data,11);return NULL; }
int main(int argc,char **argv) {
    prctl(PR_SET_PTRACER, PR_SET_PTRACER_ANY);
    const char *mode=argc>1?argv[1]:"range";
    if (!strcmp(mode,"harness")) {
        register uint64_t a __asm__("x0")=(uintptr_t)data;
        register uint64_t b __asm__("x1")=(uintptr_t)harness_write;
        register uint64_t c __asm__("x2")=(uintptr_t)harness_fault;
        __asm__ volatile("brk #1" : "+r"(a), "+r"(b), "+r"(c) :: "memory");
        return 0;
    }
    if (!strcmp(mode,"attach")) { for (;;) { ready();store(data,data[0]+1);usleep(10000); } }
    if (!strcmp(mode,"fault")) {
        fault_data=mmap(NULL,8192,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);
        fault_data[0]=3;ready();mprotect((void*)fault_data,8192,PROT_READ);store(fault_data,7);return 8;
    }
    unsigned n=argc>2?strtoul(argv[2],0,0):8, offset=argc>3?strtoul(argv[3],0,0):0;
    volatile void *p=(volatile char*)data+offset;
    if (!strcmp(mode,"wide")) { data[0]=3ULL<<32;ready();store(data,7ULL<<32);store(data,11ULL<<32);return 0; }
    if (!strcmp(mode,"pair")) {
        ready();__asm__ volatile("stp %1, %2, [%0]"::"r"(data),"r"(7ULL),"r"(11ULL):"memory");return data[1]==11?0:9;
    }
    if (!strcmp(mode,"clone")) { ready();pthread_t thread; if(pthread_create(&thread,NULL,worker,NULL)) return 7;pthread_join(thread,NULL);return data[0]==11?0:6; }
    if (!strcmp(mode,"exec")) { ready();execl("/bin/true","true",(char*)NULL);return 5; }
    if (!strcmp(mode,"slots")) { ready();for(int i=0;i<4;++i)store(&data[i],7+i);return 0; }
    if (!strcmp(mode,"same")) { ready();store(data,3);store(data,7);return 0; }
    write_n(p,n,3);ready();volatile uint64_t loaded=read_n(p,n);(void)loaded;
    write_n(p,n,7);write_n(p,n,11);return read_n(p,n)==11?0:4;
}
