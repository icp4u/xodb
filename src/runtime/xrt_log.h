#ifndef XRT_LOG_H
#define XRT_LOG_H
/* Leveled diagnostics for the C runtime and the agent; src/log.zig is the
 * Zig half. The setting is read once from XODB_LOG ("debug", or
 * "runtime=trace,agent=debug"); XODB_LOG_FILE names an append-only file to
 * use in place of stderr. An unreadable value leaves every topic at info.
 *
 * error, warn and info formats are written as given. debug and trace lines
 * get "xodb[topic] +12.345s " in front. Every format ends in "\n". */
enum xrt_log_level { XRT_LOG_ERROR, XRT_LOG_WARN, XRT_LOG_INFO, XRT_LOG_DEBUG, XRT_LOG_TRACE };
enum xrt_log_topic {
    XRT_LOG_RENDER, XRT_LOG_WINDOW, XRT_LOG_RUNTIME, XRT_LOG_AGENT, XRT_LOG_SESSION, XRT_LOG_MCP,
    XRT_LOG_SIDECAR, XRT_LOG_SEMQ, XRT_LOG_OVERVIEW, XRT_LOG_REDOT, XRT_LOG_PROFILE, XRT_LOG_TOPICS
};
/* Above every level until XODB_LOG was read, so the first line reads it. */
extern signed char xrt_log_levels[XRT_LOG_TOPICS];
void xrt_log_write(int level, int topic, const char *format, ...) __attribute__((format(printf, 3, 4)));
/* A line that is not shown costs one load and a branch. */
#define xrt_log(level, topic, ...) \
    ((level) <= xrt_log_levels[topic] ? xrt_log_write((level), (topic), __VA_ARGS__) : (void)0)
#endif
