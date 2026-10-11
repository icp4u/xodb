#!/usr/bin/env python3
"""Fast native Python discovery in the presence of a PE anchor decoy."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import time
from client import Client
from helpers.input import load_scale

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--python', required=True)
p.add_argument('--work', type=Path, required=True)
p.add_argument('--agent')
p.add_argument('--wrong-result', action='store_true')
a = p.parse_args()
if a.agent:
    os.environ['XODB_RUNTIME_AGENT'] = str(Path(a.agent).resolve())
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
w = a.work.resolve()
w.mkdir(parents=True)
spec = importlib.util.spec_from_file_location('cache_image', root/'tests/fixtures/pe/cache-image.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
image = w/'anchor.dll'
fixture.write(image, symbol='_PyRuntime')
rows = []
started = time.monotonic()
scale = load_scale()
try:
    for order in ('before', 'after'):
        evidence = w/(order+'.json')
        c = Client('control', a.python, args=['tests/fixtures/pe/runtime-anchor.py', str(image), order, str(evidence)],
                   options=('--break', 'getppid'), reply_seconds=90*scale)
        try:
            c.continue_initial_stop()
            session = c.stopped('breakpoint', seconds=60*scale)
            placement = json.loads(evidence.read_text())
            assert (placement['pe'] < placement['native']) == (order == 'before'), placement
            tid = next(t['tid'] for t in session['threads'] if t['reason'] == 'breakpoint')
            deadline = time.monotonic() + 60*scale
            while True:
                result = c.tool('get_language_stack', language='python', tid=tid)['result']
                if not result.get('isError'):
                    break
                error = result['content'][0]['text']
                assert error in ('DebugMetadataPending', 'SymbolDiscoveryPending'), error
                assert time.monotonic() < deadline, error
                time.sleep(.005)
            stack = result['structuredContent']
            expected = 'missing_anchor_frame' if a.wrong_result else 'pe_anchor_checkpoint'
            assert expected in json.dumps(stack), stack
            rows.append(dict(order=order, placement=placement, stack=stack, status='pass'))
        finally:
            c.close()
finally:
    (w/'results.json').write_text(json.dumps(dict(checks=rows, seconds=time.monotonic()-started), indent=2)+'\n')
print(json.dumps(dict(status='pass', checks=len(rows), seconds=time.monotonic()-started)))
