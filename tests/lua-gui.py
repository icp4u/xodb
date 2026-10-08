#!/usr/bin/env python3
"""Lua Locals/Watch and demo checks on private headless compositors only."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import time
from helpers.language_selection import check as check_selection

root = Path(__file__).resolve().parent.parent
os.chdir(root)
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--lua', action='append', required=True)
p.add_argument('--work', type=Path, required=True)
args = p.parse_args()
os.umask(0o022)
work = (args.work/'.work/input-lua').resolve()
work.mkdir(parents=True, mode=0o755)
spec = importlib.util.spec_from_file_location('private_input', root/'tests/helpers/input.py')
h = importlib.util.module_from_spec(spec); spec.loader.exec_module(h)
h.WORK = str(work)
for name in ('tmp', 'cache/mesa', 'cache/nvidia'):
    (work/name).mkdir(parents=True, exist_ok=True)
for xml, stem in ((h.VPTR, 'virtual-pointer'), (h.VKBD, 'virtual-keyboard')):
    subprocess.run(['wayland-scanner', 'client-header', xml, str(work/(stem+'.h'))], check=True, timeout=10)
    subprocess.run(['wayland-scanner', 'private-code', xml, str(work/(stem+'.c'))], check=True, timeout=10)
h.HELPER = str(work/'vinput')
subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-I', str(work), 'tests/helpers/vinput.c',
    str(work/'virtual-pointer.c'), str(work/'virtual-keyboard.c'), '-lwayland-client', '-lxkbcommon', '-lm', '-o', h.HELPER], check=True, timeout=60)
results = []
for lua in args.lua:
    d = None
    demo = None
    try:
        d = h.Display(str(root), ['--agent-scope', 'control', '--break', 'luaB_print', '--', lua, 'examples/lua-demo.lua'])
        for _ in range(5):
            d.keys('tap', 57)
            assert d.stopped('breakpoint')
        tid = next(t['tid'] for t in d.session()['threads'] if t['reason']=='breakpoint')
        state = d.tool('evaluate_expression', tid=tid, frame=0, expression='L')['value']
        assert 'top: table {' in state['display'] and 'answer' in state['display'], state
        d.keys('tap', 18, 'down', 42, 'tap', 38, 'up', 42, 'tap', 28)
        time.sleep(.3); d.shot('lua-table-watch')
        deadline = time.monotonic() + 30
        while True:
            tabs = d.tool('get_language_tabs')['view']
            if any(t['tab'] == 'lua' and t['visible'] and t['status'] == 'ready' for t in tabs['tabs']): break
            assert time.monotonic() < deadline, tabs
            time.sleep(.03)
        d.tool('select_language_tab', generation=d.session()['generation'], tab='lua')
        time.sleep(.3); d.shot('lua-language-stack')
        selection = check_selection(d, tid, 'lua', 'lua-linked')
        (Path(d.dir)/'language-selection.json').write_text(json.dumps(selection, indent=2)+'\n')
        d.tool('select_language_tab', generation=d.session()['generation'], tab='native')
        d.keys('tap', 66)
        assert d.wait(lambda s:s['agent_scope']=='observe')
        generation = d.session()['generation']; registers = d.tool('get_registers', tid=tid)
        logical = d.tool('get_language_stack', tid=tid, language='lua')
        assert logical['segments'][0]['frames'][0]['kind']=='C'
        assert d.tool('get_registers', tid=tid)==registers and d.session()['generation']==generation
        results.append({'lua':lua, 'value':state, 'stack':logical})
        d.app.stdin.close(); assert d.app.wait(timeout=10)==0
        env = dict(d.env, LUA=lua, XODB=str(root/'zig-out/bin/xodb'))
        with (Path(d.dir)/'demo.log').open('wb') as log:
            demo = subprocess.Popen(['scripts/demo-lua'], env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
            socket = Path(d.runtime)/f'xodb-demo-lua-{os.getuid()}'/'session.sock'
            deadline = time.monotonic()+20
            while not socket.exists() and time.monotonic()<deadline:
                assert demo.poll() is None
                time.sleep(.1)
            assert socket.exists()
            time.sleep(.5)
            outputs=[]
            for _ in range(2):
                d.keys('tap',57)
                deadline=time.monotonic()+10
                while time.monotonic()<deadline:
                    result=subprocess.run(['scripts/demo-lua','stack'],env=env,capture_output=True,text=True,timeout=10)
                    if result.returncode==0 and 'L = ' in result.stdout and result.stdout not in outputs: break
                    time.sleep(.1)
                assert result.returncode==0 and 'top:' in result.stdout and result.stdout not in outputs, result.stdout+result.stderr
                outputs.append(result.stdout)
            (Path(d.dir)/'demo-stack.txt').write_text('\n'.join(outputs))
            d.keys('tap',18,'down',42,'tap',38,'up',42,'tap',28)
            time.sleep(.3); d.shot('lua-demo-watch')
    finally:
        if demo and demo.poll() is None:
            demo.send_signal(signal.SIGTERM)
            try: demo.wait(timeout=10)
            except subprocess.TimeoutExpired: demo.kill(); demo.wait(timeout=5)
        if d: d.close()
(work/'results.json').write_text(json.dumps({'status':'pass','results':results},indent=2)+'\n')
print('Lua private GUI and demo checks passed:',len(results),'versions')
