#define _GNU_SOURCE 1
#include "elf_symbols.h"
#include "check.h"
#include <elf.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
struct input { int fd; size_t bytes; bool refuse; };
static enum xrt_status read_at(void *ctx, uint64_t at, void *out, size_t n)
{
    struct input *in = ctx;
    if (in->refuse) return XRT_DISCOVERY_PENDING;
    in->bytes += n;
    return pread(in->fd, out, n, (off_t)at) == (ssize_t)n ? XRT_OK : XRT_FILE_CHANGED;
}
static void put(unsigned char *p, uint64_t value, unsigned n, bool little)
{
    for (unsigned i = 0; i < n; ++i) { p[little ? i : n-i-1] = (unsigned char)value; value >>= 8; }
}
static void one(bool wide, bool wrong_index)
{
    const uint64_t size = UINT64_C(512) * 1024 * 1024, shoff = size-4096, symoff = size-8192;
    const unsigned hs = wide ? 64 : 52, ss = wide ? 64 : 40, syms = wide ? 24 : 16;
    unsigned char header[64] = {0}, sections[256] = {0}, symbols[48] = {0};
    memcpy(header, ELFMAG, SELFMAG); header[4] = wide ? 2 : 1; header[5] = wide ? 1 : 2; header[6] = 1;
    put(header+16, ET_DYN, 2, wide); put(header+18, wide ? EM_X86_64 : EM_68K, 2, wide);
    put(header+20, 1, 4, wide); put(header+(wide ? 52 : 40), hs, 2, wide);
    put(header+(wide ? 40 : 32), shoff, wide ? 8 : 4, wide);
    put(header+(wide ? 58 : 46), ss, 2, wide);
    put(header+(wide ? 60 : 48), 4, 2, wide);
    put(header+(wide ? 62 : 50), 2, 2, wide);
    for (unsigned i = 1; i < 4; ++i) {
        unsigned char *s = sections+i*ss;
        put(s+4, i==1 ? SHT_SYMTAB : i==2 ? SHT_STRTAB : SHT_PROGBITS, 4, wide);
        put(s+(wide ? 24 : 16), i==1 ? symoff : i==2 ? symoff+128 : 4096, wide ? 8 : 4, wide);
        put(s+(wide ? 32 : 20), i==1 ? 2*syms : 16, wide ? 8 : 4, wide);
    }
    put(sections+ss+(wide ? 40 : 24), 2, 4, wide);
    put(sections+ss+(wide ? 56 : 36), syms, wide ? 8 : 4, wide);
    put(symbols+syms, 1, 4, wide);
    put(symbols+syms+(wide ? 6 : 14), 3, 2, wide);
    int input=memfd_create("symbol-input",0), output=memfd_create("symbol-output",0);
    CHECK(input>=0 && output>=0 && !ftruncate(input,(off_t)size) && !ftruncate(output,(off_t)size));
    CHECK(pwrite(input,header,hs,0)==(ssize_t)hs);
    CHECK(pwrite(input,sections,4*ss,(off_t)shoff)==(ssize_t)(4*ss));
    CHECK(pwrite(input,symbols,2*syms,(off_t)symoff)==(ssize_t)(2*syms));
    CHECK(pwrite(input,"\0named_function\0",16,(off_t)(symoff+128))==16);
    CHECK(pwrite(input,"NOT SYMBOL DATA!",16,4096)==16);
    struct input in={input,0,false};
    CHECK(xrt_elf_symbols(read_at,&in,output,size)==XRT_OK);
    CHECK(in.bytes<1024);
    unsigned char got[16];
    CHECK(pread(output,got,16,(off_t)(symoff+128))==16 && !memcmp(got,"\0named_function\0",16));
    CHECK(pread(output,got,16,4096)==16);
    for (unsigned i=0;i<16;++i) CHECK(got[i]==0);
    if (wrong_index) put(header+(wide ? 62 : 50), 3, 2, wide);
    CHECK(pread(output,got,2,wide ? 62 : 50)==2 && !memcmp(got,header+(wide ? 62 : 50),2));
    in.refuse=true; CHECK(xrt_elf_symbols(read_at,&in,output,size)==XRT_DISCOVERY_PENDING); in.refuse=false;
    put(sections+ss+(wide ? 40 : 24), 4, 4, wide);
    CHECK(pwrite(input,sections,4*ss,(off_t)shoff)==(ssize_t)(4*ss));
    CHECK(xrt_elf_symbols(read_at,&in,output,size)==XRT_INVALID_ARGUMENT);
    put(sections+ss+(wide ? 40 : 24), 2, 4, wide);
    put(sections+2*ss+(wide ? 32 : 20), size, wide ? 8 : 4, wide);
    CHECK(pwrite(input,sections,4*ss,(off_t)shoff)==(ssize_t)(4*ss));
    CHECK(xrt_elf_symbols(read_at,&in,output,size)==XRT_INVALID_ARGUMENT);
    close(input);close(output);
}
int main(int argc, char **argv)
{
    const bool wrong_index=argc==2 && !strcmp(argv[1], "--wrong-result");
    one(true,wrong_index);one(false,wrong_index);
    puts("C sparse symbols: 512 MiB ELF64/ELF32, byte order, omitted code, bad links/ranges and policy refusal passed");
    return 0;
}
