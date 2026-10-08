#define _GNU_SOURCE 1
#define _FILE_OFFSET_BITS 64
#include "target_internal.h"
#include "xrt_files.h"
#include <assert.h>
#include <elf.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>

static struct xrt_file_view *view(const char *path, int fd, void *mapping)
{
    struct stat st; assert(!fstat(fd, &st));
    struct xrt_target *target = calloc(1, sizeof *target); assert(target);
    target->pid = getpid();
    const struct xrt_file_request request = {.kind = XRT_FILE_MAPPED, .mapping = {
        .start = (uintptr_t)mapping, .end = (uintptr_t)mapping + 4096,
        .device_major = major(st.st_dev), .device_minor = minor(st.st_dev),
        .inode = st.st_ino, .path = path}};
    struct xrt_file_view *result = NULL;
    assert(xrt_target_file_view_open(target, &request, &result) == XRT_OK);
    /* A local view retains only its pinned descriptor, never this target. */
    free(target);
    return result;
}
static enum xrt_status wait_job(struct xrt_symbol_job *job, int *fd, uint64_t *resident)
{
    for (unsigned i = 0; i < 10000; ++i) {
        enum xrt_status status = xrt_symbol_job_poll(job, fd, resident);
        if (status != XRT_DISCOVERY_PENDING) return status;
        assert(*fd == -1);
        usleep(1000);
    }
    assert(!"symbol job failed to complete"); return XRT_INVALID_STATE;
}
int main(void)
{
    char path[4096];
    const char *tmp=getenv("TMPDIR");
    int n=snprintf(path,sizeof path,"%s/xodb-symbol-job-XXXXXX",tmp && *tmp ? tmp : "/tmp");
    assert(n>0 && (size_t)n<sizeof path);
    const uint64_t far = UINT64_C(5) * 1024 * 1024 * 1024;
    int source = mkstemp(path); assert(source >= 0);
    assert(!ftruncate(source, (off_t)(far + 4096)));
    Elf64_Ehdr eh = {.e_type=ET_DYN, .e_machine=EM_X86_64, .e_version=EV_CURRENT,
        .e_ehsize=sizeof eh, .e_shoff=128, .e_shentsize=sizeof(Elf64_Shdr), .e_shnum=4};
    memcpy(eh.e_ident, ELFMAG, SELFMAG); eh.e_ident[EI_CLASS]=ELFCLASS64;
    eh.e_ident[EI_DATA]=__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__ ? ELFDATA2LSB : ELFDATA2MSB;
    eh.e_ident[EI_VERSION]=EV_CURRENT;
    Elf64_Shdr sections[4] = {0};
    sections[1]=(Elf64_Shdr){.sh_type=SHT_SYMTAB,.sh_offset=far,.sh_size=48,.sh_link=2,.sh_entsize=24};
    sections[2]=(Elf64_Shdr){.sh_type=SHT_STRTAB,.sh_offset=far+128,.sh_size=16};
    sections[3]=(Elf64_Shdr){.sh_type=SHT_PROGBITS,.sh_offset=512,.sh_size=16};
    Elf64_Sym symbols[2] = {{0},{.st_name=1,.st_shndx=3,.st_value=0x1234}};
    assert(pwrite(source,&eh,sizeof eh,0)==sizeof eh);
    assert(pwrite(source,sections,sizeof sections,128)==sizeof sections);
    assert(pwrite(source,symbols,sizeof symbols,(off_t)far)==sizeof symbols);
    assert(pwrite(source,"\0named_function\0",16,(off_t)(far+128))==16);
    assert(pwrite(source,"NOT SYMBOL DATA!",16,512)==16);
    void *mapping = mmap(NULL,4096,PROT_READ,MAP_PRIVATE,source,0); assert(mapping!=MAP_FAILED);
    struct xrt_symbol_job *job = NULL;
    assert(xrt_symbol_job_start(view(path,source,mapping), &job)==XRT_OK);
    int output = -1; uint64_t resident = 0;
    assert(wait_job(job,&output,&resident)==XRT_OK && output>=0 && resident<1024);
    int saved_output=output;
    int seals=fcntl(output,F_GET_SEALS); assert((seals&(F_SEAL_WRITE|F_SEAL_GROW|F_SEAL_SHRINK))==(F_SEAL_WRITE|F_SEAL_GROW|F_SEAL_SHRINK));
    unsigned char bytes[16];
    assert(pread(output,bytes,16,(off_t)(far+128))==16 && !memcmp(bytes,"\0named_function\0",16));
    assert(pread(output,bytes,16,512)==16);
    for (unsigned i=0;i<16;++i) assert(!bytes[i]);
    assert(xrt_symbol_job_poll(job,&output,&resident)==XRT_INVALID_STATE && output==-1);
    /* The previously returned fd remains caller-owned after job teardown. */
    xrt_symbol_job_destroy(job);
    assert(fcntl(saved_output,F_GETFD)>=0); close(saved_output);
    for (unsigned i=0;i<16;++i) {
        assert(xrt_symbol_job_start(view(path,source,mapping), &job)==XRT_OK);
        xrt_symbol_job_cancel(job);
        assert(xrt_symbol_job_poll(job,&output,&resident)==XRT_DISCOVERY_CANCELLED && output==-1);
        xrt_symbol_job_destroy(job);
    }
    struct xrt_file_view *pinned=view(path,source,mapping);
    assert(pwrite(source,"X",1,512)==1);
    assert(xrt_symbol_job_start(pinned,&job)==XRT_OK);
    assert(wait_job(job,&output,&resident)==XRT_FILE_CHANGED && output==-1);
    xrt_symbol_job_destroy(job);
    sections[1].sh_link=4;
    assert(pwrite(source,sections,sizeof sections,128)==sizeof sections);
    assert(xrt_symbol_job_start(view(path,source,mapping),&job)==XRT_OK);
    assert(wait_job(job,&output,&resident)==XRT_INVALID_ARGUMENT && output==-1);
    xrt_symbol_job_destroy(job);
    sections[1].sh_link=2; sections[2].sh_size=65*1024*1024;
    assert(ftruncate(source,(off_t)(far+128+sections[2].sh_size))==0);
    assert(pwrite(source,sections,sizeof sections,128)==sizeof sections);
    assert(xrt_symbol_job_start(view(path,source,mapping),&job)==XRT_OK);
    assert(wait_job(job,&output,&resident)==XRT_FILE_LIMIT && output==-1);
    xrt_symbol_job_destroy(job);
    munmap(mapping,4096); close(source); assert(!unlink(path));
    puts("symbol job: sparse 5 GiB, sealing, one-shot ownership, cancellation, identity change, malformed link and quota pass");
}
