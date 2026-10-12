/* Two cooperative interpreter images, each running on its own native thread.
 * Each function keeps a different local and blocks on the fixture's stdin.
 * No image or process mutation: the caller supplies two private library copies. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <link.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>
struct task { void *image; const char *language, *name; int held; char **envp; };
static void fail(const char *what) { fprintf(stderr, "%s: %s\n", what, dlerror()); exit(2); }
static void *execute(void *opaque) {
    struct task *t = opaque;
    char oracle[128];
    int n = snprintf(oracle, sizeof oracle, "{\"name\":\"%s\",\"tid\":%ld,\"held\":%d}\n", t->name, syscall(SYS_gettid), t->held);
    if (write(1, oracle, n) != n) exit(2);
    char script[512];
    if (!strcmp(t->language, "python")) {
        void (*init)(void) = dlsym(t->image, "Py_Initialize");
        int (*run)(const char *) = dlsym(t->image, "PyRun_SimpleString");
        if (!init || !run) fail("Python API");
        snprintf(script, sizeof script, "import sys\ndef %s():\n    held = %d\n    print('ready', flush=True)\n    sys.stdin.readline()\n    return held\n%s()\n", t->name, t->held, t->name);
        init();
        if (run(script)) exit(2);
    } else {
        void (*init)(int *, char ***, char ***) = dlsym(t->image, "Perl_sys_init3");
        void *(*alloc)(void) = dlsym(t->image, "perl_alloc");
        void (*construct)(void *) = dlsym(t->image, "perl_construct");
        int (*parse)(void *, void *, int, char **, char **) = dlsym(t->image, "perl_parse");
        int (*run)(void *) = dlsym(t->image, "perl_run");
        if (!init || !alloc || !construct || !parse || !run) fail("Perl API");
        snprintf(script, sizeof script, "$|=1; sub %s { my $held = %d; print qq(ready\\n); my $line = <STDIN>; return $held; } %s();", t->name, t->held, t->name);
        char *args[] = {"thread-interpreters", "-e", script, NULL};
        char **vector = args, **environment = t->envp;
        int count = 3;
        init(&count, &vector, &environment);
        void *perl = alloc();
        construct(perl);
        if (parse(perl, NULL, count, vector, NULL) || run(perl)) exit(2);
    }
    return NULL;
}
int main(int argc, char **argv, char **envp) {
    if (argc != 4) return 2;
    void *one = dlopen(argv[2], RTLD_NOW | RTLD_LOCAL);
    void *two = dlmopen(LM_ID_NEWLM, argv[3], RTLD_NOW | RTLD_LOCAL);
    if (!one || !two) fail("load interpreter");
    struct task tasks[] = {{one, argv[1], "one", 101, envp}, {two, argv[1], "two", 202, envp}};
    pthread_t threads[2];
    for (int i = 0; i < 2; ++i) if (pthread_create(&threads[i], NULL, execute, &tasks[i])) return 2;
    for (int i = 0; i < 2; ++i) if (pthread_join(threads[i], NULL)) return 2;
    return 0;
}
