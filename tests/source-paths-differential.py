#!/usr/bin/env python3
"""Authorized DWARF paths must be a subset of GNU readelf's listed files."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import random
import re
import subprocess


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--check', required=True, type=Path)
    p.add_argument('--work', required=True, type=Path)
    p.add_argument('--cases', default=1500, type=int)
    p.add_argument('--seed', default=4, type=int)
    args = p.parse_args()
    if not 2 <= args.cases <= 15000:
        p.error('--cases must be between 2 and 15000')
    os.umask(0o022)
    work = args.work.resolve(); work.mkdir(parents=True, exist_ok=True)
    check = args.check.resolve()
    spec = importlib.util.spec_from_file_location('source_fixtures', Path(__file__).with_name('source-paths.py'))
    fixtures = importlib.util.module_from_spec(spec); spec.loader.exec_module(fixtures)
    rng = random.Random(args.seed)
    names = ['a.c', 'b.c', 'hidden.c', 'x.c']
    env = dict(os.environ, LC_ALL='C', LANG='C')
    report = {'status': 'running', 'seed': args.seed, 'cases': args.cases,
              'authorized': 0, 'listed_but_refused': 0, 'counterexamples': [],
              'load_start': os.getloadavg(), 'allowed_cpus': len(os.sched_getaffinity(0))}
    def leb(value):
        result = bytearray()
        while value >= 128:
            result.append((value & 127) | 128); value >>= 7
        return bytes(result) + bytes([value])
    try:
        for index in range(args.cases):
            version = rng.choice([2, 3, 4]); wide = rng.random() < .5
            little = rng.random() < .5; dwarf64 = rng.random() < .3
            rows = bytearray()
            for _ in range(rng.randint(0, 6)):
                choice = rng.random()
                if choice < .55:
                    rows += rng.choice(names).encode() + b'\0' + leb(rng.choice([0, 0, 1, 2])) + leb(rng.choice([0, 300])) + b'\0'
                elif choice < .75:
                    rows += b'\0' + bytes(rng.randint(0, 3))
                elif choice < .85:
                    rows += b'\x80' * rng.randint(1, 12)
                else:
                    rows += bytes(rng.randint(1, 6))
            if rng.random() < .8: rows += b'\0'
            # Positive parser control and a minimized post-terminator control.
            if index == 0: rows = b'a.c\0\0\0\0\0'
            if index == 1: rows = b'a.c\0\0\0\0' + bytes(4) + b'hidden.c\0\0\0\0\0'
            image = work / f'case-{index}.elf'
            fixtures.synthetic(image, version, wide, little, dwarf64, files_override=bytes(rows))
            dump = subprocess.run(['readelf', '--debug-dump=rawline', str(image)], env=env,
                                  capture_output=True, text=True, errors='replace', timeout=10)
            assert dump.returncode in (0, 1), (index, dump.returncode, dump.stderr)
            table = dump.stdout.split('The File Name Table', 1)
            listed = set()
            if len(table) > 1:
                for line in table[1].split('Line Number Statements', 1)[0].splitlines():
                    fields = line.split()
                    if len(fields) >= 5 and fields[0].isdigit(): listed.add((fields[1], fields[-1]))
            if index < 2:
                assert ('0', 'a.c') in listed and ('0', 'hidden.c') not in listed, dump.stdout
            for name in names:
                for path, directory in [(f'/synthetic/build/{name}', '0'), (f'/synthetic/build/include/{name}', '1')]:
                    result = subprocess.run([str(check), str(image), path, 'ok'],
                                            capture_output=True, text=True, timeout=10)
                    match = re.fullmatch(re.escape(path) + r': ([a-z-]+) \(\d+ bytes, \d+ reads\)\n', result.stdout)
                    assert match and result.returncode == (0 if match[1] == 'ok' else 1), (index, result.returncode, result.stdout, result.stderr)
                    authorized = match[1] == 'ok'; shown = (directory, name) in listed
                    if index == 0 and path == '/synthetic/build/a.c': assert authorized, result.stdout
                    report['authorized'] += int(authorized)
                    report['listed_but_refused'] += int(shown and not authorized)
                    if authorized and not shown:
                        report['counterexamples'].append({'case': index, 'path': path, 'rows_hex': bytes(rows).hex(),
                            'version': version, 'elf64': wide, 'little': little, 'dwarf64': dwarf64,
                            'listed': sorted(listed), 'reader': result.stdout})
                        (work/f'case-{index}.readelf.txt').write_text(dump.stdout + dump.stderr)
            if report['counterexamples']:
                raise AssertionError('authorized a path absent from readelf; see results.json')
        report['status'] = 'pass'
    except BaseException as error:
        report['status'] = 'fail'; report['error'] = str(error)
        raise
    finally:
        report['load_end'] = os.getloadavg()
        (work/'results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f"pass: {args.cases} source-path differential cases; {report['authorized']} authorized, {report['listed_but_refused']} listed-but-refused")


if __name__ == '__main__':
    main()
