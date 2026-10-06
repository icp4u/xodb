/* Probe-ID regressions adapted from the owned C03 delivery harness.
 * Run: runtime-probe-ids [PATH-TO-XODB-AGENT]
 * Restoring UINT64_MAX - 1 used to wrap the shared counter on the next
 * allocation; remote snapshots then broke the connection. Restoring an ID
 * held by a watchpoint also created duplicate probe IDs. Only owned /bin/sleep
 * targets are launched, and every test destroys its target before returning. */
#define _GNU_SOURCE 1
#include "target_internal.h"
#include "xrt_remote.h"
#include <stdio.h>
#include <stdlib.h>

static unsigned failures;
#define EXPECT(cond)                                                                               \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #cond);                             \
            ++failures;                                                                            \
        }                                                                                          \
    } while (0)

static struct xrt_target_view view(struct xrt_target *target)
{
    struct xrt_target_view out;
    xrt_target_view(target, &out);
    return out;
}

static struct xrt_target *launch(const char *agent, uint64_t *pc)
{
    struct xrt_target *target = NULL;
    if (agent) {
        const char *transport[] = {agent, "--stdio", NULL};
        const enum xrt_status status = xrt_target_remote(transport, &target);
        EXPECT(status == XRT_OK);
        if (status != XRT_OK)
            return NULL;
    } else {
        target = xrt_target_create();
        EXPECT(target != NULL);
        if (!target)
            return NULL;
    }
    const char *argv[] = {"/bin/sleep", "30", NULL};
    const enum xrt_status status = xrt_target_launch(target, argv);
    EXPECT(status == XRT_OK);
    const struct xrt_target_view stopped = view(target);
    EXPECT(stopped.thread_count == 1 && stopped.state == XRT_STOPPED);
    struct xrt_registers registers;
    if (status != XRT_OK || stopped.thread_count != 1 ||
        xrt_target_registers(target, stopped.threads[0].tid, &registers) != XRT_OK) {
        EXPECT(0);
        EXPECT(xrt_target_destroy(target) == XRT_OK);
        return NULL;
    }
    uint64_t decoded_pc = 0;
    if (xrt_registers_pc(&registers, &decoded_pc) != XRT_OK) {
        EXPECT(0);
        EXPECT(xrt_target_destroy(target) == XRT_OK);
        return NULL;
    }
    *pc = decoded_pc;
    return target;
}

/* A fresh target per allocation path also reproduces the old remote failure
 * independently, rather than running later assertions on a broken stream. */
static void exhausted(const char *agent, unsigned operation)
{
    uint64_t pc;
    struct xrt_target *target = launch(agent, &pc);
    if (!target)
        return;
    EXPECT(xrt_target_breakpoint_restore(target, UINT64_MAX - 1, true) == XRT_OK);
    const struct xrt_target_view before = view(target);
    EXPECT(before.next_probe_id == UINT64_MAX);
    uint64_t id = 123;
    enum xrt_status status;
    if (operation == 0)
        status = xrt_target_breakpoint_reserve(target, &id);
    else if (operation == 1)
        status = xrt_target_breakpoint_set(target, pc, false, &id);
    else
        status = xrt_target_watchpoint_set(target, pc, 1, XRT_WATCH_WRITE, &id);
    EXPECT(status == (operation == 2 ? XRT_WATCHPOINT_LIMIT : XRT_BREAKPOINT_LIMIT));
    EXPECT(id == 123);
    const struct xrt_target_view after = view(target);
    EXPECT(after.next_probe_id == UINT64_MAX);
    EXPECT(after.breakpoint_count == before.breakpoint_count);
    EXPECT(after.generation == before.generation);
    for (unsigned i = 0; i < XRT_MAX_WATCHPOINTS; ++i)
        EXPECT(!after.watchpoints[i].present);
    struct xrt_registers registers;
    EXPECT(xrt_target_registers(target, after.pid, &registers) == XRT_OK);
    EXPECT(xrt_target_destroy(target) == XRT_OK);
}

