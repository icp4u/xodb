#define _GNU_SOURCE 1
#define _FILE_OFFSET_BITS 64
#include "target_internal.h"
#include "xrt_files.h"
#include "check.h"
#include <elf.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>

static struct xrt_file_view *view(const char *path, int fd, void *mapping)
{
    struct stat st; CHECK(!fstat(fd, &st));
    struct xrt_target *target = calloc(1, sizeof *target); CHECK(target);
    target->pid = getpid();
    const struct xrt_file_request request = {.kind = XRT_FILE_MAPPED, .mapping = {
        .start = (uintptr_t)mapping, .end = (uintptr_t)mapping + 4096,
        .device_major = major(st.st_dev), .device_minor = minor(st.st_dev),
        .inode = st.st_ino, .path = path}};
    struct xrt_file_view *result = NULL;
    CHECK(xrt_target_file_view_open(target, &request, &result) == XRT_OK);
    /* A local view retains only its pinned descriptor, never this target. */
    free(target);
    return result;
}
static enum xrt_status wait_job(struct xrt_symbol_job *job, int *fd, uint64_t *resident)
{
    for (unsigned i = 0; i < 10000; ++i) {
        enum xrt_status status = xrt_symbol_job_poll(job, fd, resident);
        if (status != XRT_DISCOVERY_PENDING) return status;
        CHECK(*fd == -1);
        usleep(1000);
    }
    CHECK(!"symbol job failed to complete"); return XRT_INVALID_STATE;
}
/* Fast lane: an ordinary image with a large code extent retains only its
 * symbol/name/link sections. A source change must publish no partial result. */
