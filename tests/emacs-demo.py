#!/usr/bin/env python3
"""Fast component lane: the actual Emacs demo launcher, four stops and output."""
import argparse, json, os, resource, subprocess, time
from pathlib import Path
from client import Client

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--emacs', type=Path, required=True)
p.add_argument('--work', type=Path, required=True)
p.add_argument('--agent', type=Path)
p.add_argument('--wrong-oracle', action='store_true')
a = p.parse_args()
os.umask(0o022)
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
root = Path(__file__).resolve().parents[1]
w = a.work.resolve()
w.mkdir(parents=True, mode=0o755, exist_ok=False)
os.environ.update(EMACS=str(a.emacs.resolve()), XODB=str(root/'zig-out/bin/xodb'),
                  XODB_BIN=str(root/'scripts/demo-emacs'), XDG_CACHE_HOME=str(w/'cache'))
started = time.monotonic()
c = None
result = {'status': 'failed'}
try:
    plain = subprocess.run([str(a.emacs.resolve()), '-Q', '--batch', '-l', 'examples/emacs-demo.el'],
                           cwd=root, capture_output=True, text=True, timeout=30)
    (w/'plain.log').write_text(plain.stdout + plain.stderr)
    assert plain.returncode == 0 and plain.stdout == (
        '* TODO PROFILE DELTA [2]\n* TODO CACHE BUDGET [3]\n'
        'Total: 2 tasks / 5 points\nRejected: Task points must be an integer\n'), plain
    c = Client('control', None, options=['--runtime-agent', str(a.agent.resolve())] if a.agent else [])
    stops = []
    for label in ('item', 'item', 'render', 'error'):
        c.continue_initial_stop()
        state = c.stopped('breakpoint', seconds=180)
        tid, generation = state['pid'], state['generation']
        frames = c.inspect('get_language_stack', language='elisp', tid=tid)['segments'][0]['frames']
        mark = next(i for i, f in enumerate(frames) if f['name'] == 'xodb-demo-checkpoint')
        summary = next(i for i, f in enumerate(frames) if f['name'] == 'xodb-demo-summary')
        assert summary > mark and frames[mark]['native_binding'], frames
        locals_ = c.inspect('get_language_locals', language='elisp', generation=generation,
                            tid=tid, segment=0, frame=mark)
        row = next(r for r in locals_['rows'] if r['name'] == 'label')
        expected = 'wrong' if a.wrong_oracle else label
        assert row['scope'] == 'lexical' and row['value']['display'] == json.dumps(expected), ('demo label mismatch', row, expected)
        nearby = c.inspect('get_language_locals', language='elisp', generation=generation,
                           tid=tid, segment=0, frame=mark+1)
        shown = {r['name']: r['value']['display'] for r in nearby['rows']}
        if label == 'item':
            assert shown['title'] == json.dumps('Profile delta' if not stops else 'Cache budget'), shown
            assert shown['points'] == ('2' if not stops else '3'), shown
        elif label == 'render':
            assert shown['demo-stage'] == '"render"', shown
            outer = c.inspect('get_language_locals', language='elisp', generation=generation,
                              tid=tid, segment=0, frame=mark+2)
            assert {r['name'] for r in outer['rows']} == {'lines'}, outer
            parent = next(i for i, f in enumerate(frames) if i > mark and f['name'] == 'let*')
            dynamic = c.inspect('get_language_locals', language='elisp', generation=generation,
                                tid=tid, segment=0, frame=parent)
            assert next(r for r in dynamic['rows'] if r['name'] == 'total')['value']['display'] == '5', dynamic
            assert next(r for r in dynamic['rows'] if r['name'] == 'demo-stage')['value']['display'] == '"normalize"', dynamic
        assert c.session()['generation'] == generation
        stops.append(dict(label=label, marker=mark, summary=summary, locals=locals_, nearby=nearby))
    c.continue_initial_stop()
    deadline = time.monotonic() + 15
    while c.session()['state'] != 'exited':
        assert time.monotonic() < deadline
        time.sleep(.002)
    result = dict(status='pass', seconds=time.monotonic()-started, stops=stops, agent=bool(a.agent))
finally:
    (w/'results.json').write_text(json.dumps(result, indent=2)+'\n')
    if c:
        c.close()
        (w/'rpc.json').write_text(json.dumps(c.transcript, indent=2)+'\n')
        (w/'stderr.log').write_bytes(c.p.stderr.read())
print('Emacs demo: real launcher, four named stops, lexical arguments and exact output PASS')
