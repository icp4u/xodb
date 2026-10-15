#!/usr/bin/env python3
"""Synthetic tcpdump-compatible stdout producer for live-capture tests."""
import os
import signal
import socket
import struct
import sys
import time


if '--version' in sys.argv:
    if os.environ.get('XODB_FAKE_CAPTURE_OLD'):
        print('tcpdump version 3.9.8')
    else:
        print('tcpdump version 4.99.0')
    raise SystemExit(0)


if os.environ.get('XODB_FAKE_CAPTURE_DENIED'):
    sys.stderr.write('capture: permission denied\n')
    raise SystemExit(1)


def ipv4(proto, source, destination, payload):
    return struct.pack(
        '!BBHHHBBH4s4s', 0x45, 0, 20 + len(payload), 0, 0x4000, 64,
        proto, 0, socket.inet_aton(source), socket.inet_aton(destination),
    ) + payload


def tcp(source, destination, sequence, acknowledgement, flags, payload=b''):
    return struct.pack(
        '!HHIIBBHHH', source, destination, sequence, acknowledgement,
        5 << 4, flags, 65535, 0, 0,
    ) + payload


def udp(source, destination, payload):
    return struct.pack('!HHHH', source, destination, 8 + len(payload), 0) + payload


def ethernet(packet):
    return b'\0' * 12 + b'\x08\x00' + packet


def dns(response):
    flags = 0x8180 if response else 0x0100
    return (
        struct.pack('!HHHHHH', 0x1234, flags, 1, 0, 0, 0)
        + b'\x04unit\x04test\0' + struct.pack('!HH', 1, 1)
    )


def record(seconds, microseconds, packet):
    return struct.pack('<IIII', seconds, microseconds, len(packet), len(packet)) + packet


loopback = '127.0.0.1'
client, server = 41000, 8080
packets = []
# Fill beyond the minimum ring first. Whole-record eviction must retain the
# valid exchanges at the tail while reporting bounded-ring loss.
for index in range(320):
    packets.append(record(10, index, b'\0' * 480))
packets.extend((
    record(20, 90, ethernet(ipv4(6, loopback, loopback, tcp(client, server, 99, 0, 0x02)))),
    record(20, 91, ethernet(ipv4(6, loopback, loopback, tcp(server, client, 199, 100, 0x12)))),
    record(20, 100, ethernet(ipv4(6, loopback, loopback, tcp(client, server, 100, 200, 0x18, b'GET /ow')))),
    record(20, 110, ethernet(ipv4(6, loopback, loopback, tcp(client, server, 107, 200, 0x18, b'ned HTTP/1.1\r\nHost: loop\r\n\r\n')))),
    record(20, 140, ethernet(ipv4(6, loopback, loopback, tcp(server, client, 200, 134, 0x18, b'HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n')))),
    record(20, 200, ethernet(ipv4(17, loopback, loopback, udp(42000, 53, dns(False))))),
    record(20, 225, ethernet(ipv4(17, loopback, loopback, udp(53, 42000, dns(True))))),
))
stream = struct.pack('<IHHiIII', 0xa1b2c3d4, 2, 4, 0, 0, 65535, 1) + b''.join(packets)

if os.environ.get('XODB_FAKE_CAPTURE_NO_PDEATHSIG'):
    # Linux clears the parent-death signal on exec of a binary with file
    # capabilities, as dumpcap/tcpdump are usually installed. Model that.
    import ctypes
    ctypes.CDLL(None, use_errno=True).prctl(1, 0, 0, 0, 0)  # PR_SET_PDEATHSIG, 0

pid_file = os.environ.get('XODB_FAKE_CAPTURE_PID_FILE')
if pid_file:
    with open(pid_file, 'w', encoding='ascii') as handle:
        handle.write(str(os.getpid()) + '\n')

offset = 0
while offset < len(stream):
    offset += os.write(sys.stdout.fileno(), stream[offset:])

running = True


def stop(_signum, _frame):
    global running
    running = False


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
while running:
    time.sleep(0.01)
