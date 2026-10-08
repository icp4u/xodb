#define _GNU_SOURCE 1
#include "gdb_link.h"
#include <arpa/inet.h>
#include <assert.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
static void write_all(int fd, const void *data, size_t size)
{
    const char *p = data;
    while (size) { ssize_t n = write(fd, p, size); assert(n > 0); p += n; size -= (size_t)n; }
}
static void byte(int fd, char expected)
{
    char value; assert(read(fd, &value, 1) == 1 && value == expected);
}
static void command(int fd, const char *expected)
{
    uint8_t wire[4096], out[4096]; size_t used = 0;
    for (;;) {
        assert(used < sizeof(wire) && read(fd, wire + used, 1) == 1); ++used;
        struct xrt_gdb_view view;
        enum xrt_gdb_decode_status status = xrt_gdb_decode(wire, used, out, sizeof(out), &view);
        if (status == XRT_GDB_NEED_MORE) continue;
        assert(status == XRT_GDB_OK && view.kind == XRT_GDB_PACKET);
        assert(view.length == strlen(expected) && !memcmp(out, expected, view.length));
        return;
    }
}
static void response(int fd, const char *body, bool corrupt)
{
    uint8_t wire[4096]; size_t size;
    assert(xrt_gdb_encode((const uint8_t *)body, strlen(body), wire, sizeof(wire), &size) == XRT_GDB_OK);
    if (corrupt) wire[size - 1] = wire[size - 1] == '0' ? '1' : '0';
    /* Force the reader to cope with arbitrary syscall boundaries. */
    for (size_t i = 0; i < size; ++i) write_all(fd, wire + i, 1);
}
static void serve(int listener)
{
    int fd = accept(listener, NULL, NULL); assert(fd >= 0); close(listener);
    command(fd, "qSupported"); write_all(fd, "-", 1);
    command(fd, "qSupported"); write_all(fd, "+", 1);
    response(fd, "PacketSize=4000;QStartNoAckMode+", true);
    byte(fd, '-');
    response(fd, "PacketSize=4000;QStartNoAckMode+", false); byte(fd, '+');
    command(fd, "QStartNoAckMode"); write_all(fd, "+", 1); response(fd, "OK", false); byte(fd, '+');
    command(fd, "g"); response(fd, "O6869", false); response(fd, "00000000", false);
    command(fd, "vCont;c");
    byte(fd, 3);
    response(fd, "T02thread:1;", false);
    command(fd, "unsupported"); response(fd, "", false);
    command(fd, "close");
    close(fd); _exit(0);
}
static void expired_budget(void)
{
    for (unsigned op = 0; op < 3; ++op) {
        int pair[2]; assert(!socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, pair));
        struct xrt_gdb_link *link = calloc(1, sizeof(*link)); assert(link);
        link->fd = pair[0]; link->packet_size = 1024; link->operation_deadline_ns = 1;
        uint8_t out[16]; size_t size;
        assert(xrt_gdb_encode((const uint8_t *)"OK", 2, link->rx, sizeof(link->rx), &link->received) == XRT_GDB_OK);
        enum xrt_status status = op == 0 ? xrt_gdb_send(link, "qC", 2) :
            op == 1 ? xrt_gdb_receive_stop(link, out, sizeof(out), &size, false) : xrt_gdb_interrupt(link);
        assert(status == XRT_TRANSPORT_FAILED && link->failed && link->fd == -1);
        assert(strstr(link->reason, "operation deadline exceeded"));
        assert(read(pair[1], out, sizeof(out)) == 0);
        close(pair[1]); free(link);
    }
}
int main(void)
{
    signal(SIGPIPE, SIG_IGN);
    expired_budget();
    int listener = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0); assert(listener >= 0);
    struct sockaddr_in address = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    assert(!bind(listener, (struct sockaddr *)&address, sizeof(address)) && !listen(listener, 1));
    socklen_t length = sizeof(address);
    assert(!getsockname(listener, (struct sockaddr *)&address, &length));
    pid_t child = fork(); assert(child >= 0);
    if (!child) serve(listener);
    close(listener);
    struct xrt_gdb_link *link = malloc(sizeof(*link)); assert(link);
    char endpoint[64]; snprintf(endpoint, sizeof(endpoint), "127.0.0.1:%u", ntohs(address.sin_port));
    assert(xrt_gdb_connect(link, endpoint) == XRT_OK);
    uint8_t reply[4096]; size_t size;
    assert(xrt_gdb_exchange(link, "qSupported", 10, reply, sizeof(reply), &size) == XRT_OK);
    assert(size == strlen("PacketSize=4000;QStartNoAckMode+"));
    assert(xrt_gdb_exchange(link, "QStartNoAckMode", 15, reply, sizeof(reply), &size) == XRT_OK);
    assert(size == 2 && !memcmp(reply, "OK", 2));
    link->noack = true;
    assert(xrt_gdb_exchange(link, "g", 1, reply, sizeof(reply), &size) == XRT_OK);
    assert(size == 8 && !memcmp(reply, "00000000", 8));
    assert(xrt_gdb_send(link, "vCont;c", 7) == XRT_OK);
    assert(xrt_gdb_receive(link, reply, sizeof(reply), &size, false) == XRT_NOT_STOPPED);
    assert(xrt_gdb_interrupt(link) == XRT_OK);
    assert(xrt_gdb_receive(link, reply, sizeof(reply), &size, true) == XRT_OK);
    assert(size == 12 && !memcmp(reply, "T02thread:1;", 12));
    assert(xrt_gdb_exchange(link, "unsupported", 11, reply, sizeof(reply), &size) == XRT_OK && !size);
    assert(xrt_gdb_exchange(link, "close", 5, reply, sizeof(reply), &size) == XRT_TRANSPORT_FAILED);
    assert(link->fd == -1 && link->failed && link->reason[0]);
    xrt_gdb_disconnect(link);
    int status; assert(waitpid(child, &status, 0) == child && WIFEXITED(status) && !WEXITSTATUS(status));
    const char *invalid[] = {"", "host", ":12", "host:0", "host:65536", "host:x", "::1:33", "[::1]", "[::1]:-1"};
    for (size_t i = 0; i < sizeof(invalid) / sizeof(invalid[0]); ++i)
        assert(xrt_gdb_connect(link, invalid[i]) == XRT_INVALID_ARGUMENT);
    free(link);
    puts("GDB link: TCP, NAK retransmit, checksum retry, no-ack, console, interrupt and EOF pass");
}
