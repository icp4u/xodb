// T01 ELF fixture: one of each symbol shape the reader has to classify.
// Built several ways by build.sh; run with any argument to report runtime
// addresses and this process's mappings for the load-bias check in compare.py.
#include <stdio.h>

int libfix_add(int, int); // undefined here, defined in libfix.so
int libfix_plain(int);
void libfix_report(void);
int dup_helper(int);

int fixture_global = 41; // .data
int fixture_zeroed[16]; // .bss
const char fixture_text[] = "xodb"; // .rodata
__thread int fixture_tls = 7; // STT_TLS: the value is a TLS offset, not an address
static int counter = 1; // dup.c has another local `counter`
int (*fixture_fnptr)(int);

__attribute__((weak)) int fixture_weak(void) { return 1; }
__attribute__((visibility("hidden"))) int fixture_hidden(void) { return 2; }
static __attribute__((noinline)) int helper(int x) { return x + counter; } // dup.c has another local `helper`

// SHN_ABS symbol, and a function label with no .size followed by more code.
__asm__(".globl fixture_abs\n.set fixture_abs, 0x1234\n");
__asm__(".text\n.globl fixture_label\n.type fixture_label,@function\nfixture_label:\n\tret\n\tnop\n\tnop\n\tnop\n");
void fixture_label(void);

int main(int argc, char **argv) {
    (void)argv;
    fixture_fnptr = libfix_plain; // without PIE this needs a canonical PLT entry: undefined, nonzero value
    fixture_label();
    int r = helper(argc) + dup_helper(argc) + libfix_add(fixture_global, fixture_tls) + fixture_weak() + fixture_hidden() + fixture_fnptr(1) + fixture_zeroed[0] + fixture_text[0];
    if (argc < 2) return r == 0;
    printf("sym main %p\n", (void *)main);
    printf("sym helper %p\n", (void *)helper);
    printf("sym fixture_label %p\n", (void *)fixture_label);
    printf("sym fixture_global %p\n", (void *)&fixture_global);
    printf("sym fixture_zeroed %p\n", (void *)fixture_zeroed);
    printf("sym counter %p\n", (void *)&counter);
    libfix_report();
    FILE *maps = fopen("/proc/self/maps", "r");
    if (!maps) return 2;
    char line[4096];
    while (fgets(line, sizeof line, maps)) printf("map %s", line);
    fclose(maps);
    return 0;
}
