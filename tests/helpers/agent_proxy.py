"""Bounded frame helpers for fault injection against an owned runtime agent."""
import os
import signal
import struct
import subprocess


def exact(fd, count):
    data = bytearray()
    while len(data) < count:
        part = os.read(fd, count-len(data))
        if not part:
            assert not data, 'truncated proxy frame'
            return None
        data.extend(part)
    return bytes(data)


def frame(fd):
    header = exact(fd, 32)
    if header is None:
        return None
    magic, version, op, request, target, status, size, flags = struct.unpack('>4sHHQIIII', header)
    assert magic == b'XRT1' and version == 2 and size <= 1024*1024
    body = exact(fd, size)
    assert body is not None
    return dict(header=header, body=body, op=op, request=request, target=target, status=status, flags=flags)


def write(fd, data):
    while data:
        data = data[os.write(fd, data):]


def relay(agent, request, reply):
    """One in-flight RPC per connection; callbacks may refuse or alter a frame."""
    child = subprocess.Popen([str(agent), '--stdio'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0)
    def terminate(_signal, _frame):
        raise SystemExit(0)
    previous = signal.signal(signal.SIGTERM, terminate)
    try:
        while (incoming := frame(0)) is not None:
            if not request(incoming):
                break
            write(child.stdin.fileno(), incoming['header']+incoming['body'])
            outgoing = frame(child.stdout.fileno())
            if outgoing is None:
                break
            data = reply(outgoing)
            if data is None:
                break
            write(1, data)
    except BrokenPipeError:
        pass
    finally:
        signal.signal(signal.SIGTERM, previous)
        child.stdin.close()
        try:
            child.wait(timeout=2)
        except subprocess.TimeoutExpired:
            child.terminate()
            try:
                child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        child.stdout.close()
