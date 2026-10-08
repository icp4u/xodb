#!/usr/bin/env python3
"""Owned compiler and synthetic ELF/DWARF source authorization fixtures."""
import argparse
import json
import os
import re
from pathlib import Path
import struct
import subprocess


def synthetic(path, version=5, wide=True, little=True, dwarf64=False,
              bad_tail=False, bad_directory=False, forged_offset=False, odd_path=None, odd_directory=False, odd_directory_index=0, after_terminator=b''):
    endian = '<' if little else '>'
    pack = lambda code, *v: struct.pack(endian + code, *v)
    off = 'Q' if dwarf64 else 'I'
    length = lambda b: (pack('IQ', 0xffffffff, len(b)) if dwarf64 else pack('I', len(b))) + b
    comp = b'/synthetic/build\0'
    common = bytes([1] + ([1] if version >= 4 else []) + [1, 251, 14, 13]) + bytes(12)
    include = b'/../../include\0' if odd_directory else b'include\0'
    if version == 5:
        dirs = bytes([1, 1, 8, 2]) + comp + include
        files = bytes([2, 1, 8, 2, 15, 2]) + b'fixture.c\0\0header.h\0' + bytes([3 if bad_directory else 1])
    else:
        dirs = include + b'\0'
        files = b'fixture.c\0\0\0\0header.h\0' + bytes([3 if bad_directory else 1, 0, 0, 0])
    if odd_path is not None:
        # Bad rows both before and after the valid row catch parsers that
        # either abort early or discard an already found valid filename.
        odd = odd_path.encode() + b'\0'
        if version == 5:
            files = bytes([2, 1, 8, 2, 15, 4]) + odd + bytes([odd_directory_index]) + files[6:] + odd + bytes([odd_directory_index])
        else:
            files = odd + bytes([odd_directory_index, 0, 0]) + files[:-1] + odd + bytes([odd_directory_index, 0, 0, 0])
    header = common + dirs + files + after_terminator + (b'\xff' if bad_tail else b'')
    line = length(pack('H', version) + (bytes([8 if wide else 4, 0]) if version == 5 else b'') + pack(off, len(header)) + header)
    abbrev = bytes([1, 0x11, 0, 0x10, 0x17, 0x1b, 8, 0, 0, 0])
    unit = pack('H', version)
    unit += bytes([1, 8 if wide else 4]) + pack(off, 0) if version == 5 else pack(off, 0) + bytes([8 if wide else 4])
    info = length(unit + bytes([1]) + pack(off, len(line) if forged_offset else 0) + comp)
    sections = [('.shstrtab', b''), ('.debug_info', info), ('.debug_abbrev', abbrev), ('.debug_line', line)]
    names = b'\0' + b''.join(n.encode() + b'\0' for n, _ in sections)
    sections[0] = ('.shstrtab', names)
    ehsize, shsize = (64, 64) if wide else (52, 40)
    data = bytearray(ehsize)
    rows = [bytes(shsize)]
    for n, body in sections:
        at = len(data); data.extend(body)
        args = (names.index(n.encode() + b'\0'), 3 if n == '.shstrtab' else 1, 0, 0, at, len(body), 0, 0, 1, 0)
        rows.append(pack('IIQQQQIIQQ' if wide else 'IIIIIIIIII', *args))
    shoff = len(data); data.extend(b''.join(rows))
    ident = b'\x7fELF' + bytes([2 if wide else 1, 1 if little else 2, 1]) + bytes(9)
    header = ident + pack('HHI', 2, 62 if wide else 3, 1)
    header += pack('QQQIHHHHHH' if wide else 'IIIIHHHHHH', 0, 0, shoff, 0, ehsize, 0, 0, shsize, len(rows), 1)
    data[:ehsize] = header; path.write_bytes(data)


