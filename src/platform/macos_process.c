/* Keep Darwin's Mach-containing spawn.h out of Zig translate-c. */
#include <spawn.h>
#include <crt_externs.h>
#include <stdint.h>
#include <unistd.h>
#include <signal.h>

int xrt_spawn_owned_helper(int32_t *pid, int (*create)(int32_t *pid, void *context), void *context);

struct ssh_spawn {
    const char *const *argv;
    posix_spawn_file_actions_t *actions;
    posix_spawnattr_t *attr;
};

static int ssh_create(int32_t *pid, void *context)
{
    struct ssh_spawn *spawn = context;
    pid_t child = 0;
    int status = posix_spawnp(&child, "ssh", spawn->actions, spawn->attr, (char *const *)spawn->argv, *_NSGetEnviron());
    if (status)
        return status;
    *pid = (int32_t)child;
    return 0;
}

void xodb_macos_process_signals(void)
{
    signal(SIGPIPE, SIG_IGN);
    /* An inherited SIG_IGN would auto-reap children, so a helper pid could be
     * reused between waitpid() and the confirmed-detach SIGTERM. Default
     * disposition keeps every exited helper a zombie until we reap it. */
    signal(SIGCHLD, SIG_DFL);
}

int xodb_macos_spawn_ssh(const char *const *argv, int parent, int child, pid_t *pid)
{
    posix_spawn_file_actions_t actions;
    int status = posix_spawn_file_actions_init(&actions);
    if (status) return status;
    posix_spawnattr_t attr;
    status = posix_spawnattr_init(&attr);
    if (status) { posix_spawn_file_actions_destroy(&actions); return status; }
    status = posix_spawnattr_setflags(&attr, POSIX_SPAWN_CLOEXEC_DEFAULT);
    if (status) goto done;
    if (!(status = posix_spawn_file_actions_adddup2(&actions, child, STDIN_FILENO)) &&
        !(status = posix_spawn_file_actions_adddup2(&actions, child, STDOUT_FILENO)) &&
        !(status = posix_spawn_file_actions_addclose(&actions, parent)) &&
        !(status = posix_spawn_file_actions_addclose(&actions, child)))
        {
            int32_t spawned = 0;
            struct ssh_spawn spawn = { argv, &actions, &attr };
            status = xrt_spawn_owned_helper(&spawned, ssh_create, &spawn);
            if (!status)
                *pid = (pid_t)spawned;
        }
done:
    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&actions);
    return status;
}
