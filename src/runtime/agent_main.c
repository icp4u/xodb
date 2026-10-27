#define _GNU_SOURCE 1
#include "xrt_remote.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static volatile sig_atomic_t stopping;
static void stop(int signal_number)
{
    (void)signal_number;
    stopping = 1;
}
static void usage(void)
{
    fputs("usage: xodb-agent --stdio\nPrivate C runtime agent; connect through xodb or "
          "authenticated SSH.\n",
          stderr);
}
static int decimal_u32(const char *text, uint32_t *out)
{
    if (!text || !*text || text[0] == '+' || text[0] == '-')
        return -1;
    errno = 0;
    char *end = NULL;
    unsigned long long value = strtoull(text, &end, 10);
    if (errno || end == text || *end || value > UINT32_MAX)
        return -1;
    *out = (uint32_t)value;
    return 0;
}
int main(int argc, char **argv)
{
    bool stdio = false;
    int saw_slots = 0, saw_next = 0;
    uint32_t file_slots = 0, next_file = 0;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--stdio")) {
            if (stdio) {
                usage();
                return 2;
            }
            stdio = true;
            continue;
        }
        const int slots_flag = !strcmp(argv[i], "--file-slots");
        const int next_flag = !strcmp(argv[i], "--next-file");
        if (!slots_flag && !next_flag) {
            usage();
            return 2;
        }
        if (i + 1 >= argc || (slots_flag && saw_slots) || (next_flag && saw_next)) {
            usage();
            return 2;
        }
        uint32_t value = 0;
        if (decimal_u32(argv[++i], &value) || (slots_flag && value == 0)) {
            usage();
            return 2;
        }
        if (slots_flag) {
            saw_slots = 1;
            file_slots = value;
        } else {
            saw_next = 1;
            next_file = value;
        }
    }
    if (!stdio) {
        usage();
        return 2;
    }
    if (saw_slots && xrt_agent_configure_file_slots(file_slots))
        return 1;
    if (saw_next)
        xrt_agent_configure_next_file(next_file);
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
