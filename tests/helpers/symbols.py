"""Generate a real large executable with enough symbols to require many slices."""
import subprocess
import struct

def build(root, work, count=50000):
    fixture = work/'large'
    assembly = work/'aliases.s'
    with assembly.open('w') as out:
        out.write('.text\n.globl alias_target\nalias_target: ret\n')
        for i in range(count):
            name = f'owned_symbol_{i:05d}_padding_for_discovery'
            out.write(f'.globl {name}\n.set {name}, alias_target\n')
        out.write('.section .note.GNU-stack,"",@progbits\n')
    subprocess.run(['cc','-g','-O0','-fno-pie','-no-pie',
                    str(root/'tests/fixtures/large-symbols.c'),str(assembly),'-o',str(fixture)],
                   check=True, timeout=60)
    assert fixture.stat().st_size > 300*1024*1024
    known = {}
    for line in subprocess.check_output(['nm','-P','--defined-only',str(fixture)],text=True,timeout=30).splitlines():
        parts=line.split()
        if parts[0] in ('reached','alias_target'):known[parts[0]]='0x'+parts[2]
    assert len(known)==2
    return fixture, known

def build_sparse_library(root, work, count=50000):
    """A tiny executable plus a sparse library with symbol tables above 1 GiB."""
    fixture, small, library = work/'fixture', work/'library.small', work/'library.so'
    source = root/'tests/fixtures/sparse-symbols.c'
    assembly = work/'aliases.s'
    with assembly.open('w') as out:
        out.write('.text\n.globl alias_target\n.hidden alias_target\nalias_target: ret\n')
        for i in range(count):
            name = f'owned_hidden_symbol_{i:05d}_padding_for_discovery'
            out.write(f'.globl {name}\n.hidden {name}\n.set {name}, alias_target\n')
        out.write('.section .note.GNU-stack,"",@progbits\n')
    subprocess.run(['cc', '-g', '-O0', '-fno-pie', '-no-pie', str(source), '-ldl',
                    '-o', str(fixture)], check=True, timeout=60)
    subprocess.run(['cc', '-O0', '-fPIC', '-shared', '-DSYMBOL_LIBRARY', str(source),
                    str(assembly), '-o', str(small)], check=True, timeout=60)
    data = small.read_bytes()
    assert data[:6] == b'\x7fELF\x02\x01'
    shoff, = struct.unpack_from('<Q', data, 40)
    entsize, count = struct.unpack_from('<HH', data, 58)
    headers = bytearray(data[shoff:shoff + entsize * count])
    at = 0x48000000
    with library.open('wb') as out:
        out.write(data)
        for i in range(1, count):
            start = i * entsize
            kind, flags = struct.unpack_from('<IQ', headers, start + 4)
            offset, size = struct.unpack_from('<QQ', headers, start + 24)
            if flags & 2 or kind == 8 or not size: continue
            at = (at + 15) & ~15
            out.seek(at); out.write(data[offset:offset + size])
            struct.pack_into('<Q', headers, start + 24, at)
            at += size
        at = (at + 7) & ~7
        out.seek(at); out.write(headers)
        out.seek(40); out.write(struct.pack('<Q', at))
    known = {}
    for line in subprocess.check_output(['nm', '-P', '--defined-only', str(fixture)],
                                        text=True, timeout=30).splitlines():
        name, _, address, *_ = line.split()
        if name in ('symbols_ready', 'reached'): known[name] = '0x' + address
    assert len(known) == 2
    small.unlink()
    return fixture, library, known
