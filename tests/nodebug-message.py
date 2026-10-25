#!/usr/bin/env python3
"""Fast owned symbols-only diagnostic oracle; optional private GUI proof."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
from client import Client

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', type=Path, required=True)
p.add_argument('--gui', action='store_true')
p.add_argument('--wrong-result', action='store_true')
a = p.parse_args()
root = Path(__file__).resolve().parents[1]; os.chdir(root); os.umask(0o022)
w = a.work.resolve(); w.mkdir(parents=True, exist_ok=True)
(w/'roots').mkdir(exist_ok=True)
(w/'main.c').write_text('__attribute__((noinline)) int marker(void) { volatile int number=7; return number; }\nint main(void) { return marker(); }\n')
def run(*args):
    return subprocess.run(list(map(str, args)), check=True, capture_output=True, text=True, timeout=30).stdout
full = w/'full'
run('cc', '-g', '-O0', '-no-pie', '-Wl,--build-id', w/'main.c', '-o', full)
address = '0x' + next(row.split()[0] for row in run('nm', full).splitlines() if row.endswith(' marker'))
build_id = re.search(r'Build ID: (\w+)', run('readelf', '-n', full))[1]
prefs = w/'noauto.json'; prefs.write_text('{"symbols":{"automatic":false}}')
results = {'status': 'running', 'cases': []}

def prepare(case):
    directory = w/case; directory.mkdir(exist_ok=True)
    binary = directory/'fixture'; shutil.copyfile(full, binary); binary.chmod(0o755)
    debug = directory/'fixture.debug'
    run('objcopy', '--only-keep-debug', binary, debug)
    run('strip', '--strip-all' if case == 'stripped' else '--strip-debug', binary)
    if case in ('missing', 'rejected'):
        run('objcopy', '--add-gnu-debuglink='+str(debug), binary)
    if case == 'rejected':
        debug.write_bytes(debug.read_bytes() + b'changed CRC')
    else:
        debug.unlink()
    options = ['--debug-dir', str(w/'roots')]
    if case in ('symbols', 'stripped'): options += ['--config', str(prefs)]
    name = 'wrong-fixture' if a.wrong_result else 'fixture'
    expected = f'no DWARF in {name} (build ID {build_id[:8]}); no .debug_info section; '
    expected += 'stripped; no defined symbols' if case == 'stripped' else 'symbols only'
    if case in ('missing', 'rejected'):
        expected += f'; separate debug .build-id/{build_id[:2]}/{build_id[2:]}.debug: not found; separate debug fixture.debug: '
        expected += 'not found' if case == 'missing' else 'rejected (DebugFileCrcMismatch)'
        if os.environ.get('XODB_TEST_RUNTIME_AGENT'): expected += ' (searched on the debugger host, not the target)'
    return binary, options, expected

def settled(c, name, **args):
    deadline = time.monotonic() + 30
    while True:
        reply = c.tool(name, **args)['result']
        if not reply.get('isError') or reply['content'][0]['text'] != 'DebugMetadataPending': return reply
        assert time.monotonic() < deadline, reply
        time.sleep(.005)

def host():
    for case in ('symbols', 'stripped', 'missing', 'rejected'):
        binary, options, expected = prepare(case)
        c = Client('control', str(binary), options=options, reply_seconds=30)
        try:
            c.action('set_breakpoint', address=address)
            c.action('continue'); stopped = c.stopped('breakpoint')
            tid = next(t['tid'] for t in stopped['threads'] if t['reason'] == 'breakpoint')
            source = settled(c, 'get_source_location', address=address)
            locals_ = settled(c, 'list_locals', tid=tid, frame=0)
            for reply in (source, locals_):
                assert reply.get('isError') and reply['content'][0]['text'] in ('NoDebugInfo', 'NoDebugInfoAtAddress'), reply
                assert [item['text'] for item in reply['content']][1:] == [expected], (case, expected, reply)
                assert str(w) not in reply['content'][1]['text'], reply
            view = c.inspect('get_debug_view', tid=tid, frame=0)
            assert any(d['component'] == 'locals' and d['message'] == expected for d in view['diagnostics']), view
            results['cases'].append({'case': case, 'message': expected})
        finally:
            c.close()

def gui():
    binary, options, expected = prepare('symbols')
    spec = importlib.util.spec_from_file_location('private_input', root/'tests/helpers/input.py')
    h = importlib.util.module_from_spec(spec); spec.loader.exec_module(h); h.WORK = str(w)
    for name in ('tmp', 'cache'): (w/name).mkdir(exist_ok=True)
    for xml, stem in ((h.VPTR, 'virtual-pointer'), (h.VKBD, 'virtual-keyboard')):
        run('wayland-scanner', 'client-header', xml, w/(stem+'.h'))
        run('wayland-scanner', 'private-code', xml, w/(stem+'.c'))
    h.HELPER = str(w/'vinput')
    run('cc', '-I', w, 'tests/helpers/vinput.c', w/'virtual-pointer.c', w/'virtual-keyboard.c', '-lwayland-client', '-lxkbcommon', '-lm', '-o', h.HELPER)
    d = h.Display(str(root), ['--agent-scope', 'control', *options, '--', str(binary)])
    try:
        d.tool('set_breakpoint', generation=d.session()['generation'], address=address)
        d.tool('continue', generation=d.session()['generation']); stopped = d.stopped('breakpoint')
        tid = next(t['tid'] for t in stopped['threads'] if t['reason'] == 'breakpoint')
        d.tool('select_native_frame', generation=stopped['generation'], tid=tid, frame=0)
        d.tool('select_language_tab', generation=stopped['generation'], tab='native')
        view = d.tool('get_debug_view', tid=tid, frame=0)
        assert any(x['component'] == 'locals' and x['message'] == expected for x in view['diagnostics']), view
        deadline = time.monotonic() + 20
        while True:
            shot = d.shot('missing-dwarf')
            text = h.ocr(shot, '--psm', '11').lower()
            if all(word in text for word in ('no dwarf', 'fixture', 'symbols only')): break
            assert time.monotonic() < deadline, text
            time.sleep(.05)
        results['cases'].append({'case': 'private-gui', 'message': expected})
    finally:
        d.close()

try:
    gui() if a.gui else host()
    results['status'] = 'pass'
finally:
    (w/'results.json').write_text(json.dumps(results, indent=2)+'\n')
print('Missing DWARF: examined basename/build ID, symbols, companion outcomes and consistent diagnostics PASS')
