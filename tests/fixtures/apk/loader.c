// Owned native fixture: mmap two independent PT_LOAD sets from one APK inode.
// Libraries have no imports or dynamic relocations; this is not a general linker.
#define _GNU_SOURCE
#include <elf.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>
static int (*load(int fd, off_t offset))(int) {
    Elf64_Ehdr eh;
    if (pread(fd, &eh, sizeof eh, offset) != sizeof eh || eh.e_phnum > 32) exit(2);
    Elf64_Phdr ph[32];
    size_t size = eh.e_phnum * sizeof ph[0];
    if (pread(fd, ph, size, offset + eh.e_phoff) != (ssize_t)size) exit(3);
    size_t page = sysconf(_SC_PAGESIZE), end = 0;
    for (unsigned i = 0; i < eh.e_phnum; ++i)
        if (ph[i].p_type == PT_LOAD && end < ph[i].p_vaddr + ph[i].p_memsz)
            end = ph[i].p_vaddr + ph[i].p_memsz;
    end = (end + page - 1) & -page;
    char *base = mmap(0, end, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (base == MAP_FAILED) exit(4);
    for (unsigned i = 0; i < eh.e_phnum; ++i) {
        Elf64_Phdr *p = &ph[i];
        if (p->p_type != PT_LOAD || !p->p_filesz) continue;
        if (p->p_memsz != p->p_filesz) exit(5);
        size_t low = p->p_vaddr & -page, lead = p->p_vaddr - low;
        size_t bytes = (lead + p->p_filesz + page - 1) & -page;
        int prot = (p->p_flags & PF_R ? PROT_READ : 0) | (p->p_flags & PF_W ? PROT_WRITE : 0) | (p->p_flags & PF_X ? PROT_EXEC : 0);
        if (mmap(base + low, bytes, prot, MAP_PRIVATE | MAP_FIXED, fd, offset + (p->p_offset & -page)) == MAP_FAILED) exit(6);
    }
    return (void *)(base + eh.e_entry);
}
__attribute__((noinline)) void fixture_ready(void) { __asm__ volatile(""); }
int main(int argc, char **argv) {
    if (argc != 4) return 1;
    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) return 1;
    int (*left)(int) = load(fd, strtoull(argv[2], 0, 0));
    int (*right)(int) = load(fd, strtoull(argv[3], 0, 0));
    close(fd);
    fixture_ready();
    for (int i = 0; i < 100; ++i) { left(5); right(3); usleep(10000); }
    return 0;
}
