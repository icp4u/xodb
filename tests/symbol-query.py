#!/usr/bin/env python3
"""Pinned, resumable symbol lookup: ELF oracle, sparse files, and late failures."""
import argparse
import json
import os
from pathlib import Path
import struct
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', type=Path, required=True)
p.add_argument('--sanitize', action='store_true')
p.add_argument('--image', type=Path, help='Optional real image for a libelf comparison')
a = p.parse_args()
os.umask(0o022)
root = Path(__file__).resolve().parents[1]
os.chdir(root)
w = a.work.resolve()
w.mkdir(parents=True, mode=0o755, exist_ok=True)
exe = w / 'symbols'
flags = ['-O1', '-fsanitize=address,undefined', '-fno-omit-frame-pointer'] if a.sanitize else ['-O2']
subprocess.run(['clang' if a.sanitize else 'cc', '-std=c11', '-g', *flags,
                '-Wall', '-Wextra', '-Werror', 'tests/symbol-query.c',
                'src/binary/symbol_query.c', 'src/binary/object.c', '-lelf',
                '-o', str(exe)], check=True, timeout=60)
rows = []


def run(name, path, want='ok', reason='-', mode='normal', names=('wanted', 'missing'), known=True):
    r = subprocess.run([str(exe), str(path), want, reason, mode, *names],
                       capture_output=True, text=True, timeout=90)
    (w / (name + '.log')).write_text(r.stdout + r.stderr)
    assert r.returncode == 0, (name, r.returncode, r.stdout, r.stderr)
    if known and want == 'ok':
        assert 'symbol wanted present=1 address=4198404 size=4 section=2 type=1\n' in r.stdout, (name, r.stdout)
        if 'missing' in names:
            assert 'symbol missing present=0 address=0 size=0 section=0 type=0\n' in r.stdout
    rows.append({'name': name, 'status': 'pass', 'stdout': r.stdout, 'stderr': r.stderr})


def fixture(path, wide=True, big=False, entries=None, dyn=None, strings=b'\0wanted\0other\0',
            table_flags=0, string_flags=0, entry_size=None, link=3, string_type=3,
            tail=b'', sparse=False, data_flags=3):
    order = '>' if big else '<'
    size, header_size = (24, 64) if wide else (16, 52)
    entries = [(1, 0x11, 2, 0x401004, 4)] if entries is None else entries

    def symbols(values):
        raw = bytearray(size)  # mandatory empty symbol
        for name, info, section, address, length in values:
            raw += (struct.pack(order + 'IBBHQQ', name, info, 0, section, address, length) if wide else
                    struct.pack(order + 'IIIBBH', name, address, length, info, 0, section))
        return bytes(raw)

    shnames = b'\0.shstrtab\0.data\0.strtab\0.symtab\0.dynsym\0'
    # Symbol and string records both cross page boundaries. The file can put
    # their tables beyond 5 GiB without allocating intervening disk blocks.
    far = 5 * 1024 ** 3 if sparse else 0
    sections = [
        (1, 3, 0, 0, 256, shnames, 0, 0),
        (11, 1, data_flags, 0x401000, 512, bytes(256), 0, 0),
        (17, string_type, string_flags, 0, far + 3 * 16384 - 4, strings, 0, 0),
        (25, 2, table_flags, 0, far + 16384 - 12, symbols(entries) + tail,
         link, size if entry_size is None else entry_size),
    ]
    if dyn is not None:
        sections.append((33, 11, 0, 0, far + 4 * 16384 - 12, symbols(dyn), 3, size))
    headers = [bytes(64 if wide else 40)]
    end = header_size
    with path.open('wb') as f:
        for name, kind, flags, address, offset, data, linked, stride in sections:
            f.seek(offset)
            f.write(data)
            end = max(end, offset + len(data))
            headers.append(struct.pack(order + ('IIQQQQIIQQ' if wide else 'IIIIIIIIII'),
                                       name, kind, flags, address, offset, len(data), linked, 0, 1, stride))
        table = (end + 7) & ~7
        f.seek(table)
        f.write(b''.join(headers))
        f.seek(0)
        ident = b'\x7fELF' + bytes([2 if wide else 1, 2 if big else 1, 1]) + bytes(9)
        f.write(struct.pack(order + ('16sHHIQQQIHHHHHH' if wide else '16sHHIIIIIHHHHHH'),
                            ident, 2, 62 if wide else 3, 1, 0, 0, table, 0,
                            header_size, 0, 0, 64 if wide else 40, len(headers), 1))
    return path


good = (1, 0x11, 2, 0x401004, 4)
for wide in (False, True):
    for big in (False, True):
        name = f'wide-{wide}-big-{big}'
        run(name, fixture(w / name, wide=wide, big=big))
        name += '-duplicates'
        run(name, fixture(w / name, wide=wide, big=big, dyn=[good]))

