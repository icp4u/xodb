#include <unistd.h>
#ifdef SYMBOL_LIBRARY
__attribute__((noinline, visibility("hidden")))
void sparse_symbol_hit(volatile unsigned *counter) { ++*counter; }
void sparse_entry(volatile unsigned *counter) { sparse_symbol_hit(counter); }
#else
#include <dlfcn.h>
/* Address-breakpoint restoration must not load this whole image under a
 * 128 KiB symbol-discovery budget. */
const unsigned char restart_data[256 * 1024] = {1};
volatile unsigned reached;
__attribute__((noinline)) void symbols_ready(void) { __asm__ volatile("" ::: "memory"); }
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *library = dlopen(argv[1], RTLD_NOW);
    if (!library) return 3;
    void (*entry)(volatile unsigned *) = dlsym(library, "sparse_entry");
    if (!entry) return 4;
    symbols_ready();
    for (;;) { entry(&reached); usleep(10000); }
}
#endif
