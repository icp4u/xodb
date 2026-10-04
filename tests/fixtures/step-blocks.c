#define _POSIX_C_SOURCE 200809L
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
#include <time.h>
volatile int step_value;
static atomic_int done;
__attribute__((noinline)) void short_block(void) {
    __asm__ volatile(".rept 512; nop; .endr; .global step_middle; step_middle:; .rept 512; nop; .endr" ::: "memory"); // SHORT_BLOCK
    step_value = 17; // SHORT_NEXT
}
__attribute__((noinline)) void long_block(void) {
    __asm__ volatile(".rept 12000; nop; .endr" ::: "memory"); // LONG_BLOCK
    step_value = 19; // LONG_NEXT
}
__attribute__((noinline)) void watched_block(void) {
    step_value = 1; step_value = 2; step_value = 3; step_value = 4; // WATCH_BLOCK
    step_value = 5;
}
__attribute__((noinline)) void trap_block(void) {
    __asm__ volatile(".rept 32; nop; .endr; int3; .rept 32; nop; .endr" ::: "memory"); // TRAP_BLOCK
    step_value = 23;
}
static void *worker(void *unused) {
    (void)unused;
    while (!atomic_load(&done)) { struct timespec t={.tv_nsec=1000000}; nanosleep(&t,0); }
    return 0;
}
int main(int argc,char **argv) {
    const char *mode=argc>1?argv[1]:"short";
    pthread_t thread;
    int threaded=!strcmp(mode,"threads");
    if (threaded && pthread_create(&thread,0,worker,0)) return 2;
    if (!strcmp(mode,"long")) long_block();
    else if (!strcmp(mode,"watch")) watched_block();
    else if (!strcmp(mode,"trap")) trap_block();
    else short_block();
    atomic_store(&done,1);
    if (threaded) pthread_join(thread,0);
    return step_value==0;
}
