/* Keep Darwin's Mach-containing spawn.h out of Zig translate-c. */
#include <spawn.h>
#include <crt_externs.h>
#include <unistd.h>
#include <signal.h>

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
        status = posix_spawnp(pid, "ssh", &actions, &attr, (char *const *)argv, *_NSGetEnviron());
done:
    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&actions);
    return status;
}
