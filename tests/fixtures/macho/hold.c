/* Maps each file named on the command line read-only and stops, so a debugger
 * sees them as file-backed mappings. The files are data here, never code. */
#include <fcntl.h>
#include <stdio.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

__attribute__((noinline)) void macho_mapped(void) { __asm__ volatile("" ::: "memory"); }
int main(int argc, char **argv) {
    for (int i = 1; i < argc; ++i) {
        struct stat st;
        int fd = open(argv[i], O_RDONLY);
        if (fd < 0 || fstat(fd, &st) || st.st_size <= 0) return 2;
        if (mmap(NULL, 4096, PROT_READ, MAP_PRIVATE, fd, 0) == MAP_FAILED) return 3;
        close(fd);
    }
    macho_mapped();
    return 0;
}
