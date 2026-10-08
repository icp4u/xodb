#!/usr/bin/env python3
"""Compare ranged EH sections with complete-image libdw on owned fixtures."""
import argparse
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--check', type=Path, required=True)
p.add_argument('--work', type=Path, required=True)
p.add_argument('--node', type=Path)
a = p.parse_args()
os.umask(0o022)
a.work.mkdir(parents=True, exist_ok=True, mode=0o755)
work = a.work.resolve()
check = a.check.resolve()
results = []


def run(image, want='ok', mode=None):
    cmd = [str(check), str(image), want] + ([mode] if mode else [])
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=90)
    row = {'image': image.name, 'want': want, 'exit': r.returncode,
           'output': r.stdout, 'error': r.stderr}
    results.append(row)
    (work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    assert r.returncode == 0, row


fixture = work / 'fixture.c'
fixture.write_text('''volatile int sink;
__attribute__((noinline)) int inner(int x){sink=x;return x+1;}
__attribute__((noinline)) int outer(int x){return inner(x)+sink;}
int main(void){return outer(3);}
''')
for name, flags in [('pie', ['-fPIE', '-pie']), ('exec', ['-fno-pie', '-no-pie']),
                    ('no-header', ['-fno-pie', '-no-pie', '-Wl,--no-eh-frame-hdr'])]:
    image = work / name
    subprocess.run(['cc', '-g', '-O1', '-fasynchronous-unwind-tables', *flags,
                    str(fixture), '-o', str(image)], check=True, timeout=30)
    run(image, mode='mutate')
subprocess.run(['cc', '-m32', '-g', '-O1', '-fno-pic', '-fasynchronous-unwind-tables',
                '-c', str(fixture), '-o', str(work / '32.o')], check=True, timeout=30)
subprocess.run(['ld', '-m', 'elf_i386', '--eh-frame-hdr', '-e', 'main', str(work / '32.o'),
                '-o', str(work / 'elf32')], check=True, timeout=30)
run(work / 'elf32', mode='mutate')


def elf(data):
    wide = data[4] == 2
    endian = '<' if data[5] == 1 else '>'
    shoff = struct.unpack_from(endian + ('Q' if wide else 'I'), data, 40 if wide else 32)[0]
    shsize, count, names = struct.unpack_from(endian + 'HHH', data, 58 if wide else 46)
    fmt = endian + ('IIQQQQIIQQ' if wide else 'IIIIIIIIII')
    headers = [list(struct.unpack_from(fmt, data, shoff + i * shsize)) for i in range(count)]
    strings = headers[names]
    names_data = data[strings[4]:strings[4] + strings[5]]
    sections = {names_data[h[0]:].split(b'\0', 1)[0].decode(): i for i, h in enumerate(headers)}
    return wide, endian, shoff, shsize, fmt, headers, sections


original = (work / 'exec').read_bytes()
wide, endian, shoff, shsize, fmt, headers, sections = elf(original)
eh = sections['.eh_frame']
hdr = sections['.eh_frame_hdr']


def modified(name, index, field, value, want, grow=0):
    data = bytearray(original)
    h = headers[index].copy()
    h[field] = value
    struct.pack_into(fmt, data, shoff + index * shsize, *h)
    image = work / name
    image.write_bytes(data)
    if grow:
        with image.open('r+b') as f:
            f.truncate(grow)
    run(image, want)


modified('compressed', eh, 2, headers[eh][2] | 0x800, 'limit')
modified('oversized', eh, 5, 32 * 1024 * 1024 + 1, 'limit', 64 * 1024 * 1024)
modified('not-allocated', eh, 2, 0, 'malformed')
modified('duplicate', hdr, 0, headers[eh][0], 'malformed')
modified('missing', eh, 0, 0, 'not-found')
modified('bad-alignment', eh, 8, 3, 'malformed')
# ET_REL still requires relocation handling even if the copied section looks sane.
data = bytearray(original)
struct.pack_into(endian + 'H', data, 16, 1)
(work / 'relocatable').write_bytes(data)
run(work / 'relocatable', 'limit')
# Put actual unwind bytes past 3 GiB without allocating a multi-GB buffer/copy.
data = bytearray(original)
h = headers[eh].copy()
payload = data[h[4]:h[4]+h[5]]
h[4] = 3 * 1024**3 + 4096
struct.pack_into(fmt, data, shoff + eh * shsize, *h)
sparse = work / 'sparse-large'
with sparse.open('wb') as f:
    f.write(data)
    f.seek(h[4])
    f.write(payload)
run(sparse, mode='mutate')


def big_endian(path):
    # A complete tiny PPC64 ELF with one independent CIE/FDE and function symbol.
    endian = '>'
    pack = lambda code, *v: struct.pack(endian + code, *v)
    cie = b'\0\0\0\0\x01zR\0\x01\x78\x41\x01\x1b\x0c\x01\x08\x05\x41\x01'
    cie += bytes((-len(cie)) % 4)
    frames = pack('I', len(cie)) + cie
    fde_at = len(frames)
    fde = pack('IiI', fde_at + 4, 0x1000 - (0x2000 + fde_at + 8), 16) + b'\0\x44\x0e\x10'
    frames += pack('I', len(fde)) + fde + bytes(4)
    search = b'\x01\x1b\x03\x3b' + pack('iIii', 0x2000-0x3004, 1, 0x1000-0x3000, 0x2000+fde_at-0x3000)
    strings = b'\0function\0'
    symbols = bytes(24) + pack('IBBHQQ', 1, 0x12, 0, 1, 0x1000, 16)
    names = b'\0.text\0.eh_frame\0.eh_frame_hdr\0.symtab\0.strtab\0.shstrtab\0'
    sections = [('.text', 1, 6, 0x1000, bytes(16), 0, 0, 4, 0),
                ('.eh_frame', 1, 2, 0x2000, frames, 0, 0, 4, 0),
                ('.eh_frame_hdr', 1, 2, 0x3000, search, 0, 0, 4, 0),
                ('.symtab', 2, 0, 0, symbols, 5, 1, 8, 24),
                ('.strtab', 3, 0, 0, strings, 0, 0, 1, 0),
                ('.shstrtab', 3, 0, 0, names, 0, 0, 1, 0)]
    data = bytearray(64)
    rows = [bytes(64)]
    for name, typ, flags, addr, body, link, info, align, entry in sections:
        data += bytes((-len(data)) % align)
        at = len(data)
        data += body
        rows.append(pack('IIQQQQIIQQ', names.index(name.encode()+b'\0'), typ, flags, addr,
                         at, len(body), link, info, align, entry))
    offset = len(data)
    data += b''.join(rows)
    data[:64] = b'\x7fELF\x02\x02\x01' + bytes(9) + pack('HHIQQQIHHHHHH',
        2, 21, 1, 0x1000, 0, offset, 0, 64, 0, 0, 64, len(rows), 6)
    path.write_bytes(data)


big_endian(work / 'big-endian')
run(work / 'big-endian', mode='mutate')
if a.node:
    if a.node.exists():
        run(a.node.resolve(), mode='large')
    else:
        results.append({'image': 'optional-node', 'status': 'skip', 'reason': 'requested image absent'})
        (work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
print('CFI image checks:', len(results))
