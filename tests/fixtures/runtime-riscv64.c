/* Owned riscv64 software-step fixture. Labels name every instruction the driver stops on. */
#define _GNU_SOURCE
#include <link.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <unistd.h>
#include <fcntl.h>

volatile int counter;
volatile int alarms;
long seq_result;
extern char code_begin[], code_end[];
long seq(long a0);
void atomic_inc(volatile int *p);
long sleeper(void);

__asm__(
    ".text\n.balign 4\n.globl code_begin\ncode_begin:\n"
    ".globl seq\n.type seq,@function\nseq:\n"
    ".option push\n"
    ".option rvc\n"
    ".globl s_c2\ns_c2: c.addi a0, 1\n"
    ".option norvc\n"
    ".globl s_w4\ns_w4: addi a0, a0, 1\n"
    ".option rvc\n"
    ".globl s_cbeqz_nt\ns_cbeqz_nt: c.beqz a0, s_far\n"
    ".globl s_cbnez_t\ns_cbnez_t: c.bnez a0, s_beq_nt\n"
    "c.addi a0, 5\n"
    ".option norvc\n"
    ".globl s_beq_nt\ns_beq_nt: beq a0, zero, s_far\n"
    ".globl s_bne_t\ns_bne_t: bne a0, zero, s_li_a1\n"
    "addi a0, a0, 5\n"
    ".option rvc\n"
    ".globl s_li_a1\ns_li_a1: c.li a1, 0\n"
    ".globl s_cbeqz_t\ns_cbeqz_t: c.beqz a1, s_cbnez_nt\n"
    "c.addi a0, 5\n"
    ".globl s_cbnez_nt\ns_cbnez_nt: c.bnez a1, s_far\n"
    ".globl s_cj\ns_cj: c.j s_caddiw\n"
    "c.addi a0, 5\n"
    ".globl s_caddiw\ns_caddiw: c.addiw a0, 1\n"
    ".globl s_mv_t6\ns_mv_t6: c.mv t6, ra\n"
    ".option norvc\n"
    ".globl s_jal\ns_jal: jal ra, sub1\n"
    ".globl s_auipc_t0\ns_auipc_t0: auipc t0, %pcrel_hi(sub2)\n"
    ".globl s_addi_t0\ns_addi_t0: addi t0, t0, %pcrel_lo(s_auipc_t0)\n"
    ".globl s_jalr\ns_jalr: jalr ra, 0(t0)\n"
    ".globl s_after_jalr\ns_after_jalr: nop\n"
    ".option rvc\n"
    ".globl s_cjalr\ns_cjalr: c.jalr t0\n"
    ".globl s_after_cjalr\ns_after_cjalr: c.nop\n"
    ".option norvc\n"
    ".globl s_auipc_t1\ns_auipc_t1: auipc t1, %pcrel_hi(sub2)\n"
    ".globl s_addi_t1\ns_addi_t1: addi t1, t1, %pcrel_lo(s_auipc_t1)\n"
    /* The driver rewrites t1 to (sub2 - 8) just before this step, so 8(t1) is sub2. */
    ".globl s_jalr_reg\ns_jalr_reg: jalr ra, 8(t1)\n"
    ".globl s_after_jalr_reg\ns_after_jalr_reg: nop\n"
    ".globl s_auipc_t2\ns_auipc_t2: auipc t2, %pcrel_hi(s_mv_t4)\n"
    ".globl s_addi_t2\ns_addi_t2: addi t2, t2, %pcrel_lo(s_auipc_t2)\n"
    ".option rvc\n"
    ".globl s_cjr\ns_cjr: c.jr t2\n"
    "c.addi a0, 5\n"
    ".option norvc\n"
    ".globl s_mv_t4\ns_mv_t4: mv t4, a0\n"
    ".globl s_li_a7\ns_li_a7: li a7, 172\n" /* getpid */
    ".globl s_ecall\ns_ecall: ecall\n"
    ".globl s_after_ecall\ns_after_ecall: addi a0, t4, 40\n"
    ".globl s_mv_ra\ns_mv_ra: mv ra, t6\n"
    ".option rvc\n"
    ".globl s_ret\ns_ret: c.jr ra\n"
    ".globl s_far\ns_far: c.li a0, -1\n"
    "c.jr ra\n"
    ".globl sub1\nsub1: c.addi a0, 0\n"
    ".globl s_cret\ns_cret: c.jr ra\n"
    ".option norvc\n"
    ".globl sub2\nsub2: addi a0, a0, 0\n"
    ".globl s_jret\ns_jret: jalr zero, 0(ra)\n"
    ".globl sub3\nsub3: addi a0, a0, 100\n"
    "jalr zero, 0(ra)\n"
    ".option pop\n"
    ".size seq, .-seq\n"

    ".globl atomic_inc\n.type atomic_inc,@function\natomic_inc:\n"
    ".option push\n.option norvc\n"
    ".globl s_lr\ns_lr: lr.w a4, (a0)\n"
    "addi a4, a4, 1\n"
    ".globl s_sc\ns_sc: sc.w a5, a4, (a0)\n"
    ".option rvc\n"
    ".globl s_retry\ns_retry: c.bnez a5, s_lr\n"
    ".globl s_after_sc\ns_after_sc: c.jr ra\n"
    ".option pop\n"
    ".size atomic_inc, .-atomic_inc\n"

    /* nanosleep(&req, 0) with a7=101; returns a0 */
    ".globl sleeper\n.type sleeper,@function\nsleeper:\n"
    ".option push\n.option norvc\n"
    "lla a0, sleep_req\n"
    "li a1, 0\n"
    "li a7, 101\n"
    ".globl s_sleep_ecall\ns_sleep_ecall: ecall\n"
    ".globl s_after_sleep\ns_after_sleep: ret\n"
    ".option pop\n"
    ".size sleeper, .-sleeper\n"
    ".globl code_end\ncode_end:\n"
    ".section .rodata\n.balign 8\nsleep_req: .dword 0, 400000000\n"
    ".text\n");