def multi_unit(path, units, files):
    def leb(n):
        out = bytearray()
        while n >= 128:
            out.append((n & 127) | 128); n >>= 7
        return bytes(out) + bytes([n])
    strings = bytearray(b'/synthetic/source\0')
    info, line = bytearray(), bytearray()
    abbrev = bytes([1, 0x11, 0, 0x10, 0x17, 0x1b, 8, 0, 0, 0])
    target = ''
    for cu in range(units):
        rows = bytearray()
        for f in range(files):
            target = f'unit-{cu}-header-{f}.h'
            rows += struct.pack('<I', len(strings)) + b'\0'
            strings += target.encode() + b'\0'
        header = bytes([1, 1, 1, 251, 14, 13]) + bytes(12)
        header += bytes([1, 1, 0x1f, 1]) + struct.pack('<I', 0)
        header += bytes([2, 1, 0x1f, 2, 0x0f]) + leb(files) + rows
        body = struct.pack('<HBBI', 5, 8, 0, len(header)) + header
        unit = struct.pack('<HBBI', 5, 1, 8, 0) + b'\x01' + struct.pack('<I', len(line)) + b'/synthetic/source\0'
        info += struct.pack('<I', len(unit)) + unit
        line += struct.pack('<I', len(body)) + body
    sections = [('.shstrtab', b''), ('.debug_info', info), ('.debug_abbrev', abbrev),
                ('.debug_line', line), ('.debug_line_str', strings)]
    names = b'\0' + b''.join(n.encode() + b'\0' for n, _ in sections)
    sections[0] = ('.shstrtab', names)
    data, headers = bytearray(64), [bytes(64)]
    for name, body in sections:
        offset = len(data); data += body
        headers.append(struct.pack('<IIQQQQIIQQ', names.index(name.encode() + b'\0'),
                       3 if name == '.shstrtab' else 1, 0, 0, offset, len(body), 0, 0, 1, 0))
    table = len(data); data += b''.join(headers)
    data[:64] = struct.pack('<16sHHIQQQIHHHHHH', b'\x7fELF\x02\x01\x01' + bytes(9),
                           2, 62, 1, 0, 0, table, 0, 64, 0, 0, 64, len(headers), 1)
    path.write_bytes(data)
    return '/synthetic/source/' + target


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--check', required=True, type=Path)
    p.add_argument('--work', required=True, type=Path)
    a = p.parse_args(); os.umask(0o022)
    a.work.mkdir(parents=True, exist_ok=True)
    check = a.check.resolve(); work = a.work.resolve(); results = []

    def run(image, source, want):
        result = subprocess.run([str(check), str(image), str(source), want], capture_output=True, text=True, timeout=10)
        results.append({'image': image.name, 'source': Path(source).name, 'want': want, 'exit': result.returncode, 'output': result.stdout, 'error': result.stderr})
        (work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        if result.returncode:
            raise AssertionError(results[-1])
        return result.stdout

    (work / 'fixture.c').write_text('#include "fixture.h"\nint main(void) { return value(3); }\n')
    (work / 'fixture.h').write_text('static int value(int x) { return x * 2; }\n')
    for cc in ['gcc', 'clang']:
        for version in [2, 3, 4, 5]:
            image = work / f'{cc}-{version}'
            subprocess.run([cc, '-O0', f'-gdwarf-{version}', '-Wl,--build-id', 'fixture.c', '-o', str(image)], cwd=work, check=True, timeout=30)
            for source in ['fixture.c', 'fixture.h', 'unrelated.txt']:
                run(image, work / source, 'not-found' if source == 'unrelated.txt' else 'ok')
    for version in [2, 3, 4, 5]:
        for wide in [False, True]:
            for little in [False, True]:
                for dwarf64 in [False, True]:
                    image = work / f'synthetic-{version}-{wide}-{little}-{dwarf64}'
                    synthetic(image, version, wide, little, dwarf64)
                    run(image, '/synthetic/build/fixture.c', 'ok')
                    run(image, '/synthetic/build/include/header.h', 'ok')
                    run(image, '/synthetic/build/other.c', 'not-found')
                    run(image, '/synthetic/build/sub/../fixture.c', 'ok')
                    run(image, '/synthetic/build/include/../other.c', 'not-found')
                    run(image, '/synthetic/../../fixture.c', 'malformed')
    # A bad path spelling in one valid DWARF row must not disable other
    # source files, nor authorize a filename obtained by stripping its slash.
    for version in [2, 3, 4, 5]:
        for wide in [False, True]:
            for little in [False, True]:
                for dwarf64 in [False, True]:
                    for tag, odd in [('absolute-escape', '/../../blocked.c'),
                                     ('relative-escape', '../../../blocked.c'),
                                     ('trailing-slash', '/synthetic/build/blocked.c/'),
                                     ('trailing-dot', '/synthetic/build/blocked.c/.'),
                                     ('dot', '.'), ('empty', '')]:
                        image = work / f'odd-{tag}-{version}-{wide}-{little}-{dwarf64}'
                        synthetic(image, version, wide, little, dwarf64, odd_path=odd)
                        # In DWARF 2-4 an empty name terminates the table;
                        # the apparent later rows are not entries at all.
                        empty_end = version < 5 and odd == ''
                        run(image, '/synthetic/build/fixture.c', 'not-found' if empty_end else 'ok')
                        run(image, '/synthetic/build/include/header.h', 'not-found' if empty_end else 'ok')
                        run(image, '/synthetic/build/blocked.c', 'not-found')
                        invalid = work / f'odd-bad-index-{tag}-{version}-{wide}-{little}-{dwarf64}'
                        synthetic(invalid, version, wide, little, dwarf64, odd_path=odd, odd_directory_index=3)
                        run(invalid, '/synthetic/build/fixture.c', 'not-found' if empty_end else 'malformed')
                    image = work / f'odd-directory-{version}-{wide}-{little}-{dwarf64}'
                    synthetic(image, version, wide, little, dwarf64, odd_directory=True)
                    run(image, '/synthetic/build/fixture.c', 'ok')
                    run(image, '/synthetic/build/include/header.h', 'not-found')
    # Padding, plausible filenames and invalid LEBs beyond the legacy
    # terminator are not part of the table. Compare the standard consumer.
    for version in [2, 3, 4]:
        for wide in [False, True]:
            for little in [False, True]:
                for dwarf64 in [False, True]:
                    for tag, tail in [('row', b'\0\0\0hidden.c\0\0\0\0\0'),
                                      ('padding', bytes(16)), ('invalid', b'\x80' * 11)]:
                        image = work / f'terminator-{tag}-{version}-{wide}-{little}-{dwarf64}'
                        synthetic(image, version, wide, little, dwarf64, after_terminator=tail)
                        run(image, '/synthetic/build/fixture.c', 'ok')
                        run(image, '/synthetic/build/include/header.h', 'ok')
                        run(image, '/synthetic/build/hidden.c', 'not-found')
                        dump = subprocess.run(['readelf', '--debug-dump=rawline', str(image)],
                                              capture_output=True, text=True, check=True, timeout=10)
                        (work / (image.name + '.readelf.txt')).write_text(dump.stdout + dump.stderr)
                        table = dump.stdout.split('The File Name Table', 1)[1].split('Line Number Statements', 1)[0]
                        assert 'fixture.c' in table and 'header.h' in table and 'hidden.c' not in table, table
    # GCC and clang encode trailing slash paths differently: an empty name
    # or '.', with the apparent filename in the directory table. Test their
    # actual emitted rows as well as synthetic paths containing the slash.
    for cc in ['gcc', 'clang']:
        for version in [2, 3, 4, 5]:
            for tag, suffix in [('slash', '/'), ('dot', '/.')]:
                source = work / f'line-{cc}-{version}-{tag}.c'
                source.write_text('#line 1 "/synthetic/before.c"\nint before(void){return 3;}\n'
                                  f'#line 1 "/synthetic/blocked.c{suffix}"\nint odd(void){{return before();}}\n'
                                  '#line 1 "/synthetic/good.c"\nint main(void){return odd();}\n')
                image = source.with_suffix('')
                subprocess.run([cc, '-O0', f'-gdwarf-{version}', str(source), '-o', str(image)], check=True, timeout=30)
                run(image, '/synthetic/before.c', 'ok')
                legacy_empty = cc == 'gcc' and version < 5 and tag == 'slash'
                run(image, '/synthetic/good.c', 'not-found' if legacy_empty else 'ok')
                dump = subprocess.run(['readelf', '--debug-dump=rawline', str(image)],
                                      capture_output=True, text=True, check=True, timeout=10)
                (work / (image.name + '.readelf.txt')).write_text(dump.stdout + dump.stderr)
                table = dump.stdout.split('The File Name Table', 1)[1].split('Line Number Statements', 1)[0]
                assert 'before.c' in table and ('good.c' in table) != legacy_empty, table
                run(image, '/synthetic/blocked.c', 'not-found')
    # Real compiler-produced out-of-tree paths, as used by Meson/VPATH builds.
    project = work / 'out-of-tree'
    for name in ['build', 'src', 'include']:
        (project / name).mkdir(parents=True, exist_ok=True)
    (project / 'src/main.c').write_text('#include "../include/value.h"\nint main(void){return value();}\n')
    (project / 'include/value.h').write_text('static int value(void){return 0;}\n')
    for cc in ['gcc', 'clang']:
        for version in [4, 5]:
            image = project / 'build' / f'{cc}-{version}'
            subprocess.run([cc, '-O0', f'-gdwarf-{version}', '-Wl,--build-id', '../src/main.c', '-o', image.name], cwd=image.parent, check=True, timeout=30)
            for relative in ['src/main.c', 'include/value.h']:
                run(image, project / relative, 'ok')
                run(image, str(project / 'build') + '/../' + relative, 'ok')
    for kind in ['bad_tail', 'bad_directory', 'forged_offset']:
        image = work / kind; synthetic(image, **{kind: True})
        run(image, '/synthetic/build/fixture.c', 'malformed')
    for units, files in [(1, 3000), (40, 200), (80, 400)]:
        image = work / f'line-strp-{units}x{files}'
        target = multi_unit(image, units, files)
        output = run(image, target, 'ok')
        used = int(re.search(r'\((\d+) bytes,', output)[1])
        # Includes ELF tables and the separate bounded CU cursor. A small
        # allowance covers its minimum pages; growth must track source size.
        assert used <= image.stat().st_size * 6 + 131072, (image.name, used, image.stat().st_size)
        results[-1]['amplification'] = used / image.stat().st_size
    (work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print(f'pass: {len(results)} source authorization checks')


if __name__ == '__main__':
    main()
