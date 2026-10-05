#define _GNU_SOURCE 1
#include "xrt_remote.h"
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
static volatile sig_atomic_t stopping;
static void stop(int signal_number)
{
    (void)signal_number;
    stopping = 1;
}
int main(int argc, char **argv)
{
    if (argc != 2 || strcmp(argv[1], "--stdio")) {
        fputs("usage: xodb-agent --stdio\nPrivate C runtime agent; connect through xodb or "
              "authenticated SSH.\n",
              stderr);
        return 2;
    }
    if (xrt_process_save_launch_signals() != XRT_OK)
        return 1;
    struct sigaction action = {0};
    sigemptyset(&action.sa_mask);
    action.sa_handler = SIG_IGN;
    if (sigaction(SIGPIPE, &action, NULL))
        return 1;
    action.sa_handler = stop;
    if (sigaction(SIGINT, &action, NULL) || sigaction(SIGTERM, &action, NULL) ||
        sigaction(SIGHUP, &action, NULL))
        return 1;
    for (int fd = 0; fd < 2; ++fd) {
        int flags = fcntl(fd, F_GETFL);
        if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0)
            return 1;
    }
    return xrt_agent_serve(STDIN_FILENO, STDOUT_FILENO, &stopping);
}
