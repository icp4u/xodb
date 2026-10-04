/* Nonleader, concurrent fork events; used only as an owned debugger fixture. */
#define _GNU_SOURCE
#include <pthread.h>
#include <sys/wait.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
static pthread_barrier_t barrier;
volatile unsigned tree_value;
__attribute__((noinline)) void tree_ready(void) { __asm__ volatile("" ::: "memory"); }
__attribute__((noinline)) void tree_child(void) { tree_value++; }
static void *worker(void *unused) {
    (void)unused;
    pthread_barrier_wait(&barrier);
    pid_t child=fork();
    if(child<0)_exit(91);
    if(child==0){tree_child();_exit(0);}
    int status=0;
    while(waitpid(child,&status,0)<0)if(errno!=EINTR)_exit(92);
    if(!WIFEXITED(status)||WEXITSTATUS(status))_exit(93);
    return 0;
}
int main(void) {
    pthread_t threads[2];
    tree_ready();
    if(pthread_barrier_init(&barrier,0,2))return 90;
    for(int i=0;i<2;i++)if(pthread_create(&threads[i],0,worker,0))return 94;
    for(int i=0;i<2;i++)pthread_join(threads[i],0);
    pthread_barrier_destroy(&barrier);
    return 0;
}
