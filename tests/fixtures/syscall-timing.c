#define _GNU_SOURCE
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>
__attribute__((noinline)) void profile_ready(void) { __asm__ volatile("" ::: "memory"); }
__attribute__((noinline)) void profile_done(void) { __asm__ volatile("" ::: "memory"); }
static uint64_t now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return (uint64_t)t.tv_sec*1000000000+t.tv_nsec; }
int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "wait";
    profile_ready();
    if (!strcmp(mode,"wait")) {
        char ch;
        if (syscall(SYS_read,-1,&ch,1) != -1 || errno != EBADF) return 2;
        struct timespec delay={0,50000000};
        for (int i=0;i<3;i++) nanosleep(&delay,0);
    } else if (!strcmp(mode,"sustained")) {
        struct timespec delay={0,2000000};
        for (int i=0;i<300;i++) {
            for (int j=0;j<64;j++) syscall(SYS_getpid);
            nanosleep(&delay,0);
        }
    } else if (!strcmp(mode,"burst")) {
        for (int i=0;i<1000000;i++) syscall(SYS_getpid);
    } else if (!strcmp(mode,"exit")) return 0;
    else if (!strcmp(mode,"exec")) { execl("/bin/true","true",(char *)0); return 3; }
    uint64_t begin=now();
    volatile uint64_t counter=0;
    while (now()-begin<100000000) counter++;
    profile_done();
    return counter == 0;
}
