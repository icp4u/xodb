#!/usr/bin/env python3
"""Bounded Mach-O DWARF containers: Apple output, bad sections, small budgets.

Fast lane builds the reader and checks four languages plus refusals. The
periodic matrix also checks every published dSYM slice under ASan/UBSan.
"""
import argparse
import json
import os
from pathlib import Path
import struct
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT/'tests/fixtures/macos-names'


def main():
    os.chdir(ROOT)
    os.umask(0o022)
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--work', type=Path, required=True)
    p.add_argument('--matrix', action='store_true')
    p.add_argument('--wrong-result', action='store_true')
    p.add_argument('--wrong-object-result', action='store_true')
    args = p.parse_args()
    work = args.work.resolve()
    work.mkdir(parents=True)
    started = time.monotonic()
    results = dict(status='running', rows=[])
    binary = work/'check'
    command = ['clang' if args.matrix else 'cc', '-std=c11', '-O1', '-g', '-DNDEBUG',
               '-Wall', '-Wextra', '-Werror']
    if args.matrix:
        command += ['-fsanitize=address,undefined', '-fno-sanitize-recover=all']
    command += ['tests/macos-dwarf.c', 'src/debug/macho_dwarf.c', 'src/binary/macho.c',
                '-ldw', '-lelf', '-o', str(binary)]
    run = subprocess.run(command, capture_output=True, text=True, timeout=60)
    (work/'compile.log').write_text(run.stdout+run.stderr)
    assert run.returncode == 0, run.stderr
    object_binary = work/'object-check'
    object_command = command[:command.index('tests/macos-dwarf.c')]+[
        'tests/macos-object.c', 'src/debug/macho_object.c', 'src/debug/macho_dwarf.c',
        'src/binary/macho.c', '-ldw', '-lelf', '-o', str(object_binary)]
    run = subprocess.run(object_command, capture_output=True, text=True, timeout=60)
    (work/'compile-object.log').write_text(run.stdout+run.stderr)
    assert run.returncode == 0, run.stderr

    def object_check(name, object_, pc, expected=None, dwarf_status='ok'):
        linked = FIXTURES/'corpus/out/c/arm64-O2/cprog'
        run = subprocess.run([str(object_binary), str(linked), str(object_), '0', hex(pc), str(32<<20)],
                             capture_output=True, text=True, timeout=15)
        (work/(name+'.log')).write_text(run.stdout+run.stderr)
        assert run.returncode == 0, (name, run.returncode, run.stderr)
        rows = [line.split('\t') for line in run.stdout.splitlines()]
        assert ['map', 'ok'] in rows and ['dwarf', dwarf_status] in rows, (name, rows)
        if expected is not None:
            assert ['pc', 'ok', format(expected+(1 if args.wrong_object_result else 0), 'x')] in rows, (name, rows)
        results['rows'].append(dict(case=name, status='pass'))

    def check(name, path, pc=0, cpu=0x100000c, budget=1<<20, status='ok', source=None):
        run = subprocess.run([str(binary), str(path), str(cpu), hex(pc), str(budget)],
                             capture_output=True, text=True, timeout=15)
        (work/(name+'.log')).write_text(run.stdout+run.stderr)
        assert run.returncode == 0, (name, run.returncode, run.stderr)
        rows = [line.split('\t') for line in run.stdout.splitlines()]
        assert ['status', status] in rows, (name, rows)
        size = int(next(row[1] for row in rows if row[0]=='bytes'))
        assert size <= budget, (name, size, budget)
        if status != 'ok':
            assert size == 0, (name, size)
        if source:
            found = next((row for row in rows if row[0]=='source'), None)
            assert found and found[1:3] == list(source), (name, found, source)
        results['rows'].append(dict(case=name, status='pass', bytes=size))

    try:
        cases = [('c-O2-basic', 'c/main.c', 31), ('cxx-O2-basic', 'cxx/main.cpp', 7),
                 ('objc-O2-basic', 'objc/main.m', 6), ('swift-O-basic', 'swift/main.swift', 5)]
        last = None
        for name, source, line in cases:
            rec = json.loads((FIXTURES/'transcripts'/f'{name}.json').read_text())
            # PC from the first breakpoint reply, then the recorded slide.
            reply = next(r[0] for q,r in rec['exchanges'] if r and r[0].startswith('T05') and '20:' in r[0])
            registers = dict(part.split(':', 1) for part in reply[3:].split(';') if ':' in part)
            pc = int.from_bytes(bytes.fromhex(registers['20']), 'little')-int(rec['notes']['slide'], 0)
            program = FIXTURES/'corpus'/rec['program']
            path = program.with_name(program.name+'.dSYM')/'Contents/Resources/DWARF'/program.name
            check(name, path, pc, source=('/xodb-corpus/src/'+source, str(line+(1 if args.wrong_result else 0))))
            last = path
        check('small-budget', last, budget=256, status='limit')
        data = bytearray(last.read_bytes())
        at = 32
        dwarf = []
        for _ in range(struct.unpack_from('<I', data, 16)[0]):
            cmd, size = struct.unpack_from('<II', data, at)
            if cmd == 0x19:
                for i in range(struct.unpack_from('<I', data, at+64)[0]):
                    section = at+72+80*i
                    if data[section+16:section+32].rstrip(b'\0') == b'__DWARF':
                        dwarf.append(section)
            at += size
        assert len(dwarf) >= 2
        data[dwarf[1]:dwarf[1]+16] = data[dwarf[0]:dwarf[0]+16]
        duplicate = work/'duplicate.macho'
        duplicate.write_bytes(data)
        check('duplicate-section', duplicate, status='malformed')
        object_ = FIXTURES/'corpus/out/c/arm64-O2/main.o'
        # Apple ld moved the cold fragment: tick's bias and the cold fragment's
        # bias differ by 0x260. One object-wide bias fails the second assertion.
        # Addresses independently observed with llvm-nm on both files.
        object_check('object-tick', object_, 0x1000006d8, 0)
        object_check('object-cold-fragment', object_, 0x100000fd8, 0x6a0)
        data = bytearray(object_.read_bytes())
        at = 32
        relocation = None
        for _ in range(struct.unpack_from('<I', data, 16)[0]):
            cmd, size = struct.unpack_from('<II', data, at)
            if cmd == 0x19:
                for i in range(struct.unpack_from('<I', data, at+64)[0]):
                    section = at+72+80*i
                    if data[section:section+16].rstrip(b'\0') == b'__debug_addr':
                        offset, count = struct.unpack_from('<II', data, section+56)
                        assert count >= 2
                        relocation = offset
            at += size
        assert relocation is not None
        original = bytes(data)
        data[relocation+7] |= 1  # r_pcrel; unsupported, not silently unsigned.
        bad = work/'pcrel.o'
        bad.write_bytes(data)
        object_check('object-pcrel-refused', bad, 0x1000006d8, dwarf_status='unsupported')
        data = bytearray(original)
        data[relocation+8:relocation+12] = data[relocation:relocation+4]
        bad = work/'repeated-relocation.o'
        bad.write_bytes(data)
        object_check('object-repeated-relocation', bad, 0x1000006d8, dwarf_status='malformed')
        if args.matrix:
            for ordinal, path in enumerate(sorted((FIXTURES/'corpus/out').glob('*/*/*.dSYM/Contents/Resources/DWARF/*'))):
                cpus = (0x100000c, 0x1000007) if '/universal/' in str(path) else ((0x1000007,) if '/x86_' in str(path) else (0x100000c,))
                for cpu in cpus:
                    check(f'container-{ordinal}-{cpu}', path, cpu=cpu)
        results['status'] = 'pass'
    finally:
        if results['status'] == 'running':
            results['status'] = 'fail'
        results['seconds'] = time.monotonic()-started
        (work/'results.json').write_text(json.dumps(results, indent=2)+'\n')
    print(json.dumps(dict(status=results['status'], checks=len(results['rows']), seconds=results['seconds'])))


if __name__ == '__main__':
    main()
