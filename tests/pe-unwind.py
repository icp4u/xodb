#!/usr/bin/env python3
"""Fast Windows unwind decoder: compiler SEH tables and exact register oracles.

--fuzz adds the periodic bounded ASan/UBSan mutation lane.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time
from helpers import orphans

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', type=Path, required=True)
p.add_argument('--fuzz', action='store_true')
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
orphans.adopt()
w = a.work.resolve()
w.mkdir(parents=True)
start = time.monotonic()
rows = []


def run(name, args, expected=0, timeout=30):
    begin = time.monotonic()
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    (w / (name + '.log')).write_text(result.stdout + result.stderr)
    rows.append(dict(name=name, exit=result.returncode, expected=expected,
                     seconds=time.monotonic() - begin,
                     status='pass' if result.returncode == expected else 'fail'))
    (w / 'results.json').write_text(json.dumps(dict(checks=rows,
        elapsed_seconds=time.monotonic() - start), indent=2) + '\n')
    assert result.returncode == expected, (rows[-1], result.stdout, result.stderr)
    return result.stdout


run('assemble', ['clang', '--target=x86_64-pc-windows-msvc', '-g', '-gcodeview',
    '-ffile-prefix-map=' + str(root) + '=.', '-c', 'tests/fixtures/pe/unwind.S', '-o', str(w / 'unwind.obj')])
run('link', ['lld-link', '/dll', '/noentry', '/machine:x64', '/debug',
    '/pdb:' + str(w / 'unwind.pdb'), '/out:' + str(w / 'unwind.dll'), str(w / 'unwind.obj')])
run('compiler-oracle', ['llvm-readobj', '--coff-exports', '--unwind', str(w / 'unwind.dll')])
run('instruction-oracle', ['llvm-objdump', '-d', str(w / 'unwind.dll')])
run('compile', ['cc', '-std=c11', '-O2', '-g', '-DNDEBUG', '-Wall', '-Wextra',
    '-Werror', '-Wswitch-enum', 'tests/pe-unwind.c', 'src/debug/pe_unwind.c',
    'src/binary/pe.c', '-o', str(w / 'check')])
run('boundaries-and-faults', [str(w / 'check'), str(w / 'unwind.dll')])
run('wrong-result', [str(w / 'check'), str(w / 'unwind.dll'), 'wrong-result'], expected=-6)
run('wrong-shape', [str(w / 'check'), str(w / 'unwind.dll'), 'wrong-shape'], expected=-6)
if a.fuzz:
    run('compile-sanitized', ['clang', '-std=c11', '-O1', '-g', '-DNDEBUG', '-Wall',
        '-Wextra', '-Werror', '-fsanitize=address,undefined', 'tests/pe-unwind.c',
        'src/debug/pe_unwind.c', 'src/binary/pe.c', '-o', str(w / 'sanitized')])
    run('sanitized', [str(w / 'sanitized'), str(w / 'unwind.dll')])
    seeds = w / 'seeds'
    seeds.mkdir()
    # Header is PC/stack adjustment/frame adjustment/metadata offset; the
    # remainder is a bounded metadata + code image, mutated by libFuzzer.
    seed = bytearray(16 + 2048)
    seed[0:4] = (0x120).to_bytes(4, 'little')
    seed[4:8] = (40).to_bytes(4, 'little')
    seed[12:16] = (0x200).to_bytes(4, 'little')
    seed[16 + 0x100:16 + 0x180] = b'\x90' * 128
    seed[16 + 0x200:16 + 0x208] = bytes([1, 5, 2, 0, 5, 0x32, 1, 0x30])
    (seeds / 'body').write_bytes(seed)
    seed[0:4] = (0x170).to_bytes(4, 'little')
    seed[16 + 0x170:16 + 0x176] = b'\x48\x83\xc4\x20\x5b\xc3'
    (seeds / 'epilog').write_bytes(seed)
    run('compile-fuzz', ['clang', '-std=c11', '-O1', '-g', '-Wall', '-Wextra',
        '-Werror', '-fsanitize=fuzzer,address,undefined', 'tests/pe-unwind-fuzz.c',
        'src/debug/pe_unwind.c', '-o', str(w / 'fuzz')])
    run('fuzz', [str(w / 'fuzz'), str(seeds), '-max_total_time=30', '-timeout=3',
        '-rss_limit_mb=768', '-max_len=32768', '-artifact_prefix=' + str(w) + '/'], timeout=50)
assert orphans.reap(), 'a child process is still running'
print(json.dumps(dict(status='pass', checks=len(rows), elapsed_seconds=time.monotonic() - start)))
