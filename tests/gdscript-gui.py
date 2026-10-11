#!/usr/bin/env python3
"""GDScript tab on a private compositor: the script stack of an owned
Godot 4 / Redot game with res:// path:line, each level's native call frame,
and a selected level (fast lane; GUI <= ~15 s).
Run: python3 tests/gdscript-gui.py --redot /path/to/engine --work out/gdg"""
import argparse, importlib.util, json, os, re, shutil, subprocess, tempfile, time
from pathlib import Path
from PIL import Image, ImageOps
p = argparse.ArgumentParser(description=__doc__); p.add_argument('--redot', required=True); p.add_argument('--work', type=Path, required=True); a = p.parse_args()
root = Path(__file__).resolve().parents[1]; os.chdir(root); os.umask(0o022)
a.work.mkdir(parents=True, exist_ok=True)
w = Path(tempfile.mkdtemp(prefix='gd-', dir=a.work.resolve())); w.chmod(0o755)
spec = importlib.util.spec_from_file_location('private_input', root / 'tests/helpers/input.py'); h = importlib.util.module_from_spec(spec); spec.loader.exec_module(h); h.WORK = str(w)
for name in ('tmp', 'cache/mesa', 'cache/nvidia'): (w / name).mkdir(parents=True, exist_ok=True)
started = time.monotonic()
engine = Path(a.redot).resolve()
DELAY = '_ZNK8CoreBind2OS10delay_msecEi'   # the engine function behind the script's OS.delay_msec()
each = (engine.stat().st_size * 11 // 10 >> 20) + 1
limits = ['--image-limit', f'{each}M', '--image-total-limit', f'{max(2 * each, 512)}M']
shutil.copytree(root / 'tests/fixtures/redot', w / 'project')
log = open(w / 'game.out', 'wb')
game = subprocess.Popen([str(engine), '--headless', '--path', str(w / 'project')], stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
d = None
try:
    deadline = time.monotonic() + 120
    while True:
        lines = (w / 'game.out').read_text(errors='replace').splitlines()
        truth = [json.loads(l.split(' ', 2)[2]) for l in lines if l.startswith('ORACLE stack ')]
        if truth: truth = truth[0]; break
        assert game.poll() is None and time.monotonic() < deadline, lines[-8:]
        time.sleep(.02)
    h.Display.reply_seconds = 120  # the first read of a gigabyte image on a busy host
    d = h.Display(str(root), ['--agent-scope', 'control', '--attach', str(game.pid), '--break', DELAY, *limits])
    def stack(generation):
        deadline = time.monotonic() + 120
        while True:
            reply = d.request('tools/call', {'name': 'get_language_stack', 'arguments': {'tid': game.pid, 'language': 'gdscript', 'generation': generation}})
            if not reply.get('isError'): return reply['structuredContent']
            assert reply['content'][0]['text'].endswith('Pending') and time.monotonic() < deadline, reply
            time.sleep(.02)
    # The main thread at the breakpoint under Worker.leaf (other threads sleep there too).
    deadline = time.monotonic() + 120
    while True:
        s = d.wait(lambda s: s['state'] == 'stopped' and not s['symbol_discovery_pending'] and not s['continue_pending'], seconds=120)
        assert s, d.tail()
        generation = s['generation']
        found = stack(generation)
        if found['in_script'] and any(t['tid'] == game.pid and t['reason'] == 'breakpoint' for t in s['threads']): break
        assert time.monotonic() < deadline, found
        d.tool('continue', generation=generation)
        d.wait(lambda s: s['generation'] != generation and s['state'] == 'stopped', seconds=60)
    segment = found['segments'][0]
    assert [(f['name'], f['file'], f['line']) for f in segment['frames']] == [(f['function'], f['source'], f['line']) for f in truth], (segment['frames'], truth)
    regs = d.tool('get_registers', tid=game.pid)
    deadline = time.monotonic() + 60
    while True:
        tabs = d.tool('get_language_tabs')['view']['tabs']
        if next(t for t in tabs if t['tab'] == 'gdscript')['status'] == 'ready': break
        assert time.monotonic() < deadline, tabs
        time.sleep(.02)
    d.tool('select_language_tab', generation=generation, tab='gdscript')
    normalize = lambda t: re.sub(r'[^a-z0-9]', '', t.lower())
    def visible(label, wanted):
        deadline = time.monotonic() + 15
        while True:
            shot = d.shot(label); crop = shot + '.side.png'
            with Image.open(shot) as image:
                pane = ImageOps.invert(image.crop((1013, 100, 1272, 520)).convert('L')); pane.resize((pane.width * 3, pane.height * 3)).save(crop)
            text = subprocess.run(['tesseract', crop, 'stdout', '--psm', '6'], env=dict(d.env, OMP_THREAD_LIMIT='1'), capture_output=True, text=True, check=True, timeout=30).stdout
            Path(shot + '.side.txt').write_text(text)
            if all(word in normalize(text) for word in wanted): return text
            assert time.monotonic() < deadline, (label, text)
            time.sleep(.05)
    # The tab, the top function, and the script positions as project paths.
    listing = visible('gdscript-stack', ['gdscript', 'scriptstack4levels', 'leaf', 'native', 'workergd16', 'step', 'workergd12', 'plan', 'maingd20'])
    assert 'res' in normalize(listing), listing
    # Selecting a level selects the native frame that holds its call record.
    view = d.tool('select_language_frame', generation=generation, tid=game.pid, language='gdscript', segment=0, frame=2)['view']
    binding = segment['frames'][2]['native_binding']
    assert view['logical_selection']['frame'] == 2 and view['native_selection']['frame'] == binding['frame'], (view, binding)
    selected = visible('gdscript-selected', ['plan', 'maingd20'])
    # Rendering and selection are presentation only: no resume, no register change.
    assert d.session()['generation'] == generation and d.tool('get_registers', tid=game.pid) == regs
    assert 'overlaps=0' in d.tail() or 'language layout' not in d.tail(), d.tail()
    (w / 'results.json').write_text(json.dumps(dict(status='pass', frames=[f['name'] for f in segment['frames']], ocr=dict(listing=listing, selected=selected), seconds=round(time.monotonic() - started, 1)), indent=2) + '\n')
finally:
    if d: d.close()
    if game.poll() is None: game.kill()
    game.wait(timeout=30); log.close()
print(f'GDScript GUI: tab, script stack with res:// positions and native call frames rendered ({time.monotonic() - started:.1f}s)')
