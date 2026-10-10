#!/usr/bin/env python3
"""Owned Emacs stack oracle, presentation, and input capture on private Sway."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import resource
import shutil
import subprocess
import time
from helpers.language_selection import check_layout
from PIL import Image, ImageOps

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--emacs', type=Path, required=True)
p.add_argument('--work', type=Path, required=True)
p.add_argument('--wrong-oracle', action='store_true')
a = p.parse_args()
os.umask(0o022)
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
root = Path(__file__).resolve().parents[1]
w = (a.work / '.work/input-eli').resolve()
w.mkdir(parents=True, mode=0o755)
spec = importlib.util.spec_from_file_location('private_input', root / 'tests/helpers/input.py')
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
h.WORK = str(w)
for name in ('tmp', 'cache/mesa', 'cache/nvidia'):
    (w / name).mkdir(parents=True, exist_ok=True)
for xml, stem in ((h.VPTR, 'virtual-pointer'), (h.VKBD, 'virtual-keyboard')):
    subprocess.run(['wayland-scanner', 'client-header', xml, str(w / (stem + '.h'))], check=True, timeout=10)
    subprocess.run(['wayland-scanner', 'private-code', xml, str(w / (stem + '.c'))], check=True, timeout=10)
h.HELPER = str(w / 'vinput')
subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-I', str(w), 'tests/helpers/vinput.c',
                str(w / 'virtual-pointer.c'), str(w / 'virtual-keyboard.c'),
                '-lwayland-client', '-lxkbcommon', '-lm', '-o', h.HELPER], cwd=root, check=True, timeout=60)
fixture = w / 'fixtures'
shutil.copytree(root / 'tests/fixtures/elisp', fixture)
oracle = w / 'oracle.json'
os.environ.update(XODB_ELISP_MODE='interpreted', XODB_ELISP_FUNCTIONS=str(fixture / 'functions.el'),
                  XODB_ELISP_ORACLE=str(oracle), XODB_ELISP_REPEATS='2')
for name in ('XODB_ELISP_REDEFINE', 'XODB_ELISP_WRONG_ORACLE'):
    os.environ.pop(name, None)
d = None
result = {'status': 'running'}
try:
    d = h.Display(str(root), ['--agent-scope', 'control', '--break', 'Fdebugger_trap', '--',
                             str(a.emacs.resolve()), '-Q', '--batch', '-l', str(fixture / 'driver.el')])
    d.tool('continue', generation=d.session()['generation'])
    stopped = d.wait(lambda s: s['state'] == 'stopped' and any(t['reason'] == 'breakpoint' for t in s['threads']), seconds=180)
    assert stopped, d.session()
    tid = stopped['pid']
    generation = stopped['generation']
    registers = d.tool('get_registers', tid=tid)
    deadline = time.monotonic() + 180
    while True:
        reply = d.request('tools/call', {'name': 'get_language_stack', 'arguments': {'language': 'elisp', 'tid': tid}})
        if not reply.get('isError'):
            break
        assert reply['content'][0]['text'] == 'DebugMetadataPending' and time.monotonic() < deadline, reply
        time.sleep(.03)
    stack = reply['structuredContent']
    (w / 'stack.json').write_text(json.dumps(stack, indent=2) + '\n')
    frames = stack['segments'][0]['frames']
    start = next(i for i, f in enumerate(frames) if f['name'] == 'xodb-elisp-mark')
    actual = [{'name': f['name'], 'nargs': -1 if f['arguments_unevaluated'] else f['argument_count']} for f in frames[start:]]
    expected = json.loads(oracle.read_text())['frames']
    if a.wrong_oracle:
        expected[0]['nargs'] += 1
    assert actual == expected, ('full stable stack mismatch', actual, expected)
    controls = stack['segments'][0]['controls']
    assert any(c['kind'] == 'condition-case' for c in controls), controls
    assert any(c['kind'] == 'unwind cleanup' for c in controls), controls
    assert all(f['kind'] == 'interpreted' and f['reason'] is None for f in frames if f['name'].startswith('xodb-elisp-'))
    while True:
        tabs = d.tool('get_language_tabs')['view']
        if any(t['tab'] == 'elisp' and t['visible'] and t['status'] == 'ready' for t in tabs['tabs']):
            break
        assert time.monotonic() < deadline, tabs
        time.sleep(.03)
    d.tool('select_language_tab', generation=generation, tab='elisp')
    # E must capture all text even before a logical frame is selected.
    def inert_entry(label):
        before = d.session()['generation']
        before_registers = d.tool('get_registers', tid=tid)
        # Separate the caret from the final letter for OCR; Space stays in the field.
        d.keys('tap', 18, 'tap', 32, 'tap', 18, 'tap', 48, 'tap', 22, 'tap', 34, 'tap', 57)
        deadline = time.monotonic() + 30
        while True:
            screenshot = d.shot(label)
            crop = screenshot + '.prompt.png'
            with Image.open(screenshot) as image:
                # Include the selected Elisp tab; locals can fill the entire pane.
                pane = ImageOps.invert(image.crop((1013, 96, 1272, 578)).convert('L'))
                pane.resize((pane.width * 3, pane.height * 3)).save(crop)
            text = subprocess.run(['tesseract', crop, 'stdout', '--psm', '6'], env=dict(d.env, OMP_THREAD_LIMIT='1'), capture_output=True, text=True, check=True, timeout=30).stdout
            Path(screenshot + '.txt').write_text(text)
            normalized = re.sub('[^a-z0-9]', '', text.lower())
            if 'elisp' in normalized and 'debug' in normalized and 'unavailable' in normalized:
                break
            assert time.monotonic() < deadline, text
            time.sleep(.03)
        assert d.session()['generation'] == before and d.session()['state'] == 'stopped'
        assert d.tool('get_registers', tid=tid) == before_registers
        d.keys('tap', 28)  # Unsupported Enter keeps the field and shows its reason.
        d.keys('tap', 16, 'tap', 32)
        assert d.session()['generation'] == before and d.session()['state'] == 'stopped'
        d.keys('tap', 1)
        return screenshot
    initial_entry = inert_entry('elisp-input-without-selection')
    args = dict(generation=generation, language='elisp', tid=tid, segment=0, frame=start)
    selected = d.tool('select_language_frame', **args)['view']
    binding = frames[start]['native_binding']
    assert binding and selected['logical_selection']['native_anchor'] == binding['frame'], selected
    assert selected['logical_selection']['anchor_basis'] == 'reader_arguments', selected
    linked = d.tool('select_native_frame', generation=generation, tid=tid, frame=binding['frame'])['view']
    assert linked['logical_selection']['frame'] == start and linked['logical_selection']['anchor_basis'] == 'reader_arguments', linked
    layout = check_layout(d, 'elisp')
    deadline = time.monotonic() + 30
    while True:
        shot = d.shot('elisp-stack')
        crop = shot + '.link.png'
        with Image.open(shot) as image:
            pane = ImageOps.invert(image.crop((1013, 130, 1272, 578)).convert('L'))
            pane.resize((pane.width * 3, pane.height * 3)).save(crop)
        text = subprocess.run(['tesseract', crop, 'stdout', '--psm', '6'], env=dict(d.env, OMP_THREAD_LIMIT='1'), capture_output=True, text=True, check=True, timeout=30).stdout
        Path(shot + '.txt').write_text(text)
        normalized = re.sub('[^a-z0-9]', '', text.lower())
        if 'interpreted3args' in normalized and 'capplylambda' in normalized and 'argumentsnative' in normalized:
            break
        assert time.monotonic() < deadline, text
        time.sleep(.03)
    assert d.session()['generation'] == generation and d.tool('get_registers', tid=tid) == registers
    shown = d.tool('evaluate_expression', tid=tid, frame=binding['frame'], expression='arg_vector[1]')['value']
    assert shown['visualization']['elisp']['type'] == 'string' and shown['display'] == '"sample"', shown
    d.tool('select_language_tab', generation=generation, tab='native')
    # E, arg_vector[1], Return: use the existing native expression field.
    d.keys('tap', 18, 'tap', 30, 'tap', 19, 'tap', 34, 'down', 42, 'tap', 12, 'up', 42,
           'tap', 47, 'tap', 18, 'tap', 46, 'tap', 20, 'tap', 24, 'tap', 19, 'tap', 26, 'tap', 2, 'tap', 27, 'tap', 28)
    deadline = time.monotonic() + 30
    while True:
        value_shot = d.shot('elisp-native-value')
        text = subprocess.run(['tesseract', value_shot, 'stdout', '--psm', '11'], env=dict(d.env, OMP_THREAD_LIMIT='1'), capture_output=True, text=True, check=True, timeout=30).stdout
        Path(value_shot + '.txt').write_text(text)
        if 'sample' in text.lower(): break
        assert time.monotonic() < deadline, text
        time.sleep(.03)
    d.keys('tap', 1)
    d.tool('select_language_tab', generation=generation, tab='elisp')
    d.tool('continue', generation=generation)
    next_stop = d.wait(lambda s: s['generation'] > generation and s['state'] == 'stopped' and any(t['reason'] == 'breakpoint' for t in s['threads']), seconds=30)
    assert next_stop, d.session()
    assert d.tool('get_language_tabs')['view']['logical_selection'] is None
    repeated_entry = inert_entry('elisp-input-after-continue')
    # The observer can read the same stack. Hidden presentation mutations must refuse directly.
    d.keys('tap', 66)
    assert d.wait(lambda s: s['agent_scope'] == 'observe')
    observed = d.tool('get_language_stack', language='elisp', tid=tid)
    assert observed['segments'][0]['frames']
    denied = {}
    for name, fields in [('select_language_tab', {'tab': 'elisp'}),
                         ('select_language_frame', {'language': 'elisp', 'tid': tid, 'segment': 0, 'frame': start})]:
        reply = d.request('tools/call', {'name': name, 'arguments': dict(generation=d.session()['generation'], **fields)})
        assert reply.get('isError') and reply['content'][0]['text'] == 'AgentScopeDenied', reply
        denied[name] = reply['content'][0]['text']
    result = dict(status='pass', stable_frames=len(actual), controls=len(controls), layout=layout,
                  screenshots=[shot, value_shot, initial_entry, repeated_entry], direct_observer_denials=denied)
finally:
    (w / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    if d is not None:
        d.close()
print('elisp GUI: exact stack, controls, segment links, input capture and observer scope PASS')
