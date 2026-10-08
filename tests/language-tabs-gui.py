#!/usr/bin/env python3
"""Language tab cycling/clicks and MCP synchronization on private headless Sway."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time

root = Path(__file__).resolve().parents[1]
os.chdir(root)
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', required=True, type=Path)
p.add_argument('--python', type=Path)
p.add_argument('--perl', type=Path)
p.add_argument('--lua', type=Path)
p.add_argument('--node', type=Path)
p.add_argument('--unsupported-perl', type=Path)
p.add_argument('--unsupported-lua', type=Path)
p.add_argument('--embedded', type=Path, help='Owned host linking CPython and PUC Lua')
a = p.parse_args()
os.umask(0o022)
work = (a.work / '.work/input-tabs').resolve()
work.mkdir(parents=True, mode=0o755)
spec = importlib.util.spec_from_file_location('private_input', root/'tests/helpers/input.py')
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
h.WORK = str(work)
for name in ('tmp', 'cache/mesa', 'cache/nvidia'):
    (work/name).mkdir(parents=True, exist_ok=True)
for xml, stem in ((h.VPTR, 'virtual-pointer'), (h.VKBD, 'virtual-keyboard')):
    subprocess.run(['wayland-scanner', 'client-header', xml, str(work/(stem+'.h'))], check=True, timeout=10)
    subprocess.run(['wayland-scanner', 'private-code', xml, str(work/(stem+'.c'))], check=True, timeout=10)
h.HELPER = str(work/'vinput')
subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-I', str(work), 'tests/helpers/vinput.c',
    str(work/'virtual-pointer.c'), str(work/'virtual-keyboard.c'), '-lwayland-client', '-lxkbcommon', '-lm', '-o', h.HELPER], check=True, timeout=60)
(work/'fixture.c').write_text('int main(void) { return 0; }\n')
subprocess.run(['cc', '-g', '-O0', str(work/'fixture.c'), '-o', str(work/'fixture')], check=True, timeout=60)
cases = [('native', work/'fixture', [], ())]
for label, exe, arguments in [('python', a.python, ('-c', 'print(1)')),
    ('perl', a.perl, ('-e', 'print 1')), ('lua', a.lua, ('-e', 'print(1)')),
    ('javascript', a.node, ('-e', 'console.log(1)'))]:
    if exe:
        cases.append((label, exe, [label], arguments))
if a.embedded:
    cases.append(('embedded', a.embedded, ['python', 'lua'], ()))
unavailable = {}
if a.unsupported_perl:
    cases.append(('unsupported-perl', a.unsupported_perl, [], ('-e', 'print 1')))
    unavailable['unsupported-perl'] = ('perl', 'perl_run', 'PerlVersionUnsupported', 'Unsupported version')
if a.unsupported_lua:
    cases.append(('unsupported-lua', a.unsupported_lua, [], ('-e', 'print(1)')))
    unavailable['unsupported-lua'] = ('lua', 'lua_pcallk', 'LuaImplementationUnsupported', 'Unsupported Lua build')
results = []


def poll_tabs(display, predicate):
    deadline = time.monotonic() + 900
    while True:
        result = display.tool('get_language_tabs')
        if predicate(result['view']):
            return result['view']
        assert time.monotonic() < deadline, result
        time.sleep(.03)

for label, executable, languages, arguments in cases:
    d = None
    report = {'case': label, 'status': 'running'}
    try:
        d = h.Display(str(root), ['--agent-scope', 'control', '--break', unavailable[label][1] if label in unavailable else 'main', '--', str(executable), *arguments])
        d.tool('continue', generation=d.session()['generation'])
        assert d.stopped('breakpoint')
        view = poll_tabs(d, lambda v: v['complete'])
        tabs = [t['tab'] for t in view['tabs'] if t['visible']]
        assert tabs == ['registers', 'native', *languages], view
        if label in unavailable:
            language, _, reason, hint = unavailable[label]
            entry = next(t for t in view['tabs'] if t['tab']==language)
            assert entry['status']=='unavailable' and entry['reason']==reason and not entry['visible'], entry
            deadline = time.monotonic()+15
            while True:
                shot = d.shot(label+'-hint')
                text = subprocess.run(['tesseract', shot, 'stdout', '--psm', '11'], env=dict(d.env, OMP_THREAD_LIMIT='1'), capture_output=True, text=True, check=True, timeout=30).stdout
                if hint.lower() in text.lower(): break
                assert time.monotonic()<deadline, text
                time.sleep(.1)
            (Path(shot+'.txt')).write_text(text)
        generation = d.session()['generation']
        tid = d.session()['threads'][0]['tid']
        registers = d.tool('get_registers', tid=tid)
        selected = 'native'
        for _ in range(len(tabs)):
            expected = tabs[(tabs.index(selected)+1) % len(tabs)]
            d.keys('tap', 15)
            view = poll_tabs(d, lambda v: v['selected'] == expected)
            selected = expected
        assert selected == 'native'
        # The first tab is always at the left of the right pane. Then select
        # the second tab. Coordinates refer only to this private 1280x800 output.
        d.keys('click', 1040, 108)
        poll_tabs(d, lambda v: v['selected'] == 'registers')
        d.keys('click', 1100, 108)
        poll_tabs(d, lambda v: v['selected'] == 'native')
        if languages:
            d.tool('select_language_tab', generation=generation, tab=languages[-1])
            poll_tabs(d, lambda v: v['selected'] == languages[-1])
        time.sleep(.3)
        d.shot(label+'-tabs')
        assert d.tool('get_registers', tid=tid) == registers
        assert d.session()['generation'] == generation
        # A presentation change is forbidden to an observing MCP client;
        # the human's local keyboard selection remains available.
        d.keys('tap', 66)
        assert d.wait(lambda state: state['agent_scope'] == 'observe')
        response = d.request('tools/call', {'name': 'select_language_tab', 'arguments': {
            'generation': d.session()['generation'], 'tab': 'registers'}})
        assert response.get('isError') and response['content'][0]['text'] == 'AgentScopeDenied', response
        d.keys('tap', 15)
        poll_tabs(d, lambda v: v['selected'] != (languages[-1] if languages else 'native'))
        report.update(status='pass', tabs=view)
    except BaseException as exc:
        report.update(status='fail', error=repr(exc))
        raise
    finally:
        if d:
            d.close()
        results.append(report)
        (work/'results.json').write_text(json.dumps(results, indent=2)+'\n')
print('Language tab private GUI checks passed:', len(results), 'owned targets')
