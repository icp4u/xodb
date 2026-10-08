#!/usr/bin/env python3
"""Compare the C named-local reader directly with an owned Python f_locals oracle."""
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess


def compile_fixture(python, work, *, oracle=False, lua_source=None):
    root = Path(__file__).resolve().parents[1]
    includes = shlex.split(subprocess.check_output([python+'-config', '--includes'], text=True, timeout=30))
    output = work/('python-lua-host' if lua_source else 'xodb_named.so')
    command = ['cc', *([] if lua_source else ['-shared', '-fPIC']), '-g3', '-O0', '-UNDEBUG', '-Wall', '-Wextra', '-Werror',
               *[flag.replace('-I', '-isystem', 1) if flag.startswith('-I') else flag for flag in includes], str(root/'tests/fixtures/python/named.c'), '-o', str(output)]
    if oracle:
        command += ['-DXODB_PYTHON_ORACLE', str(root/'src/language/python.c'), str(root/'src/language/python_layout.c'), '-ldw', '-ldl', '-lm']
    if lua_source:
        source = Path(lua_source).resolve()
        files = sorted(str(path) for path in source.glob('*.c') if path.name not in ('lua.c', 'luac.c'))
        assert files
        command += ['-DXODB_PYTHON_LUA', '-DXODB_PYTHON_HOST', '-DLUA_USE_LINUX', '-I'+str(source), *files, '-Wl,--export-dynamic']
        command += shlex.split(subprocess.check_output([python+'-config', '--embed', '--ldflags'], text=True, timeout=30))
    subprocess.run(command, check=True, timeout=120)
    return output


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--python', required=True)
    p.add_argument('--work', required=True, type=Path)
    p.add_argument('--lua-source', type=Path)
    a = p.parse_args()
    os.umask(0o022)
    w = a.work.resolve(); w.mkdir(parents=True, mode=0o755)
    built = compile_fixture(a.python, w, oracle=True, lua_source=a.lua_source)
    fixture = Path(__file__).resolve().parent/'fixtures/python/named.py'
    result = subprocess.run([str(built) if a.lua_source else a.python, str(fixture)], env=dict(os.environ, PYTHONPATH=str(w)),
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    (w/'oracle.log').write_text(result.stdout)
    (w/'results.json').write_text(json.dumps({'status': 'pass' if result.returncode == 0 else 'fail', 'exit_code': result.returncode, 'output': result.stdout}, indent=2)+'\n')
    print(result.stdout, end='')
    assert result.returncode == 0, result.returncode


if __name__ == '__main__':
    main()
