#define _GNU_SOURCE 1
#include "gdb_link.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <netdb.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define TIMEOUT_NS UINT64_C(5000000000)
static uint64_t now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * UINT64_C(1000000000) + (uint64_t)t.tv_nsec;
}
static enum xrt_status fail(struct xrt_gdb_link *l, enum xrt_status status,
                            const char *reason)
{
    snprintf(l->reason, sizeof(l->reason), "%s", reason);
    l->failed = true;
    if (l->fd >= 0) close(l->fd);
    l->fd = -1;
    return status;
}
static uint64_t deadline_for(const struct xrt_gdb_link *l, uint64_t deadline)
{
    return l->operation_deadline_ns && l->operation_deadline_ns < deadline ?
        l->operation_deadline_ns : deadline;
}
static bool expired(const struct xrt_gdb_link *l)
{
    return l->operation_deadline_ns && now() >= l->operation_deadline_ns;
}
static enum xrt_status operation_timeout(struct xrt_gdb_link *l)
{
    return fail(l, XRT_TRANSPORT_FAILED, "GDB operation deadline exceeded");
}
static void endpoint_notice(int fd)
{
    struct sockaddr_storage peer;
    socklen_t size = sizeof(peer);
    bool loopback = false;
    if (!getpeername(fd, (struct sockaddr *)&peer, &size)) {
        if (peer.ss_family == AF_INET) {
            const struct sockaddr_in *a = (const struct sockaddr_in *)&peer;
            loopback = (ntohl(a->sin_addr.s_addr) >> 24) == 127;
        } else if (peer.ss_family == AF_INET6) {
            const struct in6_addr *a = &((const struct sockaddr_in6 *)&peer)->sin6_addr;
            loopback = IN6_IS_ADDR_LOOPBACK(a) ||
                (IN6_IS_ADDR_V4MAPPED(a) && a->s6_addr[12] == 127);
        }
    }
    if (!loopback)
        fputs("xodb: GDB connection is non-loopback and has no encryption or authentication; use a trusted connection or SSH port forward.\n", stderr);
}
static int ready(int fd, short events, uint64_t deadline)
{
    for (;;) {
        uint64_t clock = now();
        uint64_t ms = deadline > clock ? (deadline - clock + 999999) / 1000000 : 0;
        struct pollfd p = {.fd = fd, .events = events};
        int result = poll(&p, 1, ms > INT_MAX ? INT_MAX : (int)ms);
        if (result < 0 && errno == EINTR) continue;
        if (result <= 0) return result;
        /* Drain a final buffered reply before observing EOF. */
        if (p.revents & events) return 1;
        return -1;
    }
}
static enum xrt_status write_bytes(struct xrt_gdb_link *l, const void *data,
                                   size_t size, uint64_t deadline)
{
    if (l->failed || l->fd < 0) return XRT_TRANSPORT_FAILED;
    deadline = deadline_for(l, deadline);
    const uint8_t *p = data;
    size_t at = 0;
    while (at < size) {
        if (expired(l)) return operation_timeout(l);
        ssize_t n = send(l->fd, p + at, size - at, MSG_NOSIGNAL);
        if (n > 0) { at += (size_t)n; continue; }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) &&
            ready(l->fd, POLLOUT, deadline) > 0) continue;
        if (expired(l)) return operation_timeout(l);
        return fail(l, XRT_TRANSPORT_FAILED, "GDB transport write failed or timed out");
    }
    return XRT_OK;
}
void xrt_gdb_disconnect(struct xrt_gdb_link *l)
{
    if (l && l->fd >= 0) close(l->fd);
    if (l) { l->fd = -1; l->failed = true; }
}
enum xrt_status xrt_gdb_connect(struct xrt_gdb_link *l, const char *endpoint)
{
    if (!l || !endpoint) return XRT_INVALID_ARGUMENT;
    *l = (struct xrt_gdb_link){.fd = -1, .packet_size = 1024,
        .operation_deadline_ns = now() + XRT_GDB_OPEN_NS};
    char host[256], service[6];
    const char *port, *start = endpoint, *end;
    if (*start == '[') {
        ++start;
        end = strchr(start, ']');
        if (!end || end[1] != ':') return XRT_INVALID_ARGUMENT;
        port = end + 2;
    } else {
        end = strrchr(start, ':');
        if (!end || memchr(start, ':', (size_t)(end - start))) return XRT_INVALID_ARGUMENT;
        port = end + 1;
    }
    size_t n = (size_t)(end - start), digits = strnlen(port, sizeof(service));
    if (!n || n >= sizeof(host) || !digits || digits >= sizeof(service))
        return XRT_INVALID_ARGUMENT;
    unsigned value = 0;
    for (size_t i = 0; i < digits; ++i) {
        if (port[i] < '0' || port[i] > '9') return XRT_INVALID_ARGUMENT;
        value = value * 10 + (unsigned)(port[i] - '0');
    }
    if (!value || value > 65535) return XRT_INVALID_ARGUMENT;
    memcpy(host, start, n); host[n] = 0;
    memcpy(service, port, digits + 1);
    struct addrinfo hints = {.ai_socktype = SOCK_STREAM, .ai_family = AF_UNSPEC,
                             .ai_flags = AI_NUMERICSERV}, *addresses = NULL;
    if (getaddrinfo(host, service, &hints, &addresses))
        return fail(l, XRT_TRANSPORT_FAILED, "GDB host resolution failed");
    const uint64_t deadline = deadline_for(l, now() + TIMEOUT_NS);
    for (struct addrinfo *a = addresses; a && now() < deadline; a = a->ai_next) {
        int fd = socket(a->ai_family, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, a->ai_protocol);
        if (fd < 0) continue;
        int one = 1; (void)setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        int result = connect(fd, a->ai_addr, a->ai_addrlen);
        if (result == 0) { l->fd = fd; break; }
        if (errno == EINPROGRESS && ready(fd, POLLOUT, deadline) > 0) {
            int error = 0; socklen_t size = sizeof(error);
            if (!getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) && !error) {
                l->fd = fd; break;
            }
        }
        close(fd);
    }
    freeaddrinfo(addresses);
    if (expired(l)) return operation_timeout(l);
    if (l->fd >= 0) { endpoint_notice(l->fd); return XRT_OK; }
    return fail(l, XRT_TRANSPORT_FAILED, "GDB TCP connection failed");
}
enum xrt_status xrt_gdb_send(struct xrt_gdb_link *l, const void *payload, size_t size)
{
    if (!l || (!payload && size)) return XRT_INVALID_ARGUMENT;
    if (l->failed) return XRT_TRANSPORT_FAILED;
    if (size > l->packet_size || size > XRT_GDB_PAYLOAD_MAX) return XRT_BUFFER_TOO_SMALL;
    enum xrt_gdb_decode_status encoded =
        xrt_gdb_encode(payload, size, l->tx, sizeof(l->tx), &l->sent);
    if (encoded != XRT_GDB_OK) return XRT_BUFFER_TOO_SMALL;
    l->awaiting_ack = !l->noack;
    l->retries = 0;
    return write_bytes(l, l->tx, l->sent, now() + TIMEOUT_NS);
}
static bool console_packet(const uint8_t *p, size_t n)
{
    if (n < 3 || p[0] != 'O' || !(n & 1)) return false;
    for (size_t i = 1; i < n; ++i)
        if (!((p[i] >= '0' && p[i] <= '9') || (p[i] >= 'a' && p[i] <= 'f') ||
              (p[i] >= 'A' && p[i] <= 'F'))) return false;
    return true;
}
static enum xrt_status receive(struct xrt_gdb_link *l, void *out, size_t cap,
                                size_t *length, bool wait, bool stop)
{
    if (!l || !out || !length) return XRT_INVALID_ARGUMENT;
    *length = 0;
    if (l->failed || l->fd < 0) return XRT_TRANSPORT_FAILED;
    const uint64_t deadline = deadline_for(l, now() + (wait ? TIMEOUT_NS : 0));
    unsigned frames = 0, bad = 0;
    for (;;) {
        if (expired(l)) return operation_timeout(l);
        if (l->received) {
            struct xrt_gdb_view view;
            enum xrt_gdb_decode_status decoded =
                xrt_gdb_decode(l->rx, l->received, out, cap, &view);
            if (decoded != XRT_GDB_NEED_MORE) {
                if (!view.consumed || view.consumed > l->received)
                    return fail(l, XRT_PROTOCOL_ERROR, "GDB malformed frame");
                memmove(l->rx, l->rx + view.consumed, l->received - view.consumed);
                l->received -= view.consumed;
                if (decoded == XRT_GDB_BAD_CHECKSUM && !l->noack && ++bad <= 3) {
                    if (write_bytes(l, "-", 1, deadline) != XRT_OK) return XRT_TRANSPORT_FAILED;
                    continue;
                }
                if (decoded != XRT_GDB_OK)
                    return fail(l, XRT_PROTOCOL_ERROR, "GDB invalid or oversized response");
                if (++frames > 128) return fail(l, XRT_PROTOCOL_ERROR, "GDB response frame budget exceeded");
                if (view.kind == XRT_GDB_ACK) { l->awaiting_ack = false; continue; }
                if (view.kind == XRT_GDB_NAK && l->awaiting_ack && ++l->retries <= 3) {
                    if (write_bytes(l, l->tx, l->sent, deadline) != XRT_OK) return XRT_TRANSPORT_FAILED;
                    continue;
                }
                if (view.kind != XRT_GDB_PACKET)
                    return fail(l, XRT_PROTOCOL_ERROR, "Unexpected GDB all-stop response");
                l->awaiting_ack = false;
                if (!l->noack && write_bytes(l, "+", 1, deadline) != XRT_OK) return XRT_TRANSPORT_FAILED;
                if (console_packet(out, view.length)) continue;
                *length = view.length;
                return XRT_OK;
            }
        }
        if (l->received == sizeof(l->rx))
            return fail(l, XRT_PROTOCOL_ERROR, "GDB unterminated response exceeds buffer");
        int available = ready(l->fd, POLLIN, deadline);
        if (expired(l)) return operation_timeout(l);
        if (!available && !wait) return XRT_NOT_STOPPED;
        if (!available && stop) return XRT_STOP_TIMEOUT;
        if (available <= 0)
            return fail(l, XRT_TRANSPORT_FAILED, "GDB response failed or timed out");
        ssize_t n = recv(l->fd, l->rx + l->received, sizeof(l->rx) - l->received, 0);
        if (n > 0) { l->received += (size_t)n; continue; }
        if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        return fail(l, XRT_TRANSPORT_FAILED, "GDB peer closed the connection");
    }
}
enum xrt_status xrt_gdb_receive(struct xrt_gdb_link *l, void *out, size_t cap,
                                size_t *length, bool wait)
{
    return receive(l, out, cap, length, wait, false);
}
enum xrt_status xrt_gdb_receive_stop(struct xrt_gdb_link *l, void *out, size_t cap,
                                     size_t *length, bool wait)
{
    return receive(l, out, cap, length, wait, true);
}
enum xrt_status xrt_gdb_exchange(struct xrt_gdb_link *l, const void *payload, size_t size,
                                 void *out, size_t cap, size_t *length)
{
    enum xrt_status status = xrt_gdb_send(l, payload, size);
    return status == XRT_OK ? xrt_gdb_receive(l, out, cap, length, true) : status;
}
enum xrt_status xrt_gdb_interrupt(struct xrt_gdb_link *l)
{
    if (!l) return XRT_INVALID_ARGUMENT;
    return write_bytes(l, "\003", 1, now() + TIMEOUT_NS);
}
