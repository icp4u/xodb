#!/usr/bin/env python3
"""App-side live equivalence: frames from the real --live helper are applied by the
app's own delta State (src/profile/agent_time_replay.zig); after every applied
frame the document must equal a full reparse of the same bytes. Lost, duplicated
or stale frames must be rejected without changing the published document.

Synthetic logs only. Manual real-log mode (not registered):
  python3 tests/agent-time-equivalence.py --mirror SESSION.jsonl --rounds 6 --pause 20
mirrors a live Claude session by appending only the bytes it gained."""
import argparse, importlib.util, json, os, shutil, subprocess, sys, tempfile, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ADAPTER = ROOT / 'src/profile/agent_time.py'
spec = importlib.util.spec_from_file_location('agent_time', ADAPTER)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)


class Pipe:
    def __init__(self, argv):
        self.p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    def frame(self, data=None):
        if data is not None:
            self.p.stdin.write(len(data).to_bytes(4, 'big') + data)
        self.p.stdin.flush()
        n = int.from_bytes(self.read(4), 'big')
        return self.read(n)
    def read(self, n):
        out = b''
        while len(out) < n:
            chunk = self.p.stdout.read(n - len(out))
            if not chunk: raise RuntimeError('pipe closed')
            out += chunk
        return out
    def close(self):
        self.p.stdin.close(); assert self.p.wait(timeout=20) == 0


class Helper(Pipe):
    def __init__(self, agent, path):
        super().__init__([sys.executable, '-I', '-B', str(ADAPTER), '--agent', agent, '--file', str(path), '--live'])
    def refresh(self):
        self.p.stdin.write(b'refresh\n')
        return self.frame()


def norm(doc):
    doc = json.loads(json.dumps(doc))
    def walk(x):
        for key in ('live_read_bytes', 'live_mode', 'source_fingerprint'): x.pop(key, None)
        for child in x.get('children', []): walk(child)
    walk(doc); m.strip_internal(doc)
    return doc


def first_diff(a, b, p=''):
    if type(a) != type(b) and not (isinstance(a, (int, float)) and isinstance(b, (int, float))): return p + ' type'
    if isinstance(a, dict):
        for k in sorted(set(a) | set(b)):
            if k not in a or k not in b: return p + '/' + k + ' missing'
            r = first_diff(a[k], b[k], p + '/' + k)
            if r: return r
    elif isinstance(a, list):
        if len(a) != len(b): return f'{p} len {len(a)}/{len(b)}'
        for i, (x, y) in enumerate(zip(a, b)):
            r = first_diff(x, y, f'{p}[{i}]')
            if r: return r
    elif a != b and not (isinstance(a, float) and isinstance(b, (int, float)) and abs(a - b) < 1e-9): return p + ' value'
    return None


class Check:
    def __init__(self, replay):
        self.replay = Pipe([str(replay)]); self.frames = 0; self.deltas = 0; self.resets = 0
    def helper(self, agent, path):
        # The app clears its delta state whenever it (re)starts a helper.
        assert json.loads(self.replay.frame(b'reset-state')).get('ok')
        return Helper(agent, path)
    def apply(self, frame):
        reply = json.loads(self.replay.frame(frame))
        return reply
    def step(self, helper, agent, path, label):
        frame = helper.refresh()
        if len(frame) < 256 and json.loads(frame).get('unchanged'): return None
        kind = 'reset' if b'"reset":' in frame[:200] else 'delta'
        reply = self.apply(frame)
        assert 'doc' in reply, (label, reply)
        app, full = norm(reply['doc']), norm(m.read_session(agent, complete_prefix(agent, path)))
        diff = first_diff(app, full)
        assert diff is None, (label, kind, diff)
        self.frames += 1; self.deltas += kind == 'delta'; self.resets += kind == 'reset'
        return frame, kind, len(frame)


def complete_end(path):
    """Live reads hold back an unfinished line, unless it is already oversize."""
    data = path.read_bytes(); end = data.rfind(b'\n') + 1
    return len(data) if len(data) - end > m.MAX_LINE else end