static void last_valid_and_existing(const char *agent)
{
    uint64_t pc;
    struct xrt_target *target = launch(agent, &pc);
    if (!target)
        return;
    uint64_t existing = 0, last = 0, same = 0;
    EXPECT(xrt_target_breakpoint_set(target, pc, false, &existing) == XRT_OK);
    EXPECT(existing != 0);
    EXPECT(xrt_target_breakpoint_restore(target, UINT64_MAX - 2, false) == XRT_OK);
    EXPECT(xrt_target_breakpoint_reserve(target, &last) == XRT_OK);
    EXPECT(last == UINT64_MAX - 1 && view(target).next_probe_id == UINT64_MAX);
    /* Looking up an existing address must not allocate a new ID. */
    EXPECT(xrt_target_breakpoint_set(target, pc, false, &same) == XRT_OK);
    EXPECT(same == existing);
    EXPECT(xrt_target_breakpoint_remove(target, last) == XRT_OK);
    EXPECT(view(target).next_probe_id == UINT64_MAX);
    EXPECT(xrt_target_breakpoint_reserve(target, &last) == XRT_BREAKPOINT_LIMIT);
    EXPECT(xrt_target_destroy(target) == XRT_OK);
}

static void shared_namespace(const char *agent)
{
    uint64_t pc;
    struct xrt_target *target = launch(agent, &pc);
    if (!target)
        return;
    uint64_t watch = 0;
    EXPECT(xrt_target_watchpoint_set(target, pc, 1, XRT_WATCH_WRITE, &watch) == XRT_OK);
    EXPECT(watch != 0);
    const struct xrt_target_view before = view(target);
    EXPECT(xrt_target_breakpoint_restore(target, watch, true) == XRT_INVALID_ARGUMENT);
    EXPECT(xrt_target_breakpoint_restore(target, 0, true) == XRT_INVALID_ARGUMENT);
    EXPECT(xrt_target_breakpoint_restore(target, UINT64_MAX, true) == XRT_INVALID_ARGUMENT);
    const struct xrt_target_view after = view(target);
    EXPECT(after.breakpoint_count == before.breakpoint_count);
    EXPECT(after.next_probe_id == before.next_probe_id);
    EXPECT(after.generation == before.generation);
    EXPECT(after.watchpoints[0].present && after.watchpoints[0].id == watch);
    EXPECT(xrt_target_watchpoint_remove(target, watch) == XRT_OK);
    EXPECT(xrt_target_breakpoint_restore(target, watch, true) == XRT_OK);
    EXPECT(xrt_target_breakpoint_restore(target, watch, false) == XRT_INVALID_ARGUMENT);
    EXPECT(xrt_target_destroy(target) == XRT_OK);
}

int main(int argc, char **argv)
{
    if (argc > 2) {
        fputs("usage: runtime-probe-ids [PATH-TO-XODB-AGENT]\n", stderr);
        return 2;
    }
    if (getenv("XODB_TEST_NO_LIVE") || !xrt_arch_native()) {
        puts("C probe IDs: live checks explicitly skipped");
        return 0;
    }
    const bool watchpoints = xrt_arch_native()->machine == XRT_X86_64;
    for (unsigned mode = 0; mode < (argc == 2 ? 2u : 1u); ++mode) {
        const char *agent = mode ? argv[1] : NULL;
        const unsigned before = failures;
        for (unsigned operation = 0; operation < (watchpoints ? 3u : 2u); ++operation)
            exhausted(agent, operation);
        last_valid_and_existing(agent);
        if (watchpoints)
            shared_namespace(agent);
        else
            puts("C probe IDs: hardware watchpoint cases require x86-64");
        printf("probe IDs (%s): %s\n", agent ? "agent" : "native",
               before == failures ? "passed" : "FAILED");
    }
    return failures != 0;
}
