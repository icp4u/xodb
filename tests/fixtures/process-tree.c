/* Owned process-tree fixture. vfork modes intentionally exercise Linux's
 * shared address space while every task is controlled by the test debugger. */
#define _GNU_SOURCE
#include <sys/wait.h>
#include <unistd.h>
#include <signal.h>
#include <string.h>
#include <errno.h>
#include <sched.h>
#include <stdlib.h>
#include <fcntl.h>
#include <pthread.h>
#include <sys/syscall.h>
volatile unsigned tree_value;
__attribute__((noinline)) void tree_ready(void) { __asm__ volatile("" ::: "memory"); }
__attribute__((noinline)) void tree_done(void) { __asm__ volatile("" ::: "memory"); }
__attribute__((noinline)) void tree_child(void) { tree_value++; __asm__ volatile("" ::: "memory"); tree_value++; }
#if defined(__x86_64__)
__attribute__((naked,noinline)) long tree_raw_fork(void) {
    __asm__ volatile("mov $57, %eax; .globl tree_fork_instruction; tree_fork_instruction: syscall; ret");
}
__attribute__((naked,noinline)) long tree_raw_getpid(void) {
    __asm__ volatile("mov $39, %eax; .globl tree_syscall_instruction; tree_syscall_instruction: syscall; ret");
}
#else
static long tree_raw_fork(void) { return fork(); }
static long tree_raw_getpid(void) { return getpid(); }
#endif
static int tree_wait(pid_t child) { int status=0;while(waitpid(child,&status,0)<0){if(errno!=EINTR)return 92;} return WIFEXITED(status)?WEXITSTATUS(status):93; }
/* Several threads spawn at once, so more than one child borrows the image. */
static void *spawner(void *unused) {
    (void)unused; long bad=0;
    for(int i=0;i<10;i++){pid_t child=vfork();if(child==0){tree_child();execl("/bin/true","true",(char*)0);_exit(91);} if(child<0||tree_wait(child))bad++;}
    return (void*)bad;
}
static int orphan_ready[2];
static void *orphan_exit(void *unused) { (void)unused; char b; while(read(orphan_ready[0],&b,1)<0&&errno==EINTR){} _exit(0); }
static unsigned char clone_stack[65536];
static int clone_child(void *unused) { (void)unused; tree_child(); return 0; }
int main(int argc, char **argv) {
    const char *mode=argc>1?argv[1]:"fork";
    tree_ready();
    if(!strcmp(mode,"syscall")){long pid=tree_raw_getpid();tree_done();return pid>0?0:94;}
    if(!strcmp(mode,"vfork-threads")){
        pthread_t t[4];long bad=0;
        for(int i=0;i<4;i++)if(pthread_create(&t[i],0,spawner,0))return 90;
        for(int i=0;i<4;i++){void *r=0;pthread_join(t[i],&r);bad+=(long)r;}
        tree_done();return bad?95:0;
    }
    if(!strcmp(mode,"vfork-grand")){
        /* The vfork child starts a process of its own before it exits. */
        int fd[2];char b=0;if(pipe(fd))return 90;
        pid_t child=vfork();
        if(child==0){long grand=syscall(SYS_clone,(unsigned long)SIGCHLD,0UL,0UL,0UL,0UL);if(grand==0){tree_child();(void)!write(fd[1],"g",1);_exit(0);} _exit(grand>0?0:91);}
        if(child<0||tree_wait(child))return 96;
        while(read(fd[0],&b,1)<0){if(errno!=EINTR)return 92;}
        tree_done();return b=='g'?0:97;
    }
    if(!strcmp(mode,"vfork-orphan")&&argc>3){
        /* Another thread exits the process while the vfork child is still
         * out. The child sees the exit as end-of-file, waits until the test
         * has seen it too (argv[3] appears), and then leaves a note. */
        int gone[2];pthread_t t;if(pipe(orphan_ready)||pipe(gone)||pthread_create(&t,0,orphan_exit,0))return 90;
        if(vfork()==0){char b;(void)!write(orphan_ready[1],"r",1);close(gone[1]);while(read(gone[0],&b,1)<0&&errno==EINTR){}
            while(access(argv[3],F_OK))usleep(1000);
            int out=open(argv[2],O_WRONLY|O_CREAT|O_TRUNC,0644);(void)!write(out,"survived",8);_exit(0);}
        return 98;
    }
    if(!strcmp(mode,"system")){int s=system("exit 0");tree_done();return WIFEXITED(s)?WEXITSTATUS(s):93;}
    pid_t child=!strcmp(mode,"clone-vm")?clone(clone_child,clone_stack+sizeof clone_stack,CLONE_VM|SIGCHLD,0):!strncmp(mode,"vfork",5)?vfork():!strcmp(mode,"step")?(pid_t)tree_raw_fork():fork();
    if(child<0)return 90;
    if(child==0){
        tree_child();
        if(!strcmp(mode,"vfork-exec")||!strcmp(mode,"fork-exec")){execl("/bin/true","true",(char*)0);_exit(91);}
        _exit(0);
    }
    int status=0;while(waitpid(child,&status,0)<0){if(errno!=EINTR)return 92;}
    tree_done();
    return WIFEXITED(status)?WEXITSTATUS(status):93;
}
