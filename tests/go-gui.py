#!/usr/bin/env python3
"""Go tab on a private compositor: goroutine list and a selected parked
goroutine's stack (fast lane; GUI <= ~15 s)."""
import argparse, importlib.util, json, os, re, subprocess, tempfile, time
from pathlib import Path
from PIL import Image, ImageOps
p = argparse.ArgumentParser(description=__doc__); p.add_argument('--go', required=True); p.add_argument('--work', type=Path, required=True); a = p.parse_args()
root = Path(__file__).resolve().parents[1]; os.chdir(root); os.umask(0o022)
a.work.mkdir(parents=True, exist_ok=True)
w = Path(tempfile.mkdtemp(prefix='go-', dir=a.work.resolve())); w.chmod(0o755)
spec = importlib.util.spec_from_file_location('private_input', root / 'tests/helpers/input.py'); h = importlib.util.module_from_spec(spec); spec.loader.exec_module(h); h.WORK = str(w)
for name in ('tmp', 'cache/mesa', 'cache/nvidia'): (w / name).mkdir(parents=True, exist_ok=True)
started = time.monotonic()
env = dict(os.environ, GOCACHE=str(w / 'gocache'), GOPATH=str(w / 'gopath'), GOFLAGS='', GOTOOLCHAIN='local', CGO_ENABLED='0')
exe = w / 'go-demo'
subprocess.run([a.go, 'build', '-o', str(exe), 'go-demo.go'], cwd=root / 'examples', env=env, check=True, timeout=120)
d = None
try:
    d = h.Display(str(root), ['--agent-scope', 'control', '--', str(exe), str(w / 'truth.txt')])
    d.tool('set_breakpoint', generation=d.session()['generation'], symbol='main.marker')
    d.tool('continue', generation=d.session()['generation'])
    s = d.wait(lambda s: s['state'] == 'stopped' and any(t['reason'] == 'breakpoint' for t in s['threads']), seconds=30)
    assert s, d.tail()
    tid = next(t['tid'] for t in s['threads'] if t['reason'] == 'breakpoint')
    deadline = time.monotonic() + 30
    while True:
        reply = d.request('tools/call', {'name': 'get_language_stack', 'arguments': {'tid': tid, 'language': 'go'}})
        if not reply.get('isError'): stack = reply['structuredContent']; break
        assert reply['content'][0]['text'].endswith('Pending') and time.monotonic() < deadline, reply
        time.sleep(.02)
    si = next(i for i, seg in enumerate(stack['segments']) if any(f['name'] == 'main.blocked' for f in seg['frames']))
    fi = next(i for i, f in enumerate(stack['segments'][si]['frames']) if f['name'] == 'main.blocked')
    generation = d.session()['generation']; regs = d.tool('get_registers', tid=tid)
    while True:
        tabs = d.tool('get_language_tabs')['view']['tabs']
        if next(t for t in tabs if t['tab'] == 'go')['status'] == 'ready': break
        assert time.monotonic() < deadline, tabs
        time.sleep(.02)
    d.tool('select_language_tab', generation=generation, tab='go')
    view = d.tool('select_language_frame', generation=generation, tid=tid, language='go', segment=si, frame=fi)['view']
    assert view['logical_selection']['segment'] == si and view['logical_selection']['frame'] == fi, view
    normalize = lambda t: re.sub(r'[^a-z0-9]', '', t.lower())
    def visible(label, wanted):
        deadline = time.monotonic() + 15
        while True:
            shot = d.shot(label); crop = shot + '.side.png'
            with Image.open(shot) as image:
                pane = ImageOps.invert(image.crop((1013, 130, 1272, 480)).convert('L')); pane.resize((pane.width * 3, pane.height * 3)).save(crop)
            text = subprocess.run(['tesseract', crop, 'stdout', '--psm', '6'], env=dict(d.env, OMP_THREAD_LIMIT='1'), capture_output=True, text=True, check=True, timeout=30).stdout
            Path(shot + '.side.txt').write_text(text)
            if all(word in normalize(text) for word in wanted): return text
            assert time.monotonic() < deadline, (label, text)
            time.sleep(.05)
    # A parked goroutine's stack: the inlined Mutex.Lock frames and the caller.
    parked = visible('go-parked-stack', ['mutexlock', 'mainblocked', 'godemogo'])
    # The goroutine list: the stopped thread's goroutine first, then the others.
    d.tool('select_language_frame', generation=generation, tid=tid, language='go', segment=0, frame=0)
    listing = visible('go-goroutines', ['goroutine1', 'running', 'mainmarker', 'mainmain'])
    # Rendering and selection are presentation only: no resume, no register change.
    assert d.session()['generation'] == generation and d.tool('get_registers', tid=tid) == regs
    (w / 'results.json').write_text(json.dumps(dict(status='pass', goroutines=len(stack['segments']), selected=[si, fi], ocr=dict(parked=parked, listing=listing), seconds=round(time.monotonic() - started, 1)), indent=2) + '\n')
finally:
    if d: d.close()
print(f'Go GUI: goroutine list and selected main.blocked stack rendered ({time.monotonic() - started:.1f}s)')
