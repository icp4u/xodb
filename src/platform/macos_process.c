/* Keep Darwin's Mach-containing spawn.h out of Zig translate-c. */
#include <spawn.h>
#include <crt_externs.h>
#include <unistd.h>
#include <signal.h>

void xodb_macos_ignore_sigpipe(void)
{
    signal(SIGPIPE, SIG_IGN);
}

int xodb_macos_spawn_ssh(const char *const *argv, int parent, int child, pid_t *pid)
{
    posix_spawn_file_actions_t actions;
    int status = posix_spawn_file_actions_init(&actions);
    if (status) return status;
    if (!(status = posix_spawn_file_actions_adddup2(&actions, child, STDIN_FILENO)) &&
        !(status = posix_spawn_file_actions_adddup2(&actions, child, STDOUT_FILENO)) &&
        !(status = posix_spawn_file_actions_addclose(&actions, parent)) &&
        !(status = posix_spawn_file_actions_addclose(&actions, child)))
        status = posix_spawnp(pid, "ssh", &actions, NULL, (char *const *)argv, *_NSGetEnviron());
    posix_spawn_file_actions_destroy(&actions);
    return status;
}
