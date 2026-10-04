#!/usr/bin/env python3
"""Owned Linux process with two independently mapped ELF libraries in one APK.
No ADB or device operations. Artifacts are new files in .work/apk-check-*/.
"""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import runpy
import struct
import subprocess
import zipfile
ROOT = Path(__file__).resolve().parents[2]
Rpc = runpy.run_path(str(ROOT / 'tests/android-app/check.py'))['Rpc']

def pack(path, files):
    offsets = []
    with zipfile.ZipFile(path, 'x') as archive:
        archive.writestr('AndroidManifest.xml', b'owned synthetic host fixture')
        for name, file in files:
            entry = zipfile.ZipInfo('lib/x86_64/' + name)
            # ZIP extra TLV pads library data to 16 KiB, also valid on 4 KiB Linux.
            pad = (-(archive.fp.tell() + 30 + len(entry.filename) + 4)) % 16384
            entry.extra = struct.pack('<HH', 0xcafe, pad) + bytes(pad)
            archive.writestr(entry, file.read_bytes())
            offsets.append(entry.header_offset + 30 + len(entry.filename) + len(entry.extra))
    return offsets

def build(run):
    env = dict(os.environ, TMPDIR=str(run))
    def command(*args): subprocess.run(args, check=True, env=env, capture_output=True)
    source = ROOT / 'tests/fixtures/apk/tick.c'
    for name, initial in [('left', 7), ('right', 100)]:
        command('gcc', '-shared', '-nostdlib', '-fPIC', '-fno-stack-protector', '-g', '-gdwarf-4', '-O0',
                '-Wl,--build-id=sha1', '-Wl,-Bsymbolic', '-Wl,-e,apk_' + name + '_tick',
                '-DTICK=apk_' + name + '_tick', '-DINITIAL=' + str(initial), str(source), '-o', str(run / (name + '.so')))
        command('strip', '--strip-all', '-o', str(run / (name + '.stripped.so')), str(run / (name + '.so')))
        command('objcopy', '--only-keep-debug', str(run / (name + '.so')), str(run / (name + '.debug')))
    command('gcc', '-g', '-O0', str(ROOT / 'tests/fixtures/apk/loader.c'), '-o', str(run / 'loader'))
    return source

def exercise(server, run, source, variant, debug_files):
    stripped = variant != 'embedded'
    archive = run / (variant + '.apk')
    offsets = pack(archive, [(name + '.so', run / (name + ('.stripped.so' if stripped else '.so'))) for name in ['left', 'right']])
    args = [str(server), '--headless', '--mcp', '--agent-scope', 'control', '--source', str(source), '--break', 'fixture_ready']
    for file in debug_files: args += ['--debug-file', str(file)]
    args += ['--', str(run / 'loader'), str(archive), *map(str, offsets)]
    with (run / (variant + '.stderr')).open('x') as log:
        process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log)
        try:
            rpc = Rpc(lambda b: (process.stdin.write(b), process.stdin.flush()), process.stdout)
            rpc.action('continue')
            tid = rpc.stopped('breakpoint')
            rpc.clear_breakpoints()
            symbols = [rpc.tool('find_symbol', name='apk_' + name + '_tick') for name in ['left', 'right']]
            assert symbols[0]['module_id'] != symbols[1]['module_id'], symbols
            probes = [rpc.action('set_breakpoint', symbol='apk_' + name + '_tick')['id'] for name in ['left', 'right']]
            views = []
            for name in ['left', 'right']:
                rpc.action('continue'); tid = rpc.stopped('breakpoint')
                view = rpc.tool('get_debug_view', tid=tid)
                assert view['frames'][0]['symbol'] == 'apk_' + name + '_tick', view['frames']
                views.append(view)
            for probe in probes: rpc.action('remove_breakpoint', id=probe)
            # A single source-line request must find both independently biased entries.
            line = next(i for i, text in enumerate(source.read_text().splitlines(), 1) if 'APK_STORE' in text)
            probe = rpc.action('set_breakpoint', file=str(source), line=line)['id']
            rpc.action('continue'); tid = rpc.stopped('breakpoint')
            view = rpc.tool('get_debug_view', tid=tid)
            locals_ = {row['name']: row for row in view['locals']}
            before = int(locals_['value']['display'])
            amount = int(locals_['amount']['display'])
            assert int(locals_['next']['display']) == before + amount, locals_
            assert rpc.tool('evaluate_expression', tid=tid, expression='value')['value']['display'] == str(before)
            watch = rpc.action('set_watchpoint', address=hex(locals_['value']['address']), length=4, kind='write')['id']
            # Source breakpoint can return a group: remove all installed probes.
            rpc.clear_breakpoints()
            rpc.action('continue'); rpc.stopped('watchpoint')
            hit = rpc.tool('get_debug_view', tid=tid)['watch_hits'][0]
            assert hit['before'] == before and hit['after'] == before + amount, hit
            rpc.action('remove_watchpoint', id=watch)
            previous = rpc.tool('get_debug_view', tid=tid)['frames'][0]['source']['line']
            rpc.action('step_source', tid=tid); rpc.stopped()
            assert rpc.tool('get_debug_view', tid=tid)['frames'][0]['source']['line'] != previous
            result = dict(variant=variant, offsets=offsets, symbols=symbols, watch=hit, checks='distinct modules, symbols, source breakpoint, locals, eval, write watch, source step')
            (run / (variant + '.json')).write_text(json.dumps(dict(result=result, transcript=rpc.transcript), indent=2) + '\n')
            return result
        finally:
            process.stdin.close()
            try: process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait()
            assert process.returncode == 0, (process.returncode, log.name)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--server', type=Path, default=ROOT / 'zig-out/bin/xodb')
    parser.add_argument('--debug-files', action='store_true')
    args = parser.parse_args()
    os.chdir(ROOT)
    run = ROOT / '.work' / ('apk-check-' + datetime.now().strftime('%Y%m%dT%H%M%S%f'))
    run.mkdir(parents=True)
    print(run, flush=True)
    source = build(run)
    results = [exercise(args.server.resolve(), run, source, 'embedded', [])]
    if args.debug_files:
        results += [exercise(args.server.resolve(), run, source, 'unstripped', [run / 'left.so', run / 'right.so']),
                    exercise(args.server.resolve(), run, source, 'debug-only', [run / 'left.debug', run / 'right.debug'])]
    (run / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print(json.dumps(results, indent=2))
if __name__ == '__main__': main()