static uint64_t local_projection(void)
{
    int fd = memfd_create("local-symbol-fixture", MFD_CLOEXEC);
    CHECK(fd >= 0 && ftruncate(fd, 32 * 1024 * 1024) == 0);
    const char names[] = "\0.shstrtab\0.symtab\0.strtab\0.text\0.gnu_debuglink\0";
    const char strings[] = "\0named_function\0";
    const char debuglink[16] = "owned.debug\0\0\0\0";
    Elf64_Ehdr eh = {.e_type=ET_DYN, .e_machine=EM_X86_64, .e_version=EV_CURRENT,
        .e_ehsize=sizeof eh, .e_shoff=128, .e_shentsize=sizeof(Elf64_Shdr), .e_shnum=6, .e_shstrndx=1};
    memcpy(eh.e_ident, ELFMAG, SELFMAG); eh.e_ident[EI_CLASS]=ELFCLASS64;
    eh.e_ident[EI_DATA]=__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__ ? ELFDATA2LSB : ELFDATA2MSB;
    eh.e_ident[EI_VERSION]=EV_CURRENT;
    Elf64_Shdr sections[6] = {0};
    sections[1]=(Elf64_Shdr){.sh_name=1,.sh_type=SHT_STRTAB,.sh_offset=512,.sh_size=sizeof names};
    sections[2]=(Elf64_Shdr){.sh_name=11,.sh_type=SHT_SYMTAB,.sh_offset=1024,.sh_size=48,.sh_link=3,.sh_entsize=24};
    sections[3]=(Elf64_Shdr){.sh_name=19,.sh_type=SHT_STRTAB,.sh_offset=1088,.sh_size=sizeof strings};
    sections[4]=(Elf64_Shdr){.sh_name=27,.sh_type=SHT_PROGBITS,.sh_offset=4096,.sh_size=32*1024*1024-4096};
    sections[5]=(Elf64_Shdr){.sh_name=33,.sh_type=SHT_PROGBITS,.sh_offset=1152,.sh_size=sizeof debuglink};
    Elf64_Sym symbols[2] = {{0},{.st_name=1,.st_shndx=4,.st_value=0x1234}};
    CHECK(pwrite(fd,&eh,sizeof eh,0)==sizeof eh);
    CHECK(pwrite(fd,sections,sizeof sections,128)==sizeof sections);
    CHECK(pwrite(fd,names,sizeof names,512)==sizeof names);
    CHECK(pwrite(fd,symbols,sizeof symbols,1024)==sizeof symbols);
    CHECK(pwrite(fd,strings,sizeof strings,1088)==sizeof strings);
    CHECK(pwrite(fd,debuglink,sizeof debuglink,1152)==sizeof debuglink);
    CHECK(pwrite(fd,"CODE NOT SYMBOLS",16,4096)==16);
    void *mapping=mmap(NULL,4096,PROT_READ,MAP_PRIVATE,fd,0); CHECK(mapping!=MAP_FAILED);
    char path[64]; snprintf(path,sizeof path,"/proc/self/fd/%d",fd);
    struct xrt_file_view *pinned=view(path,fd,mapping);
    int output=-1; uint64_t resident=0;
    CHECK(xrt_local_symbol_file(pinned,&output,&resident)==XRT_OK && output>=0 && resident<4096);
    CHECK((fcntl(output,F_GET_SEALS)&F_SEAL_WRITE)!=0);
    char got[sizeof names];
    CHECK(pread(output,got,sizeof names,512)==sizeof names && !memcmp(got,names,sizeof names));
    CHECK(pread(output,got,sizeof debuglink,1152)==sizeof debuglink && !memcmp(got,debuglink,sizeof debuglink));
    CHECK(pread(output,got,16,4096)==16);
    for (unsigned i=0;i<16;++i) CHECK(got[i]==0);
    struct stat stat; CHECK(fstat(output,&stat)==0 && stat.st_size==32*1024*1024 && stat.st_blocks*512<16384);
    CHECK(close(output)==0);
    const uint64_t retained=resident;
    CHECK(pwrite(fd,"X",1,4096)==1);
    CHECK(xrt_local_symbol_file(pinned,&output,&resident)==XRT_FILE_CHANGED && output==-1 && resident==0);
    CHECK(xrt_file_view_close(pinned)==XRT_OK);
    CHECK(munmap(mapping,4096)==0 && close(fd)==0);
    return retained;
}
int main(int argc, char **argv)
{
    char path[4096];
    const char *tmp=getenv("TMPDIR");
    int n=snprintf(path,sizeof path,"%s/xodb-symbol-job-XXXXXX",tmp && *tmp ? tmp : "/tmp");
    CHECK(n>0 && (size_t)n<sizeof path);
    const uint64_t far = UINT64_C(5) * 1024 * 1024 * 1024;
    int source = mkstemp(path); CHECK(source >= 0);
    CHECK(!ftruncate(source, (off_t)(far + 4096)));
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
    CHECK(pwrite(source,&eh,sizeof eh,0)==sizeof eh);
    CHECK(pwrite(source,sections,sizeof sections,128)==sizeof sections);
    CHECK(pwrite(source,symbols,sizeof symbols,(off_t)far)==sizeof symbols);
    CHECK(pwrite(source,"\0named_function\0",16,(off_t)(far+128))==16);
    CHECK(pwrite(source,"NOT SYMBOL DATA!",16,512)==16);
    void *mapping = mmap(NULL,4096,PROT_READ,MAP_PRIVATE,source,0); CHECK(mapping!=MAP_FAILED);
    struct xrt_symbol_job *job = NULL;
    CHECK(xrt_symbol_job_start(view(path,source,mapping), &job)==XRT_OK);
    int output = -1; uint64_t resident = 0;
    CHECK(wait_job(job,&output,&resident)==XRT_OK && output>=0 && resident<1024);
    int saved_output=output;
    int seals=fcntl(output,F_GET_SEALS); CHECK((seals&(F_SEAL_WRITE|F_SEAL_GROW|F_SEAL_SHRINK))==(F_SEAL_WRITE|F_SEAL_GROW|F_SEAL_SHRINK));
    unsigned char bytes[16];
    CHECK(pread(output,bytes,16,(off_t)(far+128))==16 && !memcmp(bytes,"\0named_function\0",16));
    CHECK(pread(output,bytes,16,512)==16);
    for (unsigned i=0;i<16;++i) CHECK(!bytes[i]);
    CHECK(xrt_symbol_job_poll(job,&output,&resident)==XRT_INVALID_STATE && output==-1);
    /* The previously returned fd remains caller-owned after job teardown. */
    xrt_symbol_job_destroy(job);
    CHECK(fcntl(saved_output,F_GETFD)>=0); close(saved_output);
    for (unsigned i=0;i<16;++i) {
        CHECK(xrt_symbol_job_start(view(path,source,mapping), &job)==XRT_OK);
        xrt_symbol_job_cancel(job);
        CHECK(xrt_symbol_job_poll(job,&output,&resident)==XRT_DISCOVERY_CANCELLED && output==-1);
        xrt_symbol_job_destroy(job);
    }
    struct xrt_file_view *pinned=view(path,source,mapping);
    CHECK(pwrite(source,"X",1,512)==1);
    CHECK(xrt_symbol_job_start(pinned,&job)==XRT_OK);
    CHECK(wait_job(job,&output,&resident)==XRT_FILE_CHANGED && output==-1);
    xrt_symbol_job_destroy(job);
    sections[1].sh_link=4;
    CHECK(pwrite(source,sections,sizeof sections,128)==sizeof sections);
    CHECK(xrt_symbol_job_start(view(path,source,mapping),&job)==XRT_OK);
    CHECK(wait_job(job,&output,&resident)==XRT_INVALID_ARGUMENT && output==-1);
    xrt_symbol_job_destroy(job);
    sections[1].sh_link=2; sections[2].sh_size=65*1024*1024;
    CHECK(ftruncate(source,(off_t)(far+128+sections[2].sh_size))==0);
    CHECK(pwrite(source,sections,sizeof sections,128)==sizeof sections);
    CHECK(xrt_symbol_job_start(view(path,source,mapping),&job)==XRT_OK);
    CHECK(wait_job(job,&output,&resident)==XRT_FILE_LIMIT && output==-1);
    xrt_symbol_job_destroy(job);
    munmap(mapping,4096); close(source); CHECK(!unlink(path));
    const uint64_t local_bytes = local_projection();
    if (argc == 2 && strcmp(argv[1], "--wrong-result") == 0) CHECK(local_bytes == 32 * 1024 * 1024);
    puts("symbol job: sparse 5 GiB, sealing, one-shot ownership, cancellation, identity change, malformed link and quota pass");
}
