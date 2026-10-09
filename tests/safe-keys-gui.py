#!/usr/bin/env python3
"""Owned GUI targets survive accidental words; modified detach/quit remain explicit."""
import argparse
import ctypes
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', required=True, type=Path)
p.add_argument('--binary', type=Path)
p.add_argument('--agent', type=Path)
p.add_argument('--size', nargs=2, type=int, default=(1280,800), metavar=('WIDTH','HEIGHT'))
a = p.parse_args()
root = Path(__file__).resolve().parents[1]; os.chdir(root); os.umask(0o022)
w = (a.work / '.work/input-safe').resolve(); w.mkdir(mode=0o755, parents=True, exist_ok=True)
assert ctypes.CDLL(None).prctl(36, 1, 0, 0, 0) == 0  # Reap only our explicitly detached children.
spec = importlib.util.spec_from_file_location('private_input', root/'tests/helpers/input.py')
h = importlib.util.module_from_spec(spec); spec.loader.exec_module(h); h.WORK = str(w)
for name in ('tmp', 'cache/mesa', 'cache/nvidia'): (w/name).mkdir(parents=True)
for xml, stem in ((h.VPTR, 'virtual-pointer'), (h.VKBD, 'virtual-keyboard')):
    subprocess.run(['wayland-scanner', 'client-header', xml, str(w/(stem+'.h'))], check=True, timeout=10)
    subprocess.run(['wayland-scanner', 'private-code', xml, str(w/(stem+'.c'))], check=True, timeout=10)
h.HELPER = str(w/'vinput')
subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-I'+str(w), 'tests/helpers/vinput.c',
                str(w/'virtual-pointer.c'), str(w/'virtual-keyboard.c'), '-lwayland-client', '-lxkbcommon', '-lm', '-o', h.HELPER], check=True, timeout=60)
source = w/'fixture.c'; fixture = w/'fixture'
source.write_text('#include <unistd.h>\n__attribute__((noinline)) void safe_marker(void) { __asm__ volatile("" ::: "memory"); }\nint main(void) { safe_marker(); for (;;) pause(); }\n')
subprocess.run(['cc', '-g', '-O0', str(source), '-o', str(fixture)], check=True, timeout=60)
letters = dict(zip('abcdefghijklmnopqrstuvwxyz', [30,48,46,32,18,33,34,35,23,36,37,38,50,49,24,25,16,19,31,20,22,47,17,45,21,44]))
results = []


def shifted(d, key):
    d.keys('down', 42, 'tap', letters[key], 'up', 42)


def unchanged(d, before, label):
    # F8 is applied after the preceding queued input, giving an owner-loop
    # acknowledgement without treating a screenshot delay as proof of handling.
    # Scope changes advance the generation; target event history must stay fixed.
    scope = d.session()['agent_scope']
    d.keys('tap', 66)
    after = d.wait(lambda s: s['agent_scope'] != scope)
    assert after and (after['pid'], after['last_event_sequence'], after['state']) == (before['pid'], before['last_event_sequence'], 'stopped'), (label, before, after)
    d.keys('tap', 66); assert d.wait(lambda s: s['agent_scope'] == scope)
    results.append(dict(check=label, status='pass'))


try:
    for action in ('detach', 'family', 'quit'):
        d = None; pid = None; pidfd = None
        try:
            options = ['--agent-scope', 'control', '--follow-forks', '--break', 'safe_marker',
                       *(['--runtime-agent', str(a.agent.resolve())] if a.agent else []), '--', str(fixture)]
            d = h.Display(str(root), options, binary=str(a.binary.resolve()) if a.binary else None, output_size=tuple(a.size))
            assert d.stopped()
            d.keys('tap', 63); before = d.stopped('breakpoint'); assert before
            pid = before['pid']; pidfd = os.pidfd_open(pid)
            # The expression editor was opened, then lost its input ownership.
            d.keys('tap', 18, 'tap', 1)
            for word in ('debug', 'round', 'quit', 'kill'):
                d.keys(*[part for char in word for part in ('tap', letters[char])])
                unchanged(d, before, action+': lost-focus '+word)
                d.keys('tap', 1, 'tap', 1)
            d.keys('tap', 58, 'tap', 32, 'tap', 16, 'tap', 58)
            unchanged(d, before, action+': Caps Lock is not Shift')
            d.keys('tap', 18, 'down', 42, 'tap', 32, 'tap', 16, 'up', 42)
            unchanged(d, before, action+': editor owns Shift+D and Shift+Q')
            d.shot(action+'-editor'); d.keys('tap', 1, 'tap', 1)
            unchanged(d, before, action+': Escape leaves workspace open')
            if action == 'family':
                d.keys('tap', 24, 'tap', 32, 'tap', 1)  # O, bare d, close panel.
                unchanged(d, before, 'family: bare d does not release process')
                d.keys('tap', 24)
            if action != 'quit':
                shifted(d, 'd')
                assert d.wait(lambda s: s['state'] == 'idle'), d.session()
                assert Path(f'/proc/{pid}').exists()
                status = Path(f'/proc/{pid}/status').read_text()
                assert next(line for line in status.splitlines() if line.startswith('TracerPid:')).split()[1] == '0', status
                results.append(dict(check=action+': Shift+D detached and preserved owned fixture', status='pass'))
                if action == 'family': d.keys('tap', 1)
            shifted(d, 'q'); assert d.app.wait(timeout=10) == 0
            if action == 'quit':
                assert not Path(f'/proc/{pid}').exists(), 'owned launch survived explicit quit'
            else:
                assert Path(f'/proc/{pid}').exists(), 'explicitly detached fixture was killed on quit'
            results.append(dict(check=action+': Shift+Q honors target ownership', status='pass'))
        finally:
            if d: d.close()
            if pidfd is not None:
                try: signal.pidfd_send_signal(pidfd, signal.SIGKILL)
                except ProcessLookupError: pass
                try: os.waitpid(pid, 0)
                except ChildProcessError: pass
                os.close(pidfd)
finally:
    (w/'results.json').write_text(json.dumps(dict(checks=results, expected_checks=27), indent=2)+'\n')
assert len(results) == 27, results
print('Safe GUI keys: 27 lost-focus/modifier/editor/ownership checks passed')
