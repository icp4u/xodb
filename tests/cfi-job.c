#define _GNU_SOURCE 1
#include "../src/debug/metadata_job.h"
#include "../src/runtime/xrt_loader.h"
#include "../src/runtime/xrt_remote.h"
#include "../src/runtime/remote_internal.h"
#include "check.h"
#include <elfutils/libdw.h>
#include <fcntl.h>
#include <gelf.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <time.h>
#include <unistd.h>
static void ok(enum xrt_status s) { if(s!=XRT_OK)fprintf(stderr,"runtime status=%u\n",s);CHECK(s==XRT_OK); }
static void pause_briefly(void) { struct timespec t={.tv_nsec=1000000};nanosleep(&t,NULL); }
int main(int argc,char **argv) {
    CHECK(argc==4); /* image, agent or -, plain/cancel/mutation */
    int remote=strcmp(argv[2],"-")!=0,cancel=!strcmp(argv[3],"cancel"),mutation=!strcmp(argv[3],"mutation");
    int fd=open(argv[1],O_RDONLY|O_CLOEXEC);CHECK(fd>=0);struct stat st;CHECK(!fstat(fd,&st));
    struct xrt_target *target;
    if (remote) { const char *cmd[]={argv[2],"--stdio",NULL};ok(xrt_target_remote(cmd,&target)); }
    else target=xrt_target_create();
    CHECK(target);
    const char *cmd[]={argv[1],NULL};ok(xrt_target_launch(target,cmd));
    struct xrt_auxv aux;ok(xrt_target_auxv(target,&aux));
    CHECK(aux.main_phdr && aux.page_size==(uint64_t)sysconf(_SC_PAGESIZE));
    CHECK(aux.phnum && aux.phent && aux.entry);
    int maps;ok(xrt_target_file(target,&(struct xrt_file_request){.kind=XRT_FILE_MAPS},&maps));
    FILE *file=fdopen(maps,"r");CHECK(file);char *line=NULL;size_t capacity=0;
    struct xrt_file_request request={.kind=XRT_FILE_MAPPED};
    while (getline(&line,&capacity,file)>=0) {
        uint64_t low,high,offset,major_,minor_,inode;char permissions[5];
        if(sscanf(line,"%" SCNx64 "-%" SCNx64 " %4s %" SCNx64 " %" SCNx64 ":%" SCNx64 " %" SCNu64,
            &low,&high,permissions,&offset,&major_,&minor_,&inode)!=7)continue;
        if(aux.main_phdr<low || aux.main_phdr>=high)continue;
        CHECK(major_==major(st.st_dev) && minor_==minor(st.st_dev) && inode==st.st_ino);
        request.mapping=(struct xrt_mapping){low,high,offset,major_,minor_,inode,argv[1]};break;
    }
    free(line);fclose(file);CHECK(request.mapping.end);
    struct xrt_file_view *view;ok(xrt_target_file_view_open(target,&request,&view));
    struct xmd_job *job;
    int immediate=!strcmp(argv[3],"immediate") || !strcmp(argv[3],"wrong-result");
    CHECK((immediate ? xmd_start_cfi_local(view,&job) : xmd_start_cfi(view,&job))==XBO_OK);
    if(immediate) CHECK(xmd_join(job)==XBO_OK);
    if(!strcmp(argv[3],"wrong-result")) CHECK(xmd_join(job)==XBO_AGAIN);
    if(cancel)xmd_cancel(job);
    uint64_t start=xbo_now_ns(),max_poll=0,max_rpc=0;unsigned polls=0,rpcs=0;
    struct xmd_snapshot snapshot;
    for (;;) {
        uint64_t before=xbo_now_ns();xmd_poll(job,&snapshot);uint64_t elapsed=xbo_now_ns()-before;
        if(elapsed>max_poll)max_poll=elapsed;
        ++polls;
        CHECK(!snapshot.profile.fields);
        if(snapshot.state==XMD_READY || snapshot.state==XMD_CANCELLED || snapshot.state==XMD_FAILED)break;
        if(remote && rpcs<20) {
            before=xbo_now_ns();ok(xrt_remote_call(target,&(struct xrt_call){.op=XRT_RPC_VIEW}));
            elapsed=xbo_now_ns()-before;
            if(elapsed>max_rpc)max_rpc=elapsed;
            ++rpcs;
        }
        pause_briefly();CHECK(xbo_now_ns()-start<UINT64_C(120000000000));
    }
    while(xmd_join(job)==XBO_AGAIN)pause_briefly();
    unsigned char *bytes=NULL;size_t size=0;
    if(cancel)CHECK(xmd_cfi_result(job,&bytes,&size)==XBO_CANCELLED && !bytes && !size);
    else {
        if(snapshot.state!=XMD_READY)fprintf(stderr,"job failed %u %s\n",snapshot.status,snapshot.reason?snapshot.reason:"none");
        CHECK(snapshot.state==XMD_READY && snapshot.unwind.phase==5);
        CHECK(xmd_cfi_result(job,&bytes,&size)==XBO_OK);
        uint64_t bias;CHECK(xmd_mapping_bias(job,request.mapping.start,request.mapping.end,request.mapping.offset,aux.page_size,0,&bias)==XBO_OK);
        CHECK(elf_version(EV_CURRENT)!=EV_NONE);Elf *elf=elf_memory((char *)bytes,size);CHECK(elf);
        Dwarf_CFI *cfi=dwarf_getcfi_elf(elf);CHECK(cfi);Dwarf_Frame *frame=NULL;
        /* Kernel entry fact, with bias proved from the same mapped descriptor. */
        CHECK(aux.entry>=bias && !dwarf_cfi_addrframe(cfi,aux.entry-bias,&frame));
        free(frame);dwarf_cfi_end(cfi);elf_end(elf);
        if(mutation) {
            struct timespec times[]={st.st_atim,st.st_mtim};++times[1].tv_sec;CHECK(!futimens(fd,times));
            CHECK(xmd_cfi_result(job,&bytes,&size)==XBO_CHANGED && !bytes && !size);
            times[1]=st.st_mtim;CHECK(!futimens(fd,times));
            CHECK(xmd_cfi_result(job,&bytes,&size)==XBO_CHANGED);
        }
    }
    CHECK(max_poll<UINT64_C(100000000) && max_rpc<UINT64_C(500000000));
    printf("CFI job %s: polls=%u max_poll_ms=%.3f rpcs=%u max_rpc_ms=%.3f source_bytes=%" PRIu64 " retained=%" PRIu64 "\n",argv[3],polls,max_poll/1e6,rpcs,max_rpc/1e6,snapshot.source_bytes,snapshot.unwind.retained_bytes);
    xmd_destroy(job);ok(xrt_target_destroy(target));close(fd);return 0;
}
