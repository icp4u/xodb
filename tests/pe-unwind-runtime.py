#!/usr/bin/env python3
"""Periodic differential Windows unwind oracle in an owned private Wine prefix."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time
from helpers import orphans

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', type=Path, required=True)
p.add_argument('--wine', default='wine')
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
orphans.adopt()
w = a.work.resolve()
w.mkdir(parents=True)
start = time.monotonic()
rows = []
env = dict(os.environ, ZIG_LOCAL_CACHE_DIR=str(root / '.zig-cache'),
           ZIG_GLOBAL_CACHE_DIR=str(root / '.cache/zig-global'))


def run(name, args, expected=0, cwd=root, timeout=60):
    begin = time.monotonic()
    r = subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout)
    (w / (name + '.log')).write_text(r.stdout + r.stderr)
    rows.append(dict(name=name, exit=r.returncode, expected=expected,
                     status='pass' if r.returncode == expected else 'fail', seconds=time.monotonic() - begin))
    (w / 'results.json').write_text(json.dumps(dict(checks=rows, elapsed_seconds=time.monotonic() - start), indent=2) + '\n')
    assert r.returncode == expected, (rows[-1], r.stdout, r.stderr)


run('component', ['python3', '-B', 'tests/pe-unwind.py', '--work', str(w / 'component')])
shutil.copyfile(w / 'component/unwind.dll', w / 'unwind.dll')
for name, exports in (
    ('kernel32', ['GetProcAddress', 'LoadLibraryA', 'GetStdHandle', 'WriteFile', 'ExitProcess', 'GetCommandLineA', 'VirtualAlloc']),
    ('ntdll', ['RtlAddFunctionTable', 'RtlDeleteFunctionTable', 'RtlLookupFunctionEntry', 'RtlVirtualUnwind', '__chkstk']),
    ('msvcrt', ['memcmp', 'memcpy', 'memset', 'strcmp', 'strlen', 'strncmp', 'strstr'])):
    definition = w / (name + '.def')
    definition.write_text('LIBRARY ' + name + '.dll\nEXPORTS\n' + '\n'.join('    ' + s for s in exports) + '\n')
    run(name, ['lld-link', '/lib', '/machine:x64', '/def:' + str(definition), '/out:' + str(w / (name + '.lib'))])
for label, source in (('oracle', 'tests/fixtures/pe/unwind-runtime.c'), ('decoder', 'src/debug/pe_unwind.c')):
    run(label, ['zig', 'cc', '-target', 'x86_64-windows-gnu', '-O2', '-g',
        '-ffile-prefix-map=' + str(root) + '=.', '-c', source, '-o', str(w / (label + '.obj'))])
# GNU-target Clang uses the same x64 stack-probe ABI with a different name.
run('link', ['lld-link', '/entry:entry', '/subsystem:console', '/machine:x64',
    '/alternatename:___chkstk_ms=__chkstk', '/out:' + str(w / 'runtime.exe'),
    *[str(w / (name + '.obj')) for name in ('oracle', 'decoder')],
    *[str(w / (name + '.lib')) for name in ('kernel32', 'ntdll', 'msvcrt')]])
spec = importlib.util.spec_from_file_location('private_display', root / 'tests/helpers/display.py')
display = importlib.util.module_from_spec(spec)
spec.loader.exec_module(display)
display.WORK = str(w / 'display')
d = server = None


def owned():
    result = []
    for proc in Path('/proc').iterdir():
        if not proc.name.isdigit():
            continue
        try:
            cwd = (proc / 'cwd').resolve(strict=True)
            if cwd == w or w in cwd.parents:
                result.append(int(proc.name))
        except (OSError, RuntimeError):
            pass
    return result


try:
    d = display.Display('d')
    prefix = w / 'prefix'
    prefix.mkdir(mode=0o700)
    env = dict(d.env, WINEPREFIX=str(prefix), WINEDEBUG='-all', WINEDLLOVERRIDES='mscoree,mshtml=d')
    with (w / 'server.log').open('wb') as log:
        server = subprocess.Popen(['wineserver', '-f'], cwd=w, env=env, stdout=log, stderr=subprocess.STDOUT)
        run('runtime', [a.wine, str(w / 'runtime.exe')], cwd=w)
        assert '28 RtlVirtualUnwind boundary comparisons passed' in (w / 'runtime.log').read_text()
        assert '2 RtlVirtualUnwind chained-save comparisons passed' in (w / 'runtime.log').read_text()
        shapes = [line for line in (w / 'runtime.log').read_text().splitlines() if 'shape comparisons' in line]
        assert shapes == ['14 RtlVirtualUnwind shape comparisons passed, 02 documented platform differences seen'], shapes
        run('wrong-result', [a.wine, str(w / 'runtime.exe'), 'wrong-result'], expected=90, cwd=w)
        run('wrong-shape', [a.wine, str(w / 'runtime.exe'), 'wrong-shape'], expected=90, cwd=w)
finally:
    if server and server.poll() is None:
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait(timeout=5)
    if d:
        d.close()
    for pid in owned():
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    assert orphans.reap(), 'a Wine process is still running'
print(json.dumps(dict(status='pass', checks=len(rows), seconds=time.monotonic() - start)))
