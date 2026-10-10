#define _GNU_SOURCE 1
#include <sys/prctl.h>
#include <unistd.h>
#include <stdio.h>
int main(int argc,char **argv) {
    if(argc<2)return 90;
    if(prctl(PR_SET_PTRACER,PR_SET_PTRACER_ANY,0,0,0)){perror("owned ptracer");return 91;}
    execvp(argv[1],argv+1);perror("owned exec");return 92;
}
