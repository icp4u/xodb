#!/usr/bin/env python3
"""Periodic native/agent runtime discovery with changed executable images."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import time
from client import Client
from helpers.input import load_scale
from helpers import orphans

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--python', required=True)
p.add_argument('--perl', required=True)
p.add_argument('--agent')
p.add_argument('--work', type=Path, required=True)
p.add_argument('--only', help='One table row, such as perl:mz')
p.add_argument('--wrong-result', action='store_true')
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
orphans.adopt()
w = a.work.resolve()
w.mkdir(parents=True, mode=0o755)
scale = load_scale()
started = time.monotonic()
rows = []
many_files = 2000
source = w/'decoy.c'
source.write_text('char _PyRuntime[64] = "decoy";\nint Perl_runops_standard(void) { return 1; }\nint definer_fixture(void) { return 7; }\n')
decoy = w/'decoy.so'
subprocess.run(['cc', '-shared', '-fPIC', '-g', '-O1', '-Wl,--build-id', str(source), '-o', str(decoy)], check=True, timeout=60*scale)
spec = importlib.util.spec_from_file_location('cache_image', root/'tests/fixtures/pe/cache-image.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
config = subprocess.check_output([a.perl, '-MConfig', '-e', 'print "$Config{archlibexp}/CORE/$Config{libperl}"'], text=True)
runtime = Path(config)
assert runtime.is_file(), ('shared Perl runtime required', runtime)

def observe(language, mode, args, expected, env=None, changed=None, min_calls=None):
    target = subprocess.Popen(args, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    client = None
    try:
        assert select.select([target.stdout], [], [], 60*scale)[0], 'fixture readiness'
        line = target.stdout.readline()
        assert line, target.stderr.read()
        fixture_state = json.loads(line)
        maps = Path(f'/proc/{target.pid}/maps').read_text().splitlines()
        if changed:
            mapped = [line for line in maps if str(changed) in line and 'x' in line.split()[1]]
            assert mapped, 'changed file was not executable in the target'
            if mode == 'deleted':
                assert not changed.exists() and all(line.endswith(' (deleted)') for line in mapped)
            elif mode != 'elf':
                magic = {'mz': b'MZ', 'other': b'XXXX', 'macho': bytes.fromhex('cffaedfe')}[mode]
                assert changed.read_bytes()[:len(magic)] == magic, 'fixture did not alter the image'
        options = ['--attach', str(target.pid)]
        if a.agent:
            options += ['--runtime-agent', str(Path(a.agent).resolve())]
        client = Client('control', None, options=options, reply_seconds=90*scale)
        client.stopped(seconds=60*scale)
        deadline = time.monotonic()+90*scale
        calls = 0
        while True:
            tabs = client.inspect('get_language_tabs')
            calls += 1
            if tabs['view']['complete']:
                break
            assert time.monotonic() < deadline, tabs
            time.sleep(.005)
        tab = next(row for row in tabs['view']['tabs'] if row['tab'] == language)
        actual = 'ready' if tab['status'] == 'ready' else tab['reason']
        want = 'deliberately_wrong_definer' if a.wrong_result else expected
        assert actual == want, (language, mode, expected, tab)
        # Through an agent the scan must hand control back between batches
        # of files; unsliced, the whole view settles within a few calls.
        if min_calls is not None:
            assert calls >= min_calls, ('definer scan was not sliced', calls, min_calls)
        rows.append(dict(language=language, mode=mode, expected=expected, tab=tab, fixture=fixture_state, calls=calls, status='pass'))
    finally:
        if client:
            client.close()
        if target.poll() is None:
            target.kill()
        target.wait(timeout=30*scale)

try:
    for mode in ('pe', 'data', 'unknown', 'unreadable', 'many', 'elf', 'mz', 'other', 'macho', 'deleted'):
        if a.only and a.only != 'python:'+mode:
            continue
        if mode == 'many' and not a.agent:
            continue  # Only the agent path pays a round trip per file.
        image = w/(mode+'.image')
        min_calls = None
        if mode == 'pe':
            fixture.write(image, symbol='_PyRuntime')
        elif mode in ('data', 'unknown', 'unreadable'):
            image.write_bytes(b'unknown-format'+bytes(4096))
        elif mode == 'many':
            # Distinct valid PE files, each a first look. 2,000 files need at
            # least 15 batches of 128 after the agent's own first answer.
            image.mkdir()
            fixture.write(image/'0.dll', symbol='_PyRuntime')
            for i in range(1, many_files):
                shutil.copyfile(image/'0.dll', image/f'{i}.dll')
            min_calls = 15
        else:
            shutil.copyfile(decoy, image)
        expected = 'ready' if mode in ('pe', 'data', 'many') else ('PythonRuntimeAmbiguous' if mode == 'elf' else 'PythonModuleIdentityUnavailable')
        observe('python', mode, [a.python, 'tests/fixtures/pe/definer.py', str(image), mode], expected,
                changed=image if mode not in ('pe', 'data', 'unknown', 'unreadable', 'many') else None, min_calls=min_calls)
    for mode in ('elf', 'mz', 'other', 'macho', 'deleted'):
        if a.only and a.only != 'perl:'+mode:
            continue
        own = w/('perl-'+mode)
        own.mkdir()
        exe, lib = own/'perl', own/runtime.name
        shutil.copyfile(a.perl, exe)
        exe.chmod(0o755)
        shutil.copyfile(runtime, lib)
        env = dict(os.environ, LD_LIBRARY_PATH=str(own))
        expected = 'PerlValueRuntimeAmbiguous' if mode == 'elf' else 'PerlModuleIdentityUnavailable'
        observe('perl', mode, [str(exe), 'tests/fixtures/pe/definer.pl', str(decoy), str(lib), mode], expected, env, lib)
    assert rows, 'unknown table row'
finally:
    (w/'results.json').write_text(json.dumps(dict(checks=rows, seconds=time.monotonic()-started), indent=2)+'\n')
    assert orphans.reap(), 'fixture children remain'
print(json.dumps(dict(status='pass', checks=len(rows), seconds=time.monotonic()-started)))
