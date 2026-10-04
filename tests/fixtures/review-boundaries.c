#define _GNU_SOURCE
#include <dlfcn.h>
#include <signal.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

typedef struct Node Node;
struct Node { Node *next; int value; };
struct Node tail = {0, 22}, head = {&tail, 11};
enum Mode { FIRST = 1, SECOND = 2 };
volatile enum Mode mode = FIRST;
unsigned char *boundary;
void *first_func, *second_func;
__attribute__((noinline)) void after_unmap(void) { __asm__ volatile("" ::: "memory"); }

__attribute__((noinline)) void ready(struct Node *p, const Node *alias) {
    volatile enum Mode local_mode = FIRST;
    __asm__ volatile("" : : "r"(p), "r"(alias), "r"(local_mode)); /* ready-line */
    mode = SECOND;
    __asm__ volatile("" : : "r"(local_mode));
}
int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "signal")) { raise(SIGPIPE); return 42; }
    long page = sysconf(_SC_PAGESIZE);
    boundary = mmap(0, 2 * page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (boundary == MAP_FAILED || munmap(boundary + page, page)) return 2;
    boundary += page - 2;
    if (argc > 2 && !strcmp(argv[1], "library")) {
        void *a = dlmopen(LM_ID_NEWLM, argv[2], RTLD_NOW);
        void *b = dlmopen(LM_ID_NEWLM, argv[2], RTLD_NOW);
        if (!a || !b) return 3;
        first_func = dlsym(a, "library_func"); second_func = dlsym(b, "library_func");
        if (!first_func || !second_func || first_func == second_func) return 4;
    }
    ready(&head, &head);
    if (argc > 1 && !strcmp(argv[1], "unmap")) {
        if (munmap(boundary - page + 2, page)) return 5;
        after_unmap();
    }
    if (argc > 1 && !strcmp(argv[1], "exec")) execl("/bin/true", "true", (char *)0);
    return 0;
}
