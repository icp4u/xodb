"""GDB remote serial protocol framing for the test stubs and recorders."""


def checksum(body):
    return b'%02x' % (sum(body) & 255)


def escape(payload):
    out = bytearray()
    for byte in payload:
        if byte in b'#$}*': out += bytes((0x7d, byte ^ 0x20))
        else: out.append(byte)
    return bytes(out)


def frame(payload):
    body = escape(payload)
    return b'$' + body + b'#' + checksum(body)


def unescape(body):
    out = bytearray(); i = 0
    while i < len(body):
        if body[i] == 0x7d: out.append(body[i + 1] ^ 0x20); i += 2
        elif body[i] == 0x2a: out += out[-1:] * (body[i + 1] - 29); i += 2
        else: out.append(body[i]); i += 1
    return bytes(out)


def split(buffer):
    """Yield ('ack'|'nak'|'interrupt'|'packet', payload) and leave the rest in buffer."""
    while buffer:
        first = bytes(buffer[0:1])
        if first in (b'+', b'-', b'\x03'):
            del buffer[0]
            yield {b'+': 'ack', b'-': 'nak', b'\x03': 'interrupt'}[first], b''
            continue
        if first != b'$':
            del buffer[0]
            continue
        end = 1
        while end < len(buffer) and buffer[end] != 0x23:
            end += 2 if buffer[end] in (0x7d, 0x2a) else 1
        if end + 2 >= len(buffer): return
        body = bytes(buffer[1:end]); given = bytes(buffer[end + 1:end + 3]).lower()
        del buffer[:end + 3]
        assert given == checksum(body), 'bad checksum in a recorded or received frame'
        yield 'packet', unescape(body)
