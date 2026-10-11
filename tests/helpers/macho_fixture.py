"""Hand-assembled Mach-O images for the reader's tests: every value is ours.

image() lays out one well-formed 64-bit image and returns its bytes with the
facts a reader must report and the file offsets of the fields that hostile
variants overwrite. fat() wraps slices in a universal header, cache_image()
describes a shared-cache library as it sits in memory, and sparse() writes
the loaded-image container that tests/macho-image.c reads with layout=sparse.
"""
import struct
import uuid as uuids

ARM64, X86_64 = 0x0100000c, 0x01000007
ARM64E = 0x80000002
MH_EXECUTE, MH_DYLIB = 2, 6
MH_PIE, MH_DYLIB_IN_CACHE = 0x200000, 0x80000000
N_SO, N_OSO, N_BNSYM, N_FUN, N_ENSYM = 0x64, 0x66, 0x2e, 0x24, 0x4e
UUID = uuids.UUID('0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0')


def uleb(n):
    out = bytearray()
    while True:
        out.append(n & 0x7f | (0x80 if n >> 7 else 0))
        n >>= 7
        if not n: return bytes(out)


def name16(text): return text.encode().ljust(16, b'\0')


def segment(name, vmaddr, vmsize, fileoff, filesize, prot, sections=()):
    body = b''.join(struct.pack('<16s16sQQIIIIIIII', name16(s['name']), name16(name), s['addr'], s['size'], s.get('offset', 0),
                                0, 0, 0, s.get('flags', 0), 0, 0, 0) for s in sections)
    return struct.pack('<II16sQQQQIIII', 0x19, 72 + len(body), name16(name), vmaddr, vmsize, fileoff, filesize, prot, prot, len(sections), 0) + body


def dylib(cmd, path, current=0x10000, compat=0x10000):
    text = path.encode() + b'\0'
    text += b'\0' * (-(24 + len(text)) % 8)
    return struct.pack('<IIIIII', cmd, 24 + len(text), 24, 2, current, compat) + text


class Strings:
    def __init__(self): self.data = bytearray(b' \0')
    def add(self, text):
        if not text: return 1
        at = len(self.data); self.data += text.encode() + b'\0'; return at


def nlist(strx, kind, sect, desc, value): return struct.pack('<IBBHQ', strx, kind, sect, desc, value)


