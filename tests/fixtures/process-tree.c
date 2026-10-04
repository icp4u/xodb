/* Owned process-tree fixture. vfork modes intentionally exercise Linux's
 * shared address space while every task is controlled by the test debugger. */
#define _GNU_SOURCE
#include <sys/wait.h>
#include <unistd.h>
#include <signal.h>
#include <string.h>
#include <errno.h>
#include <sched.h>
volatile unsigned tree_value;
__attribute__((noinline)) void tree_ready(void) { __asm__ volatile("" ::: "memory"); }
__attribute__((noinline)) void tree_child(void) { tree_value++; __asm__ volatile("" ::: "memory"); tree_value++; }
#if defined(__x86_64__)
__attribute__((naked,noinline)) long tree_raw_fork(void) {
    __asm__ volatile("mov $57, %eax; .globl tree_fork_instruction; tree_fork_instruction: syscall; ret");
}
#else
static long tree_raw_fork(void) { return fork(); }
#endif
static unsigned char clone_stack[65536];
static int clone_child(void *unused) { (void)unused; tree_child(); return 0; }
int main(int argc, char **argv) {
    const char *mode=argc>1?argv[1]:"fork";
    tree_ready();
    pid_t child=!strcmp(mode,"clone-vm")?clone(clone_child,clone_stack+sizeof clone_stack,CLONE_VM|SIGCHLD,0):!strncmp(mode,"vfork",5)?vfork():!strcmp(mode,"step")?(pid_t)tree_raw_fork():fork();
    if(child<0)return 90;
    if(child==0){
        tree_child();
        if(!strcmp(mode,"vfork-exec")){execl("/bin/true","true",(char*)0);_exit(91);}
        _exit(0);
    }
    int status=0;while(waitpid(child,&status,0)<0){if(errno!=EINTR)return 92;}
    return WIFEXITED(status)?WEXITSTATUS(status):93;
}
