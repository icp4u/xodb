/* Private-display test only: make snapshot progress visible, then fail a spawn. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct start { void *(*run)(void *); void *arg; };
static void *delayed(void *opaque) {
    struct start saved = *(struct start *)opaque;
    free(opaque);
    usleep(100000);
    return saved.run(saved.arg);
}
int pthread_create(pthread_t *thread, const pthread_attr_t *attr,
                   void *(*run)(void *), void *arg) {
    int (*real_create)(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *) =
        dlsym(RTLD_NEXT, "pthread_create");
    const char *gate = getenv("XODB_TEST_FLAME_WORKER_GATE");
    char mode = 0;
    if (gate && !strcmp(program_invocation_short_name, "xodb")) {
        int fd = open(gate, O_RDONLY | O_CLOEXEC);
        if (fd >= 0) { (void)read(fd, &mode, 1); close(fd); }
    }
    if (mode == 'f') return EAGAIN;
    if (mode != 'd') return real_create(thread, attr, run, arg);
    struct start *saved = malloc(sizeof(*saved));
    if (!saved) return ENOMEM;
    *saved = (struct start){run, arg};
    int result = real_create(thread, attr, delayed, saved);
    if (result) free(saved);
    return result;
}