def complete_prefix(agent, path):
    """The full-import oracle: every counter kept, over the bytes live has consumed."""
    files = [path] + (sorted(path.with_suffix('').glob('subagents/agent-*.jsonl')) if agent == 'claude' else
                      [path.with_name('chat_history.jsonl')] if agent == 'grok' else [])
    if all(complete_end(f) == f.stat().st_size for f in files if f.exists()): return path
    # Grok derives its project from the two directory names above the session file.
    base = path.parents[2] if agent == 'grok' else path.parent; out = Path(tempfile.mkdtemp(dir=base.parent)) / base.name
    for f in [p for p in base.rglob('*') if p.is_file()]:
        dst = out / f.relative_to(base); dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes(f.read_bytes()[:complete_end(f)] if f in files else f.read_bytes())
    return out / path.relative_to(base)


def jl(rows): return ''.join(json.dumps(r) + '\n' for r in rows)
def cx(t, k, **f): return {'timestamp': t, 'type': 'response_item' if k in ('message', 'function_call', 'function_call_output') else 'event_msg', 'payload': {'type': k, **f}}


def codex(check, work):
    path = work / 'codex' / 'codex.jsonl'; path.parent.mkdir()
    path.write_text(jl([cx(1, 'task_started'), cx(1, 'message', role='user', content=[{'type': 'input_text', 'text': 'synthetic A33-M1'}])]))
    h = check.helper('codex', path)
    check.step(h, 'codex', path, 'codex initial')
    t = 2
    for i in range(4):
        with path.open('a') as f: f.write(jl([cx(t, 'function_call', call_id=f'c{i}', name='exec', arguments=json.dumps({'cmd': 'git diff --stat'})),
                                              cx(t + 1, 'token_count', info={'total_token_usage': {'input_tokens': 100 * (i + 1), 'cached_input_tokens': 50 * (i + 1), 'output_tokens': 7 * (i + 1)}})]))
        assert check.step(h, 'codex', path, f'codex open tool {i}')[1] == 'delta'
        with path.open('a') as f: f.write(jl([cx(t + 2, 'function_call_output', call_id=f'c{i}')]))
        check.step(h, 'codex', path, f'codex close tool {i}'); t += 3
    line = (json.dumps(cx(t, 'message', role='user', content=[{'type': 'input_text', 'text': 'synthetic \u03b1'}]), ensure_ascii=False) + '\n').encode()
    cut = line.index('\u03b1'.encode()) + 1   # inside a UTF-8 sequence
    with path.open('ab') as f: f.write(line[:cut])
    check.step(h, 'codex', path, 'codex partial line')
    with path.open('ab') as f: f.write(line[cut:] + b'{broken}\n[]\n')
    check.step(h, 'codex', path, 'codex partial completed, malformed lines')
    with path.open('ab') as f: f.write(b'x' * (m.MAX_LINE + 100))
    check.step(h, 'codex', path, 'codex oversize partial line')
    with path.open('ab') as f: f.write(b'x' * 40 + b'\n' + jl([cx(t, 'task_complete')]).encode())
    check.step(h, 'codex', path, 'codex oversize line completed')
    data = path.read_bytes(); path.write_bytes(data[:len(data) // 2].rsplit(b'\n', 1)[0] + b'\n')
    assert check.step(h, 'codex', path, 'codex truncated')[1] == 'reset'
    other = path.with_name('codex.new'); other.write_text(jl([cx(50, 'task_started'), cx(51, 'task_complete')])); os.replace(other, path)
    assert check.step(h, 'codex', path, 'codex rotated')[1] == 'reset'
    h.close()


def claude_rows(t0, call, prompt='synthetic G18 work', usage=10, mid='m'):
    return [{'timestamp': t0, 'type': 'user', 'uuid': f'u{t0}', 'message': {'content': prompt}},
            {'timestamp': t0 + 1, 'type': 'assistant', 'uuid': f'a{t0}', 'message': {'id': f'{mid}{t0}', 'usage': {'input_tokens': usage, 'cache_read_input_tokens': 2 * usage, 'output_tokens': 3},
             'content': [{'type': 'tool_use', 'id': call, 'name': 'Agent', 'input': {}}]}},
            {'timestamp': t0 + 4, 'type': 'user', 'uuid': f'r{t0}', 'message': {'content': [{'type': 'tool_result', 'tool_use_id': call, 'content': 'ok'}]}},
            {'timestamp': t0 + 5, 'type': 'assistant', 'uuid': f'e{t0}', 'message': {'id': f'{mid}{t0}e', 'content': [], 'stop_reason': 'end_turn'}}]


def claude(check, work):
    path = work / 'claude' / 'parent.jsonl'; sub = path.with_suffix('') / 'subagents'; path.parent.mkdir()
    path.write_text(jl(claude_rows(1, 'spawn-m')))
    h = check.helper('claude', path)
    check.step(h, 'claude', path, 'claude initial')
    sub.mkdir(parents=True)
    (sub / 'agent-m.jsonl').write_text(jl(claude_rows(2, 'leaf-m', mid='cm')[:2]))
    (sub / 'agent-m.meta.json').write_text(json.dumps({'toolUseId': 'spawn-m', 'description': 'worker m'}))
    check.step(h, 'claude', path, 'claude first child')
    with path.open('a') as f: f.write(jl(claude_rows(10, 'spawn-a')))
    # A new child that sorts before the existing one, plus a nested grandchild.
    (sub / 'agent-a.jsonl').write_text(jl(claude_rows(11, 'leaf-a', mid='ca')))
    (sub / 'agent-a.meta.json').write_text(json.dumps({'toolUseId': 'spawn-a', 'description': 'worker a'}))
    (sub / 'agent-n.jsonl').write_text(jl(claude_rows(3, 'leaf-n', mid='cn')))
    (sub / 'agent-n.meta.json').write_text(json.dumps({'toolUseId': 'leaf-m', 'parentAgentId': 'm', 'description': 'nested'}))
    check.step(h, 'claude', path, 'claude children inserted before and nested')
    # Streamed usage: the same message id again with grown usage, then a partial line.
    with (sub / 'agent-m.jsonl').open('a') as f: f.write(jl([{'timestamp': 4, 'type': 'assistant', 'uuid': 'a2b', 'message': {'id': 'cm2', 'usage': {'input_tokens': 10, 'cache_read_input_tokens': 20, 'output_tokens': 9}, 'content': []}}]) + '{"timest')
    assert check.step(h, 'claude', path, 'claude child streamed usage, partial line')[1] == 'delta'
    with (sub / 'agent-m.jsonl').open('a') as f: f.write('amp": 4}\n' + jl(claude_rows(2, 'leaf-m', mid='cm')[2:]))
    assert check.step(h, 'claude', path, 'claude child grows')[1] == 'delta'
    # A fork replays its spawner's history under the same ids.
    (sub / 'agent-f.jsonl').write_text(jl(claude_rows(10, 'spawn-a')[:2] + claude_rows(20, 'leaf-f', mid='cf')))
    (sub / 'agent-f.meta.json').write_text(json.dumps({'toolUseId': 'spawn-a', 'isFork': True, 'description': 'fork'}))
    check.step(h, 'claude', path, 'claude fork child')
    (sub / 'agent-n.jsonl').unlink(); (sub / 'agent-n.meta.json').unlink()
    assert check.step(h, 'claude', path, 'claude child removed')[1] == 'reset'
    h.close()


def grok(check, work):
    d = work / 'grok' / '%2Fsrv%2Fproj' / 'session'; d.mkdir(parents=True); ev = d / 'events.jsonl'; hist = d / 'chat_history.jsonl'
    ev.write_text(jl([{'ts': 1, 'type': 'turn_started'}]))
    hist.write_text(jl([{'type': 'user', 'content': [{'type': 'text', 'text': 'synthetic KG2'}]}]))
    h = check.helper('grok', ev)
    check.step(h, 'grok', ev, 'grok initial')
    for i in range(3):
        with ev.open('a') as f: f.write(jl([{'ts': 2 + 3 * i, 'type': 'tool_completed', 'tool_name': 'bash', 'tool_call_id': f'g{i}', 'duration_ms': 1500}]))
        with hist.open('a') as f: f.write(jl([{'type': 'assistant', 'tool_calls': [{'id': f'g{i}', 'name': 'bash', 'arguments': json.dumps({'command': 'make -j2'})}]}]))
        check.step(h, 'grok', ev, f'grok tool {i}')
    with ev.open('a') as f: f.write(jl([{'ts': 20, 'type': 'turn_ended', 'outcome': 'success'}]))
    (d / 'usage.json').write_text(json.dumps({'session': {}, 'turns': [{'turnNumber': 1, 'inputTokens': 90, 'cachedReadTokens': 60, 'outputTokens': 9, 'reasoningTokens': 2}]}))
    check.step(h, 'grok', ev, 'grok usage appears')
    (d / 'usage.json').write_text(json.dumps({'session': {}, 'turns': [{'turnNumber': 1, 'inputTokens': 120, 'cachedReadTokens': 60, 'outputTokens': 9, 'reasoningTokens': 2}]}))
    check.step(h, 'grok', ev, 'grok usage replaced')
    h.close()


def faults(replay, work):
    """Lost, duplicated and stale frames are rejected; the published document stays."""
    path = work / 'faults.jsonl'; path.write_text(jl([cx(1, 'task_started')]))
    h = Helper('codex', path); frames = []
    for i in range(4):
        frames.append(h.refresh())
        with path.open('a') as f: f.write(jl([cx(2 + i, 'function_call', call_id=f'f{i}', name='exec', arguments='{}'), cx(3 + i, 'function_call_output', call_id=f'f{i}')]))
    h.close()
    clean = Pipe([str(replay)])
    want = [json.loads(clean.frame(f))['doc'] for f in frames]
    clean.close()
    r = Pipe([str(replay)])
    current = lambda: json.loads(r.frame(b'current'))['doc']
    def ok(i):
        doc = json.loads(r.frame(frames[i])).get('doc')
        assert doc == want[i] and current() == want[i], i
        return True
    def rejected(i, error, published):
        # The error is reported and the published document is byte-for-byte what it was.
        assert json.loads(r.frame(frames[i])).get('error') == error, (i, error)
        assert current() == published, ('published document changed by rejected frame', i, error)
    assert current() is None
    assert ok(0) and ok(1)
    rejected(1, 'InvalidLiveDelta', want[1])            # duplicate
    rejected(3, 'AgentLogDeltaBaseMismatch', want[1])   # frame 2 lost
    rejected(0, 'InvalidLiveDelta', want[1])            # stale reset
    # The next in-order frames still apply on top of the untouched document.
    assert ok(2) and ok(3)
    # A restarted helper starts over at generation 1; the app clears its state first.
    rejected(0, 'InvalidLiveDelta', want[3])
    assert json.loads(r.frame(b'reset-state')).get('ok') and current() is None
    assert ok(0)
    r.close()
    return 5


def mirror(check, src, rounds, pause, work):
    dst = work / 'mirror' / src.name; sub_s, sub_d = src.with_suffix('') / 'subagents', dst.with_suffix('') / 'subagents'
    def sync():
        for a, b in [(src, dst)] + [(f, sub_d / f.name) for f in sorted(sub_s.glob('agent-*.jsonl'))]:
            data = a.read_bytes(); have = b.stat().st_size if b.exists() else 0
            b.parent.mkdir(parents=True, exist_ok=True)
            if len(data) > have:
                with open(b, 'ab') as f: f.write(data[have:])
            meta = a.with_suffix('.meta.json')
            if meta.exists() and not b.with_suffix('.meta.json').exists(): shutil.copy(meta, b.with_suffix('.meta.json'))
    sync(); h = check.helper('claude', dst); rows = []
    for i in range(rounds):
        if i: time.sleep(pause); sync()
        t = time.monotonic(); got = check.step(h, 'claude', dst, f'mirror round {i}')
        rows.append({'round': i, 'kind': got[1] if got else 'unchanged', 'wire_bytes': got[2] if got else 0, 'seconds': round(time.monotonic() - t, 2)})
        print(json.dumps(rows[-1]), flush=True)
    h.close()


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--mirror'); p.add_argument('--rounds', type=int, default=6); p.add_argument('--pause', type=float, default=20)
    args = p.parse_args()
    started = time.monotonic()
    work = Path(tempfile.mkdtemp(prefix='agent-time-eq-', dir=os.environ.get('TMPDIR')))
    os.chmod(work, 0o700)
    try:
        replay = work / 'replay'
        cmd = ['zig', 'build-exe', str(ROOT / 'src/profile/agent_time_replay.zig'), '-lc', '-OReleaseSafe', f'-femit-bin={replay}']
        subprocess.run(cmd, check=True, cwd=work)
        check = Check(replay)
        if args.mirror:
            mirror(check, Path(args.mirror), args.rounds, args.pause, work)
        else:
            codex(check, work); claude(check, work); grok(check, work)
            rejected = faults(replay, work)
            assert check.deltas >= 10 and check.resets >= 5, (check.deltas, check.resets)
        check.replay.close()
        print(json.dumps({'status': 'pass', 'frames': check.frames, 'deltas': check.deltas, 'resets': check.resets, 'seconds': round(time.monotonic() - started, 2)}))
    finally:
        shutil.rmtree(work)


if __name__ == '__main__':
    main()
