#define _GNU_SOURCE
/* Owned-child Linux ARM64 watchpoint investigation, not a production backend. */
#include <sys/ptrace.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <asm/ptrace.h>
#include <elf.h>
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <pthread.h>

#if !defined(__aarch64__)
#error Run on native ARM64 Linux
#endif
#ifndef TRAP_HWBKPT
#define TRAP_HWBKPT 4 /* Linux UAPI; absent from Jetty glibc 2.27 signal.h. */
#endif
#define MAX_OWNED 64
static pid_t owned[MAX_OWNED];
static size_t owned_count;
static unsigned passed;
static volatile uint64_t *data;
static char *self_path;
static long long now_ms(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (long long)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
static void cleanup(void) {
    for (size_t i=0; i<owned_count; ++i) if (owned[i]>0) {
        kill(owned[i], SIGKILL);
        long long end=now_ms()+2000;
        int status;
        while (now_ms()<end) {
            pid_t r=waitpid(owned[i], &status, WNOHANG|__WALL);
            if (r<0 && errno==ECHILD) break;
            if (r==owned[i] && (WIFEXITED(status)||WIFSIGNALED(status))) break;
            if (r==owned[i] && WIFSTOPPED(status)) ptrace(PTRACE_CONT,r,0,0);
            usleep(1000);
        }
    }
}
static void fail(const char *what, int line) {
    fprintf(stderr,"FAIL line=%d %s errno=%d %s\n",line,what,errno,strerror(errno));
    exit(1);
}
#define CHECK(x) do { if (!(x)) fail(#x, __LINE__); } while (0)
static void call(int request, pid_t pid, uintptr_t addr, uintptr_t value) {
    CHECK(ptrace(request,pid,(void*)addr,(void*)value)==0);
}
static int wait_one(pid_t pid) {
    long long end=now_ms()+3000;
    int status;
    while (now_ms()<end) {
        pid_t r=waitpid(pid,&status,WNOHANG|__WALL);
        if (r==pid) return status;
        CHECK(r==0 || (r<0 && errno==EINTR));
        usleep(1000);
    }
    errno=ETIMEDOUT; fail("wait_one",__LINE__); return 0;
}
static void stopped(pid_t pid,int sig) {
    int status=wait_one(pid);
    if (!WIFSTOPPED(status) || WSTOPSIG(status)!=sig) fprintf(stderr,"WAIT pid=%d expected_signal=%d status=0x%x\n",pid,sig,status);
    CHECK(WIFSTOPPED(status) && WSTOPSIG(status)==sig);
}
static void exited(pid_t pid) {
    int status=wait_one(pid);
    CHECK(WIFEXITED(status) && WEXITSTATUS(status)==0);
    for (size_t i=0;i<owned_count;++i) if(owned[i]==pid) owned[i]=0;
}
static struct user_hwdebug_state get_debug(pid_t pid,int note) {
    struct user_hwdebug_state s; memset(&s,0,sizeof(s));
    struct iovec iov={&s,sizeof(s)};
    call(PTRACE_GETREGSET,pid,note,(uintptr_t)&iov);
    CHECK(iov.iov_len==sizeof(s));
    CHECK((s.dbg_info&255)>0 && (s.dbg_info&255)<=16);
    return s;
}
static void set_debug(pid_t pid,int note,const struct user_hwdebug_state *s) {
    struct iovec iov={(void*)s,8+16*(s->dbg_info&255)};
    call(PTRACE_SETREGSET,pid,note,(uintptr_t)&iov);
}
static struct user_hwdebug_state set_one(pid_t pid,uintptr_t addr,unsigned length,unsigned type) {
    struct user_hwdebug_state s=get_debug(pid,NT_ARM_HW_WATCH);
    memset(s.dbg_regs,0,sizeof(s.dbg_regs));
    /* Linux 4.9 consumes the unaligned address and shifts the low BAS mask. */
    s.dbg_regs[0].addr=addr;
    s.dbg_regs[0].ctrl=1 | (type<<3) | (((1u<<length)-1)<<5);
    set_debug(pid,NT_ARM_HW_WATCH,&s);
    struct user_hwdebug_state actual=get_debug(pid,NT_ARM_HW_WATCH);
    printf("PROGRAM requested=0x%x readback=0x%x addr=0x%llx\n",s.dbg_regs[0].ctrl,actual.dbg_regs[0].ctrl,(unsigned long long)actual.dbg_regs[0].addr);
    return s;
}
static struct user_pt_regs regs(pid_t pid) {
    struct user_pt_regs s;
    struct iovec iov={&s,sizeof(s)};
    call(PTRACE_GETREGSET,pid,NT_PRSTATUS,(uintptr_t)&iov);
    CHECK(iov.iov_len==sizeof(s)); return s;
}
static uint64_t read_value(pid_t pid,uintptr_t addr,unsigned length) {
    uint64_t value=0;
    struct iovec local={&value,length},remote={(void*)addr,length};
    CHECK(process_vm_readv(pid,&local,1,&remote,1,0)==length);
    return value;
}
static siginfo_t info(pid_t pid) {
    siginfo_t s; memset(&s,0,sizeof(s));
    call(PTRACE_GETSIGINFO,pid,0,(uintptr_t)&s); return s;
}
static void hit(pid_t pid,uintptr_t addr) {
    stopped(pid,SIGTRAP); siginfo_t s=info(pid);
    CHECK(s.si_code==TRAP_HWBKPT);
    CHECK((uintptr_t)s.si_addr==addr);
}
static void cont(pid_t pid) {call(PTRACE_CONT,pid,0,0);}
static void clear(pid_t pid) {
    struct user_hwdebug_state s=get_debug(pid,NT_ARM_HW_WATCH);
    memset(s.dbg_regs,0,sizeof(s.dbg_regs)); set_debug(pid,NT_ARM_HW_WATCH,&s);
}
static void advance(pid_t pid,const struct user_hwdebug_state *desired) {
    struct user_hwdebug_state saved=*desired;
    printf("BEFORE STEP ctrl=0x%x\n",saved.dbg_regs[0].ctrl);
    struct user_hwdebug_state disabled=saved;
    for(unsigned i=0;i<(saved.dbg_info&255);++i) disabled.dbg_regs[i].ctrl=0;
    set_debug(pid,NT_ARM_HW_WATCH,&disabled);
    uint64_t pc=regs(pid).pc;
    call(PTRACE_SINGLESTEP,pid,0,0); stopped(pid,SIGTRAP);
    CHECK(info(pid).si_code==TRAP_TRACE);
    CHECK(regs(pid).pc==pc+4);
    set_debug(pid,NT_ARM_HW_WATCH,&saved);
    struct user_hwdebug_state rearmed=get_debug(pid,NT_ARM_HW_WATCH);
    printf("STEPPED pc=0x%llx -> 0x%llx ctrl=0x%x\n",(unsigned long long)pc,(unsigned long long)regs(pid).pc,rearmed.dbg_regs[0].ctrl);
}
static void store_at(uintptr_t addr,unsigned n,uint64_t v) {
    switch(n) {
    case 1: __asm__ volatile("strb %w0,[%1]"::"r"(v),"r"(addr):"memory");break;
    case 2: __asm__ volatile("strh %w0,[%1]"::"r"(v),"r"(addr):"memory");break;
    case 4: __asm__ volatile("str %w0,[%1]"::"r"(v),"r"(addr):"memory");break;
    case 8: __asm__ volatile("str %0,[%1]"::"r"(v),"r"(addr):"memory");break;
    default:_exit(92);
    }
}
static uint64_t load_at(uintptr_t addr,unsigned n) {
    uint64_t v;
    switch(n) {
    case 1: __asm__ volatile("ldrb %w0,[%1]":"=r"(v):"r"(addr):"memory");break;
    case 2: __asm__ volatile("ldrh %w0,[%1]":"=r"(v):"r"(addr):"memory");break;
    case 4: __asm__ volatile("ldr %w0,[%1]":"=r"(v):"r"(addr):"memory");break;
    case 8: __asm__ volatile("ldr %0,[%1]":"=r"(v):"r"(addr):"memory");break;
    default:_exit(93);
    }
    return v;
}
static void *thread_write(void *arg) {store_at((uintptr_t)arg,8,7);return NULL;}
static pid_t spawn(unsigned offset,unsigned n,unsigned mode) {
    memset((void*)data,0,128);
    store_at((uintptr_t)data+offset,n,3);
    pid_t pid=fork(); CHECK(pid>=0);
    if(!pid) {
        CHECK(prctl(PR_SET_PDEATHSIG,SIGKILL)==0);
        CHECK(ptrace(PTRACE_TRACEME,0,0,0)==0); raise(SIGSTOP);
        uintptr_t addr=(uintptr_t)data+offset;
        if(mode==2) {
            pthread_t thread; CHECK(pthread_create(&thread,NULL,thread_write,(void*)addr)==0);
            CHECK(pthread_join(thread,NULL)==0);_exit(0);
        }
        if(mode==3) {execl(self_path,self_path,"exec-child",NULL);_exit(94);}
        if(mode==4) {for(unsigned i=0;i<4;++i) store_at((uintptr_t)&data[i],8,7);_exit(0);}
        if(mode==5) {store_at((uintptr_t)data,8,7);_exit(0);}
        if(mode==6) {
            uint64_t a=7,b=11;
            __asm__ volatile("stp %0,%1,[%2]"::"r"(a),"r"(b),"r"(data):"memory");
            _exit(0);
        }
        if(load_at(addr,n)!=3) _exit(95);
        store_at(addr,n,7);
        if(mode==1) store_at(addr,n,11);
        _exit(0);
    }
    CHECK(owned_count<MAX_OWNED);owned[owned_count++]=pid;
    stopped(pid,SIGSTOP);
    call(PTRACE_SETOPTIONS,pid,0,PTRACE_O_EXITKILL|PTRACE_O_TRACECLONE|PTRACE_O_TRACEEXEC);
    return pid;
}
static void pass(const char *name) {++passed;printf("PASS %s\n",name);}
static void basic(unsigned offset,unsigned n) {
    printf("CASE write offset=%u length=%u\n",offset,n);
    pid_t pid=spawn(offset,n,1); uintptr_t addr=(uintptr_t)data+offset;
    struct user_hwdebug_state original=get_debug(pid,NT_ARM_HW_WATCH);
    struct user_hwdebug_state desired=set_one(pid,addr,n,2);printf("PHASE first hit\n");cont(pid);hit(pid,addr);
    uint64_t pc=regs(pid).pc;
    CHECK(read_value(pid,addr,n)==3);
    printf("PHASE plain continue\n");cont(pid);hit(pid,addr);
    CHECK(regs(pid).pc==pc && read_value(pid,addr,n)==3);
    printf("PHASE disable step\n");advance(pid,&desired);CHECK(read_value(pid,addr,n)==7);
    printf("PHASE second hit\n");cont(pid);hit(pid,addr);CHECK(read_value(pid,addr,n)==7);
    advance(pid,&desired);CHECK(read_value(pid,addr,n)==11);
    set_debug(pid,NT_ARM_HW_WATCH,&original);
    cont(pid);exited(pid);
    printf("PASS write offset=%u length=%u pre=3 post=7 second=11 plain_continue=retrap pc=0x%llx\n",offset,n,(unsigned long long)pc);++passed;
}
int main(int argc,char **argv) {
    setvbuf(stdout,NULL,_IOLBF,0);self_path=argv[0];
    if(argc==2 && !strcmp(argv[1],"exec-child")) {raise(SIGSTOP);return 0;}
    atexit(cleanup);alarm(90);
    data=mmap(NULL,4096,PROT_READ|PROT_WRITE,MAP_SHARED|MAP_ANONYMOUS,-1,0);
    CHECK(data!=MAP_FAILED);
    pid_t pid=spawn(0,8,0);
    struct user_hwdebug_state w=get_debug(pid,NT_ARM_HW_WATCH);
    struct user_hwdebug_state b=get_debug(pid,NT_ARM_HW_BREAK);
    printf("CAPS watch_slots=%u break_slots=%u debug_version=%u regset_bytes=%zu uid=%d\n",w.dbg_info&255,b.dbg_info&255,(w.dbg_info>>8)&255,sizeof(w),getuid());
    CHECK((w.dbg_info&255)==4); // Expected Jetty baseline; other hosts report a different gate.
    cont(pid);exited(pid);
    for(unsigned n=1;n<=8;n*=2) for(unsigned offset=0;offset+n<=8;offset+=n) basic(offset,n);
    pid=spawn(0,8,0);struct user_hwdebug_state desired=set_one(pid,(uintptr_t)data,8,3);cont(pid);hit(pid,(uintptr_t)data);
    CHECK(read_value(pid,(uintptr_t)data,8)==3);advance(pid,&desired);
    cont(pid);hit(pid,(uintptr_t)data);CHECK(read_value(pid,(uintptr_t)data,8)==3);
    advance(pid,&desired);CHECK(read_value(pid,(uintptr_t)data,8)==7);clear(pid);cont(pid);exited(pid);
    pass("read_write catches load then store");
    pid=spawn(0,8,0);set_one(pid,(uintptr_t)data,8,2);cont(pid);hit(pid,(uintptr_t)data);
    clear(pid);cont(pid);exited(pid);CHECK(*data==7);pass("remove before store permits completion without SIGTRAP");
    pid=spawn(0,8,0);set_one(pid,(uintptr_t)data,8,2);cont(pid);hit(pid,(uintptr_t)data);
    clear(pid);call(PTRACE_DETACH,pid,0,0);exited(pid);CHECK(*data==7);pass("clear then detach preserves target execution");
    pid=spawn(0,8,4);w=get_debug(pid,NT_ARM_HW_WATCH);
    for(unsigned i=0;i<4;++i) {w.dbg_regs[i].addr=(uintptr_t)&data[i];w.dbg_regs[i].ctrl=1|(2<<3)|(255<<5);}
    set_debug(pid,NT_ARM_HW_WATCH,&w);
    struct user_hwdebug_state four=w;
    w.dbg_regs[4].addr=(uintptr_t)&data[4];w.dbg_regs[4].ctrl=1|(2<<3)|(255<<5);
    struct iovec fifth={&w,8+16*5};errno=0;
    CHECK(ptrace(PTRACE_SETREGSET,pid,(void*)NT_ARM_HW_WATCH,&fifth)==-1);
    printf("CAPACITY fifth_slot_errno=%d (%s)\n",errno,strerror(errno));
    CHECK(errno==ENOSPC);set_debug(pid,NT_ARM_HW_WATCH,&four);
    for(unsigned i=0;i<4;++i) {
        cont(pid);hit(pid,(uintptr_t)&data[i]);advance(pid,&four);CHECK(data[i]==7);
    }
    clear(pid);cont(pid);exited(pid);pass("four slots hit and fifth rejected; partial SETREGSET requires rollback");
    pid=spawn(0,8,2);set_one(pid,(uintptr_t)data,8,2);cont(pid);
    int status=wait_one(pid);CHECK(WIFSTOPPED(status) && ((unsigned)status>>16)==PTRACE_EVENT_CLONE);
    unsigned long tid=0;call(PTRACE_GETEVENTMSG,pid,0,(uintptr_t)&tid);stopped((pid_t)tid,SIGSTOP);
    w=get_debug((pid_t)tid,NT_ARM_HW_WATCH);
    for(unsigned i=0;i<(w.dbg_info&255);++i) CHECK(w.dbg_regs[i].ctrl==0 && w.dbg_regs[i].addr==0);
    desired=set_one((pid_t)tid,(uintptr_t)data,8,2);cont((pid_t)tid);hit((pid_t)tid,(uintptr_t)data);
    advance((pid_t)tid,&desired);CHECK(*data==7);clear((pid_t)tid);cont((pid_t)tid);
    status=wait_one((pid_t)tid);CHECK(WIFEXITED(status)&&WEXITSTATUS(status)==0);
    clear(pid);cont(pid);exited(pid);pass("clone starts without watches; program child before resume");
    pid=spawn(0,8,3);set_one(pid,(uintptr_t)data,8,2);cont(pid);
    status=wait_one(pid);CHECK(WIFSTOPPED(status)&&((unsigned)status>>16)==PTRACE_EVENT_EXEC);
    w=get_debug(pid,NT_ARM_HW_WATCH);
    for(unsigned i=0;i<(w.dbg_info&255);++i) CHECK(w.dbg_regs[i].ctrl==0 && w.dbg_regs[i].addr==0);
    cont(pid);stopped(pid,SIGSTOP);cont(pid);exited(pid);pass("exec clears watch regsets");
    for(unsigned mode=5;mode<=6;++mode) {
        unsigned offset=mode==5 ? 4 : 8, n=mode==5 ? 4 : 8;
        pid=spawn(offset,n,mode);uintptr_t addr=(uintptr_t)data+offset;
        desired=set_one(pid,addr,n,2);cont(pid);stopped(pid,SIGTRAP);
        siginfo_t si=info(pid);CHECK(si.si_code==TRAP_HWBKPT);
        CHECK(read_value(pid,addr,n)==3);
        printf("WIDE mode=%s watched=0x%llx reported=0x%llx raw_pc=0x%llx pre=3\n",
               mode==5 ? "str8_upper4" : "stp_second8",(unsigned long long)addr,
               (unsigned long long)(uintptr_t)si.si_addr,(unsigned long long)regs(pid).pc);
        advance(pid,&desired);CHECK(read_value(pid,addr,n)==(mode==5 ? 0 : 11));
        clear(pid);cont(pid);exited(pid);pass(mode==5 ? "wide store overlaps watched subrange" : "pair store hits second watched element");
    }
    printf("SUMMARY passed=%u failed=0\n",passed);munmap((void*)data,4096);return 0;
}