def image(cputype=ARM64, subtype=0, filetype=MH_EXECUTE, flags=MH_PIE | 0x85, base=0x100000000, unixthread=False,
          version_min=False, extra_commands=(), extra_symbols=(), starts=None, strings_tail=b''):
    """One image: __PAGEZERO, __TEXT, __DATA, __LINKEDIT. Returns (bytes, facts)."""
    text_size, data_off, link_off = 0x1000, 0x1000, 0x2000
    code = 0x800
    functions = [('_main', 0x00, 0x40, True), ('_helper', 0x40, 0x20, True), ('_local', 0x60, 0x10, False)]
    hidden = 0x70  # a function with no symbol: only LC_FUNCTION_STARTS knows it
    strings = Strings()
    symbols, debug = [], []
    # Locals, then the debug map as ld writes it, then externals and undefined.
    local = [nlist(strings.add('_local'), 0x0e, 1, 0, base + code + 0x60)]
    stabs = [nlist(strings.add('/src/owned/'), N_SO, 0, 0, 0), nlist(strings.add('fixture.c'), N_SO, 0, 0, 0),
             nlist(strings.add('/obj/owned/fixture.o'), N_OSO, 0, 1, 0x65000000)]
    for name, at, size, _ in functions:
        stabs += [nlist(1, N_BNSYM, 1, 0, base + code + at), nlist(strings.add(name), N_FUN, 1, 0, base + code + at),
                  nlist(1, N_FUN, 0, 0, size), nlist(1, N_ENSYM, 1, 0, size)]
        debug.append(dict(name=name, address=base + code + at, size=size))
    stabs.append(nlist(1, N_SO, 1, 0, 0))
    external = [nlist(strings.add(name), 0x0f, 1, 0, base + code + at) for name, at, _, ext in functions if ext]
    external.append(nlist(strings.add('_counter'), 0x0f, 4, 0, base + data_off + 0x10))
    undefined = [nlist(strings.add('_printf'), 0x01, 0, 0x100, 0)]
    table = local + stabs + external + undefined + [nlist(*row) if isinstance(row, tuple) else row for row in extra_symbols]
    strings.data += strings_tail
    if starts is None:
        starts = uleb(code) + uleb(0x40) + uleb(0x20) + uleb(0x10) + b'\0'
        starts += b'\0' * (-len(starts) % 8)  # a caller's own stream is stored exactly
    starts_off = link_off
    sym_off = starts_off + len(starts)
    str_off = sym_off + 16 * len(table)
    sig_off = str_off + len(strings.data) + (-len(strings.data) % 16)
    signature = b'\xfa\xde\x0c\xc0' + bytes(12)
    link_size = sig_off + len(signature) - link_off
    commands = [
        segment('__PAGEZERO', 0, base, 0, 0, 0),
        segment('__TEXT', base, text_size, 0, text_size, 5, [
            dict(name='__text', addr=base + code, size=0x100, offset=code, flags=0x80000400),
            dict(name='__unwind_info', addr=base + 0x900, size=0x40, offset=0x900),
            dict(name='__eh_frame', addr=base + 0x940, size=0x60, offset=0x940, flags=0x6800000b)]),
        segment('__DATA', base + data_off, 0x2000, data_off, 0x1000, 3, [
            dict(name='__data', addr=base + data_off, size=0x100, offset=data_off),
            dict(name='__bss', addr=base + data_off + 0x1000, size=0x800, flags=1)]),
        segment('__LINKEDIT', base + 0x3000, (link_size + 0xfff) & ~0xfff, link_off, link_size, 1),
        struct.pack('<II16s', 0x1b, 24, UUID.bytes),
        struct.pack('<IIII', 0x24, 16, 0x000a0f00, 0x000e0000) if version_min else struct.pack('<IIIIII', 0x32, 24, 1, 0x000d0000, 0x000e0200, 0),
    ]
    if unixthread:
        words, flavor, pc = (68, 6, 32) if cputype == ARM64 else (42, 4, 16)
        state = bytearray(words * 4); struct.pack_into('<Q', state, pc * 8, base + code)
        commands.append(struct.pack('<IIII', 0x5, 16 + len(state), flavor, words) + state)
    elif filetype == MH_EXECUTE:
        commands.append(struct.pack('<IIQQ', 0x80000028, 24, code, 0))
    if filetype == MH_DYLIB: commands.append(dylib(0xd, '@rpath/libowned.dylib', 0x20304, 0x10000))
    commands.append(dylib(0xc, '/usr/lib/libSystem.B.dylib', 0x54c0000))
    marks = {}
    def add(key, blob): marks[key] = 32 + sum(map(len, commands)); commands.append(blob)
    add('symtab', struct.pack('<IIIIII', 0x2, 24, sym_off, len(table), str_off, len(strings.data)))
    add('dysymtab', struct.pack('<II18I', 0xb, 80, 0, len(local) + len(stabs), len(local) + len(stabs), len(external),
                                len(local) + len(stabs) + len(external), len(undefined), *[0] * 12))
    add('starts', struct.pack('<IIII', 0x26, 16, starts_off, len(starts)))
    add('signature', struct.pack('<IIII', 0x1d, 16, sig_off, len(signature)))
    for blob in extra_commands: add('extra', blob)
    body = b''.join(commands)
    assert 32 + len(body) <= code, len(body)
    out = bytearray(sig_off + len(signature))
    out[:32] = struct.pack('<IIIIIIII', 0xfeedfacf, cputype, subtype, filetype, len(commands), len(body), flags, 0)
    out[32:32 + len(body)] = body
    out[code:code + 0x100] = bytes(range(256))
    out[starts_off:starts_off + len(starts)] = starts
    out[sym_off:str_off] = b''.join(table)
    out[str_off:str_off + len(strings.data)] = strings.data
    out[sig_off:] = signature
    at = dict(ncmds=16, sizeofcmds=20, first_command=32, text=32 + 72, data=32 + 72 + 72 + 3 * 80, linkedit=32 + 72 + 72 + 3 * 80 + 72 + 2 * 80,
              sym_off=sym_off, str_off=str_off, starts_off=starts_off, **marks)
    at['uuid'] = at['linkedit'] + 72
    facts = dict(uuid=str(UUID).upper(), cputype=cputype, subtype=subtype, filetype=filetype, flags=flags, base=base,
                 entry=base + code if filetype == MH_EXECUTE or unixthread else 0, symbols=len(table), strings=len(strings.data),
                 debug=debug, functions=[(n, base + code + a, s) for n, a, s, _ in functions], hidden=base + code + hidden,
                 text_end=base + code + 0x100, counter=base + data_off + 0x10, at=at, commands=len(commands),
                 locals=len(local) + len(stabs), externals=len(external), undefined=len(undefined))
    return bytes(out), facts


