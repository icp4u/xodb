#!/usr/bin/env python3
"""Ranged V8 layout: libdw oracle, resumable limits, and no partial certification."""
import argparse
import json
import os
from pathlib import Path
import struct
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', type=Path, required=True)
p.add_argument('--sanitize', action='store_true')
a = p.parse_args()
os.umask(0o022)
root = Path(__file__).resolve().parents[1]
os.chdir(root)
w = a.work.resolve()
w.mkdir(parents=True, mode=0o755, exist_ok=True)
exe = w / 'ranged'
flags = ['-O1', '-fsanitize=address,undefined', '-fno-omit-frame-pointer'] if a.sanitize else ['-O2']
subprocess.run(['clang' if a.sanitize else 'cc', '-std=c11', '-g', *flags,
                '-Wall', '-Wextra', '-Werror', 'tests/javascript-ranged.c',
                'src/language/javascript_ranged.c', 'src/language/javascript_layout.c',
                'src/debug/dwarf_cursor.c', 'src/debug/dwarf_index.c', 'src/binary/object.c', '-ldw', '-lelf',
                '-o', str(exe)], check=True, timeout=60)
rows = []

def run(name, path, want='ok', fields='oracle'):
    r = subprocess.run([str(exe), str(path), want, fields, str(w / (name + '.names'))], capture_output=True, text=True, timeout=45)
    (w / (name + '.log')).write_text(r.stdout + r.stderr)
    assert r.returncode == 0, (name, r.returncode, r.stdout, r.stderr)
    rows.append({'name': name, 'status': 'pass', 'stdout': r.stdout, 'stderr': r.stderr})

for compiler in ('g++', 'clang++'):
    for version in (2, 3, 4, 5):
        for bad in (False, True):
            name = compiler + str(version) + ('-bad' if bad else '-good')
            path = w / name
            subprocess.run([compiler, '-std=c++17', '-O0', '-gdwarf-' + str(version),
                            '-fno-eliminate-unused-debug-types', '-DWRONG_LAYOUT=' + ('8' if bad else '0'),
                            'tests/fixtures/javascript/layout.cc', '-o', str(path)], check=True, timeout=30)
            run(name, path, 'JavaScriptDwarfLayoutMismatch' if bad else 'ok')

def elf(path, info, abbrev, big=False, wide=False):
    order = '>' if big else '<'
    names = b'\0.shstrtab\0.debug_info\0.debug_abbrev\0'
    sections = [(1, 3, names), (11, 1, info), (23, 1, abbrev)]
    data = bytearray(64)
    headers = [bytes(64)]
    for name, kind, payload in sections:
        offset = len(data)
        data += payload
        headers.append(struct.pack(order + 'IIQQQQIIQQ', name, kind, 0, 0, offset, len(payload), 0, 0, 1, 0))
    table = len(data)
    data += b''.join(headers)
    data[:64] = struct.pack(order + '16sHHIQQQIHHHHHH',
                           b'\x7fELF\x02' + bytes([2 if big else 1, 1]) + bytes(9),
                           2, 62, 1, 0, 0, table, 0, 64, 0, 0, 64, len(headers), 1)
    path.write_bytes(data)

def unit(body, big=False, wide=False, address_size=8):
    order = '>' if big else '<'
    content = struct.pack(order + ('HQB' if wide else 'HIB'), 4, 0, address_size) + body
    return (struct.pack(order + 'IQ', 0xffffffff, len(content)) if wide else struct.pack(order + 'I', len(content))) + content

abbrev = bytes([1, 0x11, 1, 0, 0, 2, 0x39, 1, 3, 8, 0, 0,
                3, 2, 1, 3, 8, 0, 0, 4, 0x0d, 0, 3, 8, 0x1c, 0x0b, 0, 0, 0])
prefix = b'\x01\x02v8\0\x02internal\0\x03JSArray\0'
member = b'\x04kLengthOffset\0\x18'
body = prefix + member + b'\0\0\0\0'
for big in (False, True):
    for wide in (False, True):
        name = f'order-{big}-wide-{wide}'
        path = w / name
        elf(path, unit(body, big, wide), abbrev, big, wide)
        run(name, path, fields='1')
cases = [
    ('wrong-address', unit(body, address_size=4), abbrev, 'JavaScriptDwarfMalformed', '0'),
    ('late-conflict', unit(body) + unit(prefix + member[:-1] + b'\x19\0\0\0\0'), abbrev, 'JavaScriptDwarfLayoutMismatch', '0'),
    ('unrelated-namespace', unit(body.replace(b'v8\0', b'other\0')), abbrev, 'ok', '0'),
    ('unrelated-owner', unit(body.replace(b'JSArray\0', b'Other\0')), abbrev, 'ok', '0'),
    ('trailing-byte', unit(body) + b'\xff', abbrev, 'JavaScriptDwarfMalformed', '0'),
    ('bad-abbreviation', unit(prefix + b'\x7f\0\0\0\0'), abbrev, 'JavaScriptDwarfMalformed', '0'),
    ('missing-abbreviation', unit(body), b'', 'JavaScriptDwarfMalformed', '0'),
    # A block is an offset into .debug_info, never an integer constant.
    ('block-constant', unit(prefix + member[:-1] + b'\x01\x18\0\0\0\0'),
     abbrev.replace(b'\x1c\x0b', b'\x1c\x0a'), 'JavaScriptDwarfConstantUnsupported', '0'),
]
for name, info, ab, want, fields in cases:
    path = w / name
    elf(path, info, ab)
    run(name, path, want, fields)
# Put the real CU beyond 5 GiB, without materializing the intervening bytes.
path = w / 'sparse-large'
elf(path, unit(body), abbrev)
with path.open('r+b') as f:
    header = f.read(64)
    table = struct.unpack_from('<Q', header, 40)[0]
    far = 5 * 1024 * 1024 * 1024 + 4096
    f.seek(far)
    f.write(unit(body))
    f.seek(table + 2 * 64 + 24)
    f.write(struct.pack('<Q', far))
run('sparse-large', path, fields='1')
# Structural unsupported forms must not look like an absent DWARF profile.
for encoding in ('zlib', 'zlib-gnu'):
    path = w / encoding
    subprocess.run(['objcopy', '--compress-debug-sections=' + encoding,
                    str(w / 'g++4-good'), str(path)], check=True, timeout=10)
    run(encoding, path, 'limit', '0')
path = w / 'stripped'
subprocess.run(['objcopy', '--strip-debug', str(w / 'g++4-good'), str(path)], check=True, timeout=10)
run('stripped', path, fields='0')
(w / 'results.json').write_text(json.dumps({'status': 'pass', 'checks': rows}, indent=2) + '\n')
print('Ranged JavaScript DWARF checks passed:', len(rows))
