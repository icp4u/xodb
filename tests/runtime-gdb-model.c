#define _GNU_SOURCE 1
#include "xrt_gdbremote.h"
#include "gdb_packet.h"
#include "gdb_link.h"
#include <arpa/inet.h>
#include <assert.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
#include <time.h>

/* Synthetic stub: confirmations are deliberately unreliable. None of its
 * addresses refer to this process, so a native fallback cannot make it pass. */
static int digit(unsigned c)
{
    if (c >= '0' && c <= '9') return (int)c - '0';
    if (c >= 'a' && c <= 'f') return (int)c - 'a' + 10;
    assert(0); return 0;
}
static void encode(uint64_t value, char *out)
{
    static const char hex[] = "0123456789abcdef";
    for (unsigned i = 0; i < 8; ++i) {
        unsigned byte = (unsigned)(value >> (8 * i)) & 255;
        out[2 * i] = hex[byte >> 4]; out[2 * i + 1] = hex[byte & 15];
    }
}
static uint64_t decode(const char *text)
{
    uint64_t value = 0;
    for (unsigned i = 0; i < 8; ++i)
        value |= (uint64_t)(digit(text[2 * i]) * 16 + digit(text[2 * i + 1])) << (8 * i);
    return value;
}
static void send_all(int fd, const void *data, size_t size)
{
    size_t at = 0;
    while (at < size) {
        ssize_t n = send(fd, (const char *)data + at, size - at, MSG_NOSIGNAL);
        assert(n > 0); at += (size_t)n;
    }
}
static int command(int fd, char *out, size_t cap)
{
    uint8_t wire[4096]; size_t used = 0;
    for (;;) {
        struct pollfd p = {.fd = fd, .events = POLLIN};
        assert(poll(&p, 1, 10000) > 0);
        ssize_t n = recv(fd, wire + used, 1, 0);
        if (n == 0) return 0;
        assert(n == 1 && used + 1 < sizeof(wire)); ++used;
        struct xrt_gdb_view view;
        enum xrt_gdb_decode_status status = xrt_gdb_decode(wire, used, (uint8_t *)out, cap - 1, &view);
        if (status == XRT_GDB_NEED_MORE) continue;
        assert(status == XRT_GDB_OK && view.consumed == used);
        used = 0;
        if (view.kind == XRT_GDB_ACK) continue;
        assert(view.kind == XRT_GDB_PACKET);
        send_all(fd, "+", 1); out[view.length] = 0; return 1;
    }
}
static void reply(int fd, const char *text)
{
    uint8_t wire[8192]; size_t size;
    assert(xrt_gdb_encode((const uint8_t *)text, strlen(text), wire, sizeof(wire), &size) == XRT_GDB_OK);
    send_all(fd, wire, size);
}
enum { SLOW_THREADS = 3, CHURN_THREADS = 4, CLOSED_LINK = 5 };
static void serve(int listener, int mode)
{
    int fd = accept(listener, NULL, NULL); assert(fd >= 0); close(listener);
    uint64_t reg = 7, memory = 17, selected = 1; unsigned detach_count = 0;
    char request[4096], response[4096];
    unsigned commands = 0, round = 0, listed = 0, delayed = 0;
    while (command(fd, request, sizeof(request))) {
        assert(++commands <= 4096); strcpy(response, "");
        if (!strncmp(request, "qSupported:", 11))
            strcpy(response, "PacketSize=1000;qXfer:features:read+");
        else if (!strcmp(request, "vCont?")) strcpy(response, mode >= SLOW_THREADS ? "vCont;c;s" : "vCont;c");
        else if (!strcmp(request, "?")) strcpy(response, mode == CHURN_THREADS ? "T05thread:10000;" : "T05thread:1;");
        else if (!strncmp(request, "qXfer:features:read:target.xml:", 30)) {
            snprintf(response, sizeof(response), "l<target><architecture>%s</architecture><feature>"
                "<reg name='rip' bitsize='64'/><reg name='rsp' bitsize='64'/>"
                "<reg name='rax' bitsize='64'/></feature></target>", mode == 2 ? "unsupported" : "i386:x86-64");
        } else if (!strcmp(request, "qfThreadInfo") || !strcmp(request, "qsThreadInfo")) {
            bool first = request[1] == 'f';
            if (first) listed = 0;
            if (mode == SLOW_THREADS && round && !first) {
                /* Each page is inside the read deadline. The entire inventory
                 * exceeds the operation budget. EOF proves the client stops it. */
                struct pollfd p = {.fd = fd, .events = POLLIN};
                if (poll(&p, 1, (int)(XRT_GDB_OPERATION_NS / UINT64_C(10000000))) > 0) {
                    char c;
                    assert(recv(fd, &c, 1, 0) == 0);
                    assert(delayed > 0 && delayed < 32);
                    close(fd); _exit(0);
                }
                assert(++delayed <= 32);
                snprintf(response, sizeof(response), "m%x", delayed + 2);
            } else if (mode == CHURN_THREADS && listed < 1024) {
                size_t at = 0;
                for (unsigned i = 0; i < 64 && listed < 1024; ++i, ++listed) {
                    unsigned tid = listed == 0 ? 1 : listed == 1 ? 0x80000001u :
                        0x10000u + round * 1024 + listed - 2;
                    int n = snprintf(response + at, sizeof(response) - at, "%c%x", i ? ',' : 'm', tid);
                    assert(n > 0 && (size_t)n < sizeof(response) - at); at += (size_t)n;
                }
            } else if (first) {
                if (mode < SLOW_THREADS) reply(fd, "T05thread:1;"); /* Duplicate initial stop. */
                strcpy(response, mode == 1 ? "" : "m1,2");
            } else strcpy(response, "l");
        } else if (!strncmp(request, "vCont;s:", 8)) {
            ++round;
            snprintf(response, sizeof(response), "T05thread:%x;", mode == CHURN_THREADS ? 0x10000 + round * 1024 : 1);
        }
        else if (!strcmp(request, "qAttached")) strcpy(response, "1");
        else if (!strncmp(request, "Hg", 2)) {
            char *end; selected = strtoull(request + 2, &end, 16); assert(!*end);
            strcpy(response, "OK");
        }
        else if (!strcmp(request, "g")) {
            if (mode == CLOSED_LINK && ++listed > 1) { close(fd); _exit(0); }
            encode(0x1000, response); encode(0x8000, response + 16); encode(mode == CHURN_THREADS ? selected : reg, response + 32); response[48] = 0;
        } else if (!strncmp(request, "P2=", 3)) {
            uint64_t wanted = decode(request + 3);
            reg = wanted == 10 ? 9 : wanted;
            strcpy(response, wanted == 11 ? "E01" : "OK");
        } else if (request[0] == 'm') {
            unsigned long long address; unsigned size;
            assert(sscanf(request + 1, "%llx,%x", &address, &size) == 2 && (size == 8 || size == 1));
            if (size == 1) { reply(fd, "90"); continue; }
            encode(address == 0x2000 ? memory : 17, response); response[16] = 0;
        } else if (request[0] == 'M') {
            unsigned long long address; unsigned size; int at = 0;
            assert(sscanf(request + 1, "%llx,%x:%n", &address, &size, &at) == 2 && size == 8);
            if (address == 0x2000) memory = decode(request + 1 + at);
            strcpy(response, address == 0x2010 ? "E01" : "OK");
        } else if (!strncmp(request, "Z0,", 3)) strcpy(response, "E01");
        else if (!strncmp(request, "z0,", 3)) strcpy(response, "OK");
        else if (!strcmp(request, "D")) {
            strcpy(response, mode < SLOW_THREADS && detach_count++ == 0 ? "E01" : "OK");
        }
        reply(fd, response);
    }
    close(fd); _exit(0);
}
struct fixture { pid_t child; char endpoint[64]; };
static struct fixture start(int mode)
{
    int listener = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0); assert(listener >= 0);
    struct sockaddr_in address = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    assert(!bind(listener, (struct sockaddr *)&address, sizeof(address)) && !listen(listener, 1));
    socklen_t size = sizeof(address); assert(!getsockname(listener, (struct sockaddr *)&address, &size));
    struct fixture f = {.child = fork()}; assert(f.child >= 0);
    if (!f.child) serve(listener, mode);
    close(listener);
    snprintf(f.endpoint, sizeof(f.endpoint), "127.0.0.1:%u", ntohs(address.sin_port)); return f;
}
static void finish(struct fixture f)
{
    int status; assert(waitpid(f.child, &status, 0) == f.child);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
}
static uint64_t generation(struct xrt_target *target)
{
    struct xrt_target_view view; xrt_target_view(target, &view); return view.generation;
}
static void lifecycle_checks(void)
{
    for (int mode = SLOW_THREADS; mode <= CLOSED_LINK; ++mode) {
        struct fixture f = start(mode); struct xrt_target *target = NULL;
        assert(xrt_target_gdb_remote(f.endpoint, &target) == XRT_OK);
        if (mode == SLOW_THREADS) {
            struct timespec begin, end;
            assert(!clock_gettime(CLOCK_MONOTONIC, &begin));
            assert(xrt_target_step(target, 1) == XRT_OK);
            assert(xrt_target_wait_stopped(target) == XRT_TRANSPORT_FAILED);
            assert(!clock_gettime(CLOCK_MONOTONIC, &end));
            struct xrt_gdb_info info; assert(xrt_target_gdb_info(target, &info));
            assert(strstr(info.reason, "operation deadline exceeded"));
            assert(xrt_target_poll(target) == XRT_TRANSPORT_FAILED);
            printf("GDB slow inventory: operation deadline failed the link after %.3f s\n",
                (double)(end.tv_sec - begin.tv_sec) + (double)(end.tv_nsec - begin.tv_nsec) / 1e9);
        } else if (mode == CHURN_THREADS) {
            for (unsigned round = 0; round < 4; ++round) {
                struct xrt_target_view view; xrt_target_view(target, &view);
                assert(view.thread_count == 1024);
                /* A high remote TID keeps its local alias across refreshes. */
                struct xrt_registers regs;
                assert(xrt_target_registers(target, 2, &regs) == XRT_OK);
                uint64_t actual;
                assert(xrt_registers_value(&regs, "rax", 3, &actual) == XRT_OK && actual == 0x80000001u);
                assert(xrt_target_step(target, (int32_t)(0x10000 + round * 1024)) == XRT_OK);
                assert(xrt_target_wait_stopped(target) == XRT_OK);
                assert(xrt_target_registers(target, (int32_t)(0x10000 + round * 1024), &regs) == XRT_UNKNOWN_THREAD);
            }
            assert(xrt_target_detach(target) == XRT_OK);
        } else {
            struct xrt_registers regs;
            assert(xrt_target_registers(target, 1, &regs) == XRT_TRANSPORT_FAILED);
            assert(xrt_target_detach(target) == XRT_TRANSPORT_FAILED);
        }
        /* ASan/LSan also verify that a failed transport frees the target. */
        assert(xrt_target_destroy(target) == XRT_OK);
        finish(f);
    }
    puts("GDB lifecycle: bounded slow inventory, full-table turnover with stable aliases, failed-link destruction pass");
}
int main(void)
{
    alarm(90);
    lifecycle_checks();
    for (int mode = 0; mode <= 2; ++mode) {
        struct fixture f = start(mode); struct xrt_target *target = NULL;
        enum xrt_status status = xrt_target_gdb_remote(f.endpoint, &target);
        if (mode == 2) {
            assert(status == XRT_UNSUPPORTED_ARCHITECTURE && !target); finish(f); continue;
        }
        assert(status == XRT_OK && target);
        struct xrt_gdb_info info; assert(xrt_target_gdb_info(target, &info));
        assert(info.unsupported & XRT_GDB_CAP_STEP);
        assert(mode == 1 ? (info.unsupported & XRT_GDB_CAP_THREADS) : (info.supported & XRT_GDB_CAP_THREADS));
        struct xrt_target_view view; xrt_target_view(target, &view);
        assert(view.thread_count == (mode == 1 ? 1u : 2u));
        uint64_t before = generation(target);
        assert(xrt_target_step(target, 1) == XRT_UNSUPPORTED_CONTROL);
        assert(generation(target) == before);
        for (uint64_t address = 0x2000; address <= 0x2010; address += 8) {
            uint64_t value = 29; before = generation(target);
            status = xrt_target_write(target, address, &value, sizeof(value));
            assert(status == (address == 0x2000 ? XRT_OK : XRT_PARTIAL_MEMORY_WRITE));
            assert(generation(target) > before);
        }
        for (uint64_t value = 10; value <= 12; ++value) {
            before = generation(target);
            status = xrt_target_register_write(target, 1, "rax", 3, value);
            assert(status == (value == 12 ? XRT_OK : XRT_PARTIAL_REGISTER_WRITE));
            assert(generation(target) > before);
            struct xrt_registers regs; uint64_t actual;
            assert(xrt_target_registers(target, 1, &regs) == XRT_OK);
            assert(xrt_registers_value(&regs, "rax", 3, &actual) == XRT_OK && actual == (value == 10 ? 9 : value));
        }
        uint64_t bp_id = 0; before = generation(target);
        assert(xrt_target_breakpoint_set(target, 0x1000, false, &bp_id) == XRT_PERMISSION_DENIED);
        assert(generation(target) > before);
        assert(xrt_target_continue(target) == XRT_INVALID_STATE);
        assert(xrt_target_detach(target) == XRT_DETACH_INCOMPLETE);
        xrt_target_view(target, &view); assert(view.detach_pending && view.state == XRT_STOPPED);
        assert(xrt_target_detach(target) == XRT_OK);
        assert(xrt_target_destroy(target) == XRT_OK); finish(f);
    }
    puts("GDB model: unreliable write confirmations invalidate; missing step/thread capabilities, unsupported XML architecture, duplicate stops, uncertain breakpoint guard, retryable detach pass");
}
