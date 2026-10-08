#define _GNU_SOURCE 1
#include "xrt_source.h"
#include "xrt_remote.h"
#include "remote_internal.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    assert(argc==4);
    const char *command[]={argv[1],"--stdio",NULL};
    struct xrt_target *target;
    assert(xrt_target_remote(command,&target)==XRT_OK);
    const char *child[]={argv[2],NULL};
    assert(xrt_target_launch(target,child)==XRT_OK);
    int maps;
    assert(xrt_target_file(target,&(struct xrt_file_request){.kind=XRT_FILE_MAPS},&maps)==XRT_OK);
    FILE *file=fdopen(maps,"r"); assert(file);
    char line[16384],image[8192]={0};
    struct xrt_file_request request={.kind=XRT_FILE_MAPPED};
    while (fgets(line,sizeof line,file)) {
        unsigned long long start,end,offset,inode; unsigned major,minor; char mode[5],path[8192];
        if (sscanf(line,"%llx-%llx %4s %llx %x:%x %llu %8191[^\n]",&start,&end,mode,&offset,&major,&minor,&inode,path)!=8 || strcmp(path,argv[2])) continue;
        strcpy(image,path); request.mapping=(struct xrt_mapping){start,end,offset,major,minor,inode,image}; break;
    }
    fclose(file); assert(image[0]);
    file=fopen(argv[3],"r"); assert(file);
    unsigned count=0;
    while (fgets(line,sizeof line,file)) {
        char *path=strchr(line,'\t'); assert(path); *path++=0;
        size_t n=strlen(path); assert(n && path[n-1]=='\n'); path[n-1]=0;
        enum xrt_source_reason expected;
        if (!strcmp(line,"ready")) expected=XRT_SOURCE_READY;
        else if (!strcmp(line,"unsafe")) expected=XRT_SOURCE_PATH_UNSAFE;
        else if (!strcmp(line,"kernel")) expected=XRT_SOURCE_KERNEL_UNSUPPORTED;
        else if (!strcmp(line,"filesystem")) expected=XRT_SOURCE_FILESYSTEM_UNSUPPORTED;
        else if (!strcmp(line,"unavailable")) expected=XRT_SOURCE_UNAVAILABLE;
        else if (!strcmp(line,"not-listed")) expected=XRT_SOURCE_NOT_LISTED;
        else { assert(0); return 1; }
        struct xrt_source_file meta;
        enum xrt_status status=xrt_source_open(target,&request,path,&meta);
        if (meta.reason!=expected) fprintf(stderr,"case %u: wanted reason=%u got=%u status=%u\n",count,expected,meta.reason,status);
        assert(meta.reason==expected);
        if (expected==XRT_SOURCE_READY) {
            assert(status==XRT_OK && meta.identity.size>=0 && meta.identity.size<=XRT_SOURCE_MAX);
            unsigned char bytes[64]; size_t size=(uint64_t)meta.identity.size<sizeof bytes?(size_t)meta.identity.size:sizeof bytes;
            assert(xrt_source_read(target,&meta,0,bytes,size)==XRT_OK);
            size_t returned=999;
            assert(xrt_remote_call(target,&(struct xrt_call){.op=XRT_RPC_FILE_READ,
                .args={meta.handle,(uint64_t)meta.identity.size,1},.out=bytes,.capacity=sizeof bytes,.length=&returned})==XRT_INVALID_ARGUMENT);
            assert(!returned);
            assert(xrt_source_close(target,&meta)==XRT_OK);
        } else assert(status==XRT_FILE_UNAVAILABLE && !meta.handle);
        printf("case %u: %s pass\n",++count,line);
    }
    fclose(file);
    assert(xrt_target_destroy(target)==XRT_OK);
    printf("Source confinement: %u cases passed\n",count);
    return 0;
}