#define ITER 20000
static void *worker(void *arg)
{
    (void)arg;
    for (int i = 0; i < ITER; ++i)
        atomic_inc(&counter);
    return 0;
}
static void on_alarm(int sig)
{
    (void)sig;
    alarms++;
}
__attribute__((noinline)) void phase(int n)
{
    __asm__ volatile("" ::"r"(n) : "memory");
}

static long text_off = -1;
static int find_text(struct dl_phdr_info *info, size_t size, void *data)
{
    (void)size; (void)data;
    uintptr_t want = (uintptr_t)code_begin;
    for (int i = 0; i < info->dlpi_phnum; ++i) {
        const ElfW(Phdr) *ph = &info->dlpi_phdr[i];
        uintptr_t lo = info->dlpi_addr + ph->p_vaddr;
        if (ph->p_type == PT_LOAD && want >= lo && want < lo + ph->p_filesz) {
            text_off = (long)(want - lo + ph->p_offset);
            return 1;
        }
    }
    return 0;
}
static int code_intact(void)
{
    dl_iterate_phdr(find_text, 0);
    size_t n = (size_t)(code_end - code_begin);
    unsigned char disk[4096];
    int fd = open("/proc/self/exe", O_RDONLY);
    if (fd < 0 || text_off < 0 || n > sizeof disk || pread(fd, disk, n, text_off) != (ssize_t)n) {
        printf("code-intact: cannot check\n");
        return 2;
    }
    close(fd);
    int bad = 0;
    for (size_t i = 0; i < n; ++i)
        if (disk[i] != (unsigned char)code_begin[i]) {
            if (!bad)
                printf("code-intact: first diff at %p\n", (void *)(code_begin + i));
            ++bad;
        }
    printf("code-intact: %zu bytes, %d differ\n", n, bad);
    return bad ? 1 : 0;
}

int main(void)
{
    setvbuf(stdout, 0, _IONBF, 0);
    phase(1);
    seq_result = seq(1);
    printf("seq=%ld\n", seq_result);
    phase(2);
    volatile int line_a = 10;     /* LINE_A */
    int line_b = line_a * 3 + 1;  /* LINE_B */
    printf("line=%d\n", line_b);  /* LINE_C */
    phase(3);                      /* LINE_D */
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_alarm;
    sigaction(SIGALRM, &sa, 0);
    struct itimerval it = {{0, 0}, {0, 100000}};
    setitimer(ITIMER_REAL, &it, 0);
    long slept = sleeper();
    printf("sleep=%ld alarms=%d\n", slept, alarms);
    phase(4);
    pthread_t a, b;
    pthread_create(&a, 0, worker, 0);
    pthread_create(&b, 0, worker, 0);
    pthread_join(a, 0);
    pthread_join(b, 0);
    printf("counter=%d expect=%d\n", counter, 2 * ITER);
    phase(5);
    return code_intact();
}
