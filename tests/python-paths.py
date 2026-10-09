#!/usr/bin/env python3
"""Compile and run the stopped Python path reader against public-API oracles."""
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--python', required=True)
    parser.add_argument('--work', required=True, type=Path)
    parser.add_argument('--sanitize', action='store_true')
    args = parser.parse_args()
    os.umask(0o022)
    root = Path(__file__).resolve().parents[1]
    work = args.work.resolve(); work.mkdir(parents=True, mode=0o755)
    includes = shlex.split(subprocess.check_output([args.python+'-config', '--includes'], text=True, timeout=30))
    command = ['cc', '-shared', '-fPIC', '-g3', '-O1', '-UNDEBUG', '-Wall', '-Wextra', '-Werror',
               *[flag.replace('-I', '-isystem', 1) if flag.startswith('-I') else flag for flag in includes],
               str(root/'tests/fixtures/python/paths.c'), str(root/'src/language/python.c'),
               str(root/'src/language/python_layout.c'), '-ldw', '-ldl', '-lm', '-o', str(work/'xodb_paths.so')]
    env = dict(os.environ, PYTHONPATH=str(work))
    if args.sanitize:
        command += ['-fsanitize=address,undefined', '-fno-omit-frame-pointer']
        env['LD_PRELOAD'] = subprocess.check_output(['cc', '-print-file-name=libasan.so'], text=True).strip()
        env['ASAN_OPTIONS'] = 'detect_leaks=0:abort_on_error=1'
        env['UBSAN_OPTIONS'] = 'halt_on_error=1:print_stacktrace=1'
    subprocess.run(command, check=True, timeout=120)
    result = subprocess.run([args.python, str(root/'tests/fixtures/python/paths.py')], env=env,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    (work/'oracle.log').write_text(result.stdout)
    (work/'results.json').write_text(json.dumps({'status': 'pass' if result.returncode == 0 else 'fail',
        'exit_code': result.returncode, 'sanitized': args.sanitize, 'output': result.stdout}, indent=2)+'\n')
    print(result.stdout, end='')
    assert result.returncode == 0, result.returncode


if __name__ == '__main__':
    main()
