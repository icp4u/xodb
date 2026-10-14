#define _GNU_SOURCE 1
#include "xrt_log.h"
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#define UNREAD 127
signed char xrt_log_levels[XRT_LOG_TOPICS] = {
    UNREAD, UNREAD, UNREAD, UNREAD, UNREAD, UNREAD, UNREAD, UNREAD, UNREAD, UNREAD, UNREAD,
};
static const char *const levels[] = {"error", "warn", "info", "debug", "trace"};
static const char *const topics[XRT_LOG_TOPICS] = {
    "render", "window", "runtime", "agent", "session", "mcp", "sidecar", "semq", "overview", "redot", "profile",
};
static pthread_once_t once = PTHREAD_ONCE_INIT;
static int log_fd = STDERR_FILENO;
static struct timespec epoch;
static int named(const char *const *names, int count, const char *text, size_t size)
{
    for (int i = 0; i < count; ++i)
        if (strlen(names[i]) == size && !memcmp(names[i], text, size)) return i;
    return -1;
}
/* The grammar of src/log.zig: comma-joined "level" or "topic=level". */
static int parse(signed char *table, const char *text)
{
    for (;;) {
        size_t size = strcspn(text, ",");
        const char *equals = memchr(text, '=', size);
        int topic = equals ? named(topics, XRT_LOG_TOPICS, text, (size_t)(equals - text)) : 0;
        const char *name = equals ? equals + 1 : text;
        int level = named(levels, 5, name, size - (size_t)(name - text));
        if (topic < 0 || level < 0) return -1;
        for (int i = 0; i < XRT_LOG_TOPICS; ++i)
            if (!equals || i == topic) table[i] = (signed char)level;
        if (!text[size]) return 0;
        text += size + 1;
    }
}
static void configure(void)
{
    signed char table[XRT_LOG_TOPICS];
    memset(table, XRT_LOG_INFO, sizeof table);
    clock_gettime(CLOCK_MONOTONIC, &epoch);
    const char *file = getenv("XODB_LOG_FILE"), *text = getenv("XODB_LOG");
    if (file && file[0]) {
        int fd = open(file, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0600);
        if (fd >= 0) log_fd = fd;
    }
    if (text && text[0] && parse(table, text)) memset(table, XRT_LOG_INFO, sizeof table);
    memcpy(xrt_log_levels, table, sizeof table);
}
void xrt_log_write(int level, int topic, const char *format, ...)
{
    pthread_once(&once, configure);
    if (level > xrt_log_levels[topic]) return;
    char line[1024];
    size_t used = 0;
    if (level >= XRT_LOG_DEBUG) {
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        long long ms = (long long)(now.tv_sec - epoch.tv_sec) * 1000 + (now.tv_nsec - epoch.tv_nsec) / 1000000;
        used = (size_t)snprintf(line, sizeof line, "xodb[%s] +%lld.%03llds ", topics[topic], ms / 1000, ms % 1000);
    }
    va_list args;
    va_start(args, format);
    int wrote = vsnprintf(line + used, sizeof line - used, format, args);
    va_end(args);
    if (wrote < 0) return;
    used += (size_t)wrote;
    if (used >= sizeof line) { /* One write per line: cut it and keep the newline. */
        used = sizeof line;
        line[used - 1] = '\n';
    }
    for (size_t at = 0; at < used;) {
        ssize_t n = write(log_fd, line + at, used - at);
        if (n <= 0) return;
        at += (size_t)n;
    }
}