def fat(slices, wide=False, align=12):
    """slices: (cputype, subtype, bytes). Returns the universal file."""
    each = 32 if wide else 20
    at = (8 + each * len(slices) + (1 << align) - 1) & -(1 << align)
    head = struct.pack('>II', 0xcafebabf if wide else 0xcafebabe, len(slices)); body = bytearray()
    for cputype, subtype, blob in slices:
        head += struct.pack('>IIQQII', cputype, subtype, at, len(blob), align, 0) if wide else struct.pack('>IIIII', cputype, subtype, at, len(blob), align)
        body += blob + bytes(-len(blob) % (1 << align)); at += len(blob) + (-len(blob) % (1 << align))
    start = (len(head) + (1 << align) - 1) & -(1 << align)
    return head + bytes(start - len(head)) + bytes(body)


def sparse(path, extent, ranges):
    """ranges: (offset, bytes) pieces of a loaded image; everything else is unmapped."""
    with open(path, 'wb') as out:
        out.write(b'XMOSPRS1' + struct.pack('<QQ', extent, len(ranges)))
        for offset, blob in ranges: out.write(struct.pack('<QQ', offset, len(blob)))
        for _, blob in ranges: out.write(blob)


def cache_image():
    """A library inside a dyld shared cache, as mapped: arm64e, split segments,
    and a __LINKEDIT shared by the whole cache a gigabyte above the header
    with a 400 MiB string table. Returns (extent, ranges, facts); file offsets
    are offsets in the cache file, which is not part of the fixture."""
    text, cache_off = 0x180028000, 0x28000
    link_vm, link_off, link_size = text + 0x40000000, 0x30000000, 0x20000000
    str_off, str_size = link_off + 0x1000000, 400 << 20
    sym_off, starts_off = link_off + 0x4000, link_off + 0x8000
    names = [('_owned_first', 0x100), ('_owned_middle', (200 << 20) + 5), ('_owned_last', str_size - 0x40)]
    code = 0x4000
    table = b''.join(nlist(strx, 0x0f, 1, 0, text + code + 0x40 * i) for i, (_, strx) in enumerate(names))
    starts = uleb(code) + uleb(0x40) + uleb(0x40) + b'\0'
    commands = [
        segment('__TEXT', text, 0x8000, cache_off, 0x8000, 5, [dict(name='__text', addr=text + code, size=0x1000, offset=cache_off + code, flags=0x80000400),
                                                              dict(name='__unwind_info', addr=text + 0x6000, size=0x80, offset=cache_off + 0x6000)]),
        segment('__DATA_CONST', text + 0x10000000, 0x4000, 0x10000000, 0x4000, 3, [dict(name='__const', addr=text + 0x10000000, size=0x100, offset=0x10000000)]),
        segment('__AUTH_CONST', text + 0x18000000, 0x4000, 0x18000000, 0x4000, 3, [dict(name='__auth_got', addr=text + 0x18000000, size=0x40, offset=0x18000000)]),
        segment('__DATA_DIRTY', text + 0x20000000, 0x4000, 0x20000000, 0x4000, 3, [dict(name='__data', addr=text + 0x20000000, size=0x40, offset=0x20000000)]),
        segment('__LINKEDIT', link_vm, link_size, link_off, link_size, 1),
        dylib(0xd, '/usr/lib/system/libowned_c.dylib', 0x5010000),
        struct.pack('<II16s', 0x1b, 24, UUID.bytes),
        struct.pack('<IIIIII', 0x32, 24, 1, 0x001a0000, 0x001a0000, 0),
        struct.pack('<IIIIII', 0x2, 24, sym_off, len(names), str_off, str_size),
        struct.pack('<II18I', 0xb, 80, 0, 0, 0, len(names), len(names), 0, *[0] * 12),
        struct.pack('<IIII', 0x26, 16, starts_off, len(starts)),
    ]
    body = b''.join(commands)
    header = struct.pack('<IIIIIIII', 0xfeedfacf, ARM64, ARM64E, MH_DYLIB, len(commands), len(body), MH_DYLIB_IN_CACHE | 0x85, 0)
    page = bytearray(0x8000); page[:32 + len(body)] = header + body
    page[code:code + 16] = bytes(range(16)); page[0x6000:0x6004] = struct.pack('<I', 1)
    link = link_vm - text
    ranges = [(0, bytes(page)), (link + sym_off - link_off, table), (link + starts_off - link_off, starts)]
    for name, strx in names:  # only the string pages that symbols point into exist
        start = strx & ~0xfff
        blob = bytearray(0x1000); blob[strx - start:strx - start + len(name) + 1] = name.encode() + b'\0'
        ranges.append((link + str_off - link_off + start, bytes(blob)))
    facts = dict(uuid=str(UUID).upper(), text=text, symbols=[(name, text + code + 0x40 * i) for i, (name, _) in enumerate(names)],
                 extent=link + link_size, string_size=str_size, mapped=sum(len(blob) for _, blob in ranges))
    return link + link_size, ranges, facts