cases = [
    ('weak-duplicate', {'dyn': [(1, 0x21, 2, 0x401004, 4)]}, 'ok', '-'),
    ('late-address-conflict', {'entries': [good] + [(8, 0x11, 2, 0x401008, 4)] * 300,
                               'dyn': [(1, 0x11, 2, 0x401008, 4)]}, 'malformed', 'SymbolDefinitionConflict'),
    ('late-size-conflict', {'dyn': [(1, 0x11, 2, 0x401004, 8)]}, 'malformed', 'SymbolDefinitionConflict'),
    ('late-type-conflict', {'dyn': [(1, 0x12, 2, 0x401004, 4)]}, 'malformed', 'SymbolDefinitionConflict'),
    ('tls-type', {'entries': [(1, 0x16, 2, 0x401004, 4)]}, 'limit', 'SymbolTlsUnsupported'),
    ('tls-section', {'data_flags': 0x403}, 'limit', 'SymbolTlsUnsupported'),
    ('entry-stride', {'entry_size': 16}, 'malformed', 'SymbolTableExtent'),
    ('entry-tail', {'tail': b'\0'}, 'malformed', 'SymbolTableExtent'),
    ('bad-link', {'link': 999}, 'malformed', 'SymbolTableExtent'),
    ('link-nonstrings', {'string_type': 1}, 'malformed', 'SymbolStringTableType'),
    ('compressed-symbols', {'table_flags': 0x800}, 'limit', 'SymbolCompressionUnsupported'),
    ('compressed-strings', {'string_flags': 0x800}, 'limit', 'SymbolCompressionUnsupported'),
    ('name-offset', {'entries': [(12345, *good[1:])]}, 'malformed', 'SymbolNameExtent'),
    ('unterminated-name', {'strings': b'\0wanted'}, 'malformed', 'SymbolNameExtent'),
    ('section-extent', {'entries': [(1, 0x11, 998, 0x401004, 4)]}, 'malformed', 'SymbolSectionExtent'),
    ('section-reserved', {'entries': [(1, 0x11, 0xff01, 0x401004, 4)]}, 'malformed', 'SymbolSectionExtent'),
    ('section-extended', {'entries': [(1, 0x11, 0xffff, 0x401004, 4)]}, 'limit', 'SymbolExtendedIndexUnsupported'),
    ('address-low', {'entries': [(1, 0x11, 2, 0x400fff, 4)]}, 'malformed', 'SymbolAddressExtent'),
    ('address-high', {'entries': [(1, 0x11, 2, 0x401101, 4)]}, 'malformed', 'SymbolAddressExtent'),
    ('size-high', {'entries': [(1, 0x11, 2, 0x401004, 256)]}, 'malformed', 'SymbolAddressExtent'),
    ('size-overflow', {'entries': [(1, 0x11, 2, 0x401004, 2 ** 64 - 1)]}, 'malformed', 'SymbolAddressExtent'),
]
for name, kwargs, want, reason in cases:
    run(name, fixture(w / name, **kwargs), want, reason)
for section in (0, 0xfff1, 0xfff2):
    name = f'no-address-{section}'
    run(name, fixture(w / name, entries=[(1, 0x11, section, 0x401004, 4)]), known=False)
run('nonallocated', fixture(w / 'nonallocated', data_flags=0), known=False)
run('empty', fixture(w / 'empty', entries=[]), known=False)
run('same-request', fixture(w / 'same-request'), names=('wanted',) * 256)
long = 'x' * 255
run('long-name', fixture(w / 'long-name', strings=b'\0' + long.encode() + b'\0'),
    names=(long,), mode='tiny', known=False)
run('long-nonmatch', fixture(w / 'long-nonmatch', strings=b'\0wanted-long-name\0'), known=False)
entries = [good] + [(8, 0x11, 2, 0x401008, 4)] * 1300
run('tiny', fixture(w / 'tiny', entries=entries), mode='tiny')
run('midway-change', fixture(w / 'midway-change', entries=entries),
    'changed', 'SymbolFileChanged', mode='change')
for big in (False, True):
    name = f'sparse-big-{big}'
    run(name, fixture(w / name, big=big, sparse=True), mode='tiny')
if a.image:
    run('real-image', a.image, names=('_ZN2v88internal7Version6major_E',
        '_ZN2v88internal7Version6minor_E', '_ZN2v88internal7Version6build_E',
        '_ZN2v88internal7Version6patch_E', '_ZN2v88internal7Version15version_string_E',
        'v8dbg_class_JSArray__length__Object', 'main', 'xodb_missing_symbol'), known=False)
(w / 'results.json').write_text(json.dumps({'status': 'pass', 'checks': rows}, indent=2) + '\n')
print('Ranged symbol checks passed:', len(rows))
