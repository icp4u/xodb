#!/usr/bin/env python3
"""Compact unwind rows compared with LLVM, plus regular pages and bad tables."""
import argparse
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import time

from helpers import macho_fixture as mf

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT/'tests/fixtures/macos-names/corpus/out'


def main():
    os.chdir(ROOT)
    os.umask(0o022)
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--work', type=Path, required=True)
    p.add_argument('--matrix', action='store_true')
    p.add_argument('--wrong-result', action='store_true')
    args = p.parse_args()
    work = args.work.resolve()
    work.mkdir(parents=True)
    results = dict(status='running', rows=[])
    started = time.monotonic()
    binary = work/'check'
    command = ['clang' if args.matrix else 'cc', '-std=c11', '-O1', '-g', '-DNDEBUG', '-Wall', '-Wextra', '-Werror']
    if args.matrix:
        command += ['-fsanitize=address,undefined', '-fno-sanitize-recover=all']
    command += ['tests/macos-unwind.c', 'src/debug/macho_unwind.c', 'src/binary/macho.c', '-o', str(binary)]
    run = subprocess.run(command, capture_output=True, text=True, timeout=60)
    (work/'compile.log').write_text(run.stdout+run.stderr)
    assert run.returncode == 0, run.stderr

    def check(name, path, pc, expected=None, table='ok', budget=1<<20):
        run = subprocess.run([str(binary), str(path), hex(pc), str(budget)], capture_output=True, text=True, timeout=10)
        (work/(name+'.log')).write_text(run.stdout+run.stderr)
        assert run.returncode == 0, (name, run.stderr)
        rows = [line.split('\t') for line in run.stdout.splitlines()]
        assert ['table', table] in rows, (name, rows)
        if expected:
            wanted = list(expected)
            if args.wrong_result:
                wanted[-1] ^= 1
            assert ['row', 'ok', *(format(v, 'x') for v in wanted)] in rows, (name, rows, wanted)
        elif table == 'ok':
            assert ['row', 'not-found', '0', '0', '0'] in rows, (name, rows)
        retained = int(next(row[1] for row in rows if row[0]=='retained'))
        assert retained <= budget, (name, retained, budget)
        results['rows'].append(dict(case=name, status='pass'))

    try:
        selected = [FIXTURES/'c/arm64-O2/cprog', FIXTURES/'swift/arm64-Onone/libXFDep.dylib']
        if args.matrix:
            selected = [p for p in sorted(FIXTURES.glob('*/*/*')) if p.is_file() and p.suffix != '.o' and p.read_bytes()[:4] == bytes.fromhex('cffaedfe')]
        for ordinal, path in enumerate(selected):
            oracle = subprocess.run(['llvm-objdump', '--macho', '--unwind-info', str(path)], capture_output=True, text=True, timeout=15)
            assert oracle.returncode == 0, oracle.stderr
            (work/f'oracle-{ordinal}.log').write_text(oracle.stdout+oracle.stderr)
            rows = [(int(a,16), int(b,16)) for a,b in re.findall(r'function offset=0x([0-9a-fA-F]+), encoding\[\d+\]=0x([0-9a-fA-F]+)', oracle.stdout)]
            indices = [int(v,16) for v in re.findall(r'function offset=0x([0-9a-fA-F]+), 2nd level page offset=', oracle.stdout)]
            assert rows and indices, path
            for i,(start,encoding) in enumerate(rows):
                end = rows[i+1][0] if i+1<len(rows) else indices[-1]
                check(f'linked-{ordinal}-{i}', path, start, (start,end,encoding))
        # Independent, regular-page fixture. No real code/memory is simulated.
        table = bytearray(128)
        struct.pack_into('<7I',table,0,1,28,0,28,0,28,2)
        struct.pack_into('<6I',table,28,0x100,52,52,0x200,0,52)
        struct.pack_into('<IHH4I',table,52,2,8,2,0x100,0x02000000,0x180,0x04000000)

        def fixture(name, content):
            segment = mf.segment('__TEXT',0x100000000,4096,0,512,5,
                [dict(name='__unwind_info',addr=0x100000100,size=len(content),offset=256)])
            data = bytearray(512)
            struct.pack_into('<8I',data,0,0xfeedfacf,mf.ARM64,0,2,1,len(segment),0,0)
            data[32:32+len(segment)] = segment
            data[256:256+len(content)] = content
            path = work/(name+'.macho')
            path.write_bytes(data)
            return path

        regular = fixture('regular',table)
        check('regular-start',regular,0x100,(0x100,0x180,0x02000000))
        check('regular-end-minus-one',regular,0x17f,(0x100,0x180,0x02000000))
        check('regular-next',regular,0x180,(0x180,0x200,0x04000000))
        check('regular-outside',regular,0x200)
        check('budget',regular,0x100,table='limit',budget=1)
        for name, at, value, status in [('index-count',24,0xffffffff,'limit'),('page-offset',32,127,'malformed'),
                ('unordered-index',40,0x100,'malformed'),('unordered-page',68,0x100,'malformed'),
                ('sentinel-page',44,52,'malformed'),('version',0,2,'unsupported')]:
            corrupt = bytearray(table)
            struct.pack_into('<I',corrupt,at,value)
            assert corrupt != table
            check(name,fixture(name,corrupt),0x100,table=status)
        results['status'] = 'pass'
    finally:
        if results['status']=='running':
            results['status']='fail'
        results['seconds']=time.monotonic()-started
        (work/'results.json').write_text(json.dumps(results,indent=2)+'\n')
    print(json.dumps(dict(status=results['status'],checks=len(results['rows']),seconds=results['seconds'])))


if __name__ == '__main__':
    main()
