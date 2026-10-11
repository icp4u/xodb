#!/usr/bin/env python3
"""The actual scripts/demo-redot launcher, driven without a display: the stop
it promises, and the text its `stack` subcommand prints, against the stack
the demo game printed itself (fast lane; about 3 s).
Run: python3 tests/gdscript-demo.py --redot /path/to/engine --work out/gdd"""
import argparse, importlib.util, json, os, re, signal, subprocess, time
from pathlib import Path
from types import SimpleNamespace

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--redot', type=Path, required=True)
p.add_argument('--work', type=Path, required=True)
a = p.parse_args()
os.umask(0o022)
root = Path(__file__).resolve().parents[1]; os.chdir(root)
w = a.work.resolve(); w.mkdir(parents=True, mode=0o755, exist_ok=True)
runtime = w / 'rt'; runtime.mkdir(mode=0o700, exist_ok=True); runtime.chmod(0o700)
started = time.monotonic()
spec = importlib.util.spec_from_file_location('shared', root / 'tests/shared-sessions.py'); s = importlib.util.module_from_spec(spec); spec.loader.exec_module(s)

# Without an engine the launcher says what it needs and starts nothing.
env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), XODB=str(root / 'zig-out/bin/xodb'))
for name in ('REDOT', 'GODOT', 'REDOT_PROJECT'): env.pop(name, None)
unset = subprocess.run(['scripts/demo-redot'], env=env, capture_output=True, text=True, timeout=30)
assert unset.returncode == 1 and 'Set REDOT to a Redot or Godot 4 engine binary' in unset.stderr, unset
idle = subprocess.run(['scripts/demo-redot', 'stack'], env=env, capture_output=True, text=True, timeout=30)
assert idle.returncode == 1 and 'No running demo session' in idle.stderr, idle

env['REDOT'] = str(a.redot.resolve())
session = runtime / f'xodb-demo-redot-{os.getuid()}'
server = SimpleNamespace(path=session / 'session.sock', clients=[])
def stack_text():
    done = subprocess.run(['scripts/demo-redot', 'stack'], env=env, capture_output=True, text=True, timeout=180)
    return done.returncode, done.stdout + done.stderr
result = {'status': 'failed'}
log = open(w / 'demo.log', 'wb')
# Its own process group: the script, xodb and the game.
demo = subprocess.Popen(['scripts/demo-redot', '--headless', '--agent-scope', 'control'], env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
server.proc = demo
try:
    deadline = time.monotonic() + 180
    while True:
        assert demo.poll() is None, (w / 'demo.log').read_text()
        try: owner = s.Client(server, 'owner'); break
        except (FileNotFoundError, ConnectionRefusedError):
            assert time.monotonic() < deadline, (w / 'demo.log').read_text(); time.sleep(.02)
    owner.claim(ttl_ms=60000)
    ready = lambda state: state['state'] == 'stopped' and not state['symbol_discovery_pending'] and not state['continue_pending']
    state = s.eventually(owner.session, ready, 'attach stop', timeout=180)
    truth = next(json.loads(l.split(' ', 2)[2]) for l in (session / 'game.log').read_text(errors='replace').splitlines() if l.startswith('ORACLE stack '))
    # Space in the GUI: run to the script's OS.delay_msec().
    owner.action('continue')
    state = s.eventually(owner.session, lambda state: ready(state) and any(t['reason'] == 'breakpoint' for t in state['threads']), 'script stop', timeout=180)
    pid = state['pid']
    assert any(t['tid'] == pid and t['reason'] == 'breakpoint' for t in state['threads']), state['threads']
    code, text = stack_text()
    (w / 'demo-stack.txt').write_text(text)
    assert code == 0, text
    lines = text.splitlines()
    assert lines[0] == f'GDScript on thread {pid}: 4 levels, complete', lines[0]
    for level, row in zip(truth, lines[1:5]):
        assert re.fullmatch(rf"  {re.escape(level['function'])} +{re.escape(level['source'])}:{level['line']}   <- native #\d+ .*GDScriptFunction.*call.*", row), (row, level)
    labelled = [l for l in lines if '   <= ' in l]
    assert [l.split('   <= ')[1] for l in labelled] == [f"{f['function']} {f['source']}:{f['line']}" for f in truth], labelled
    # The planted wrong answer: one line off must not match what was printed.
    assert not re.search(rf"^  leaf +res://worker\.gd:{truth[0]['line'] + 1} ", text, re.M), text
    # Reading and printing changed nothing.
    assert owner.session()['generation'] == state['generation']
    result = {'status': 'passed', 'stack': lines[:5], 'labelled_native_frames': len(labelled)}
finally:
    for client in server.clients:
        try: client.close()
        except Exception: pass
    if demo.poll() is None:
        os.killpg(demo.pid, signal.SIGTERM)
        try: demo.wait(timeout=30)
        except subprocess.TimeoutExpired:
            os.killpg(demo.pid, signal.SIGKILL); demo.wait()
    log.close()
    result['seconds'] = round(time.monotonic() - started, 2)
    (w / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result))
assert result['status'] == 'passed', result
