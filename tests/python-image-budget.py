#!/usr/bin/env python3
"""The Python view does not depend on the full-image budget of unrelated
libraries, and names that budget when the interpreter's own image exceeds it.
Run: python3 tests/python-image-budget.py --python /path/to/python3 --work out/budget
The target maps sparse padded shared objects whose sizes add up to more than
the total image budget."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
from client import Client

FIXTURE = 'tests/fixtures/python/budget.py'


def limit(name):
    text = Path('src/binary/snapshot.zig').read_text()
    return eval(re.search(rf'pub const {name}: usize = ([0-9* ]+);', text).group(1))


def modules(client):
    regions, cursor = [], None
    while True:
        page = client.inspect('list_modules', **({'cursor': cursor} if cursor else {}))
        regions += page['regions']; cursor = page.get('next')
        if not cursor: return regions, page


def stack(client, **args):
    """The reply once the worker reading the over-sized image's symbols is done."""
    deadline = time.monotonic() + 60
    while True:
        result = client.tool('get_language_stack', language='python', **args)['result']
        if not result.get('isError'): return result['structuredContent'], None
        why = result['content'][0]['text']
        if why not in ('SymbolDiscoveryPending', 'DebugMetadataPending'): return None, why
        assert time.monotonic() < deadline, why
        time.sleep(.005)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--python', required=True)
    p.add_argument('--work', required=True, type=Path)
    a = p.parse_args()
    root = Path(__file__).resolve().parents[1]; os.chdir(root); os.umask(0o022)
    w = a.work.resolve(); w.mkdir(parents=True, mode=0o755)
    total, each = limit('total_limit'), limit('per_image_limit') - (1 << 20)
    count = total // each + 1
    (w/'pad.c').write_text('int xodb_pad(void) { return 7; }\n')
    subprocess.run(['cc', '-shared', '-fPIC', '-O1', str(w/'pad.c'), '-o', str(w/'pad.so')], check=True, timeout=60)
    pads = [w/f'pad{i}.so' for i in range(count)] + [w/'over.so']  # the last exceeds the per-image limit
    for pad in pads:
        shutil.copyfile(w/'pad.so', pad); os.truncate(pad, each if pad.name != 'over.so' else each + (2 << 20))  # a hole, not data
    sizes = [pad.stat().st_size for pad in pads]
    assert sum(sizes[:count]) > total and sizes[-1] > limit('per_image_limit')
    target = subprocess.Popen([a.python, FIXTURE, *map(str, pads)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    client = None; result = {'status': 'running'}
    try:
        line = target.stdout.readline()
        assert line, target.stderr.read()
        addresses = json.loads(line); tid = target.pid
        names = {str(pad) for pad in pads}

        # Every pad is mapped and unread in full; the stack still resolves.
        client = Client('control', None, options=['--attach', str(target.pid)])
        generation = client.stopped()['generation']
        found, why = stack(client, generation=generation, tid=tid)
        assert found, why
        where = [(s, f) for s, segment in enumerate(found['segments']) for f, frame in enumerate(segment['frames']) if frame['name'] == 'leaf']
        assert len(where) == 1 and any(frame['name'] == '<module>' for segment in found['segments'] for frame in segment['frames']), found
        held = client.inspect('evaluate_language_expression', generation=generation, tid=tid, language='python', segment=where[0][0], frame=where[0][1], expression='held')
        assert held['diagnostic'] is None and held['rows'][0]['value']['display'] == 'int 42', held
        regions, page = modules(client)
        mapped = {r['path'] for r in regions}
        assert names <= mapped, (names, mapped)
        assert page['total_load_failures'] == 0 and not any(r['full_image_deferred'] for r in regions), page['load_failures']
        tabs = client.inspect('get_language_tabs')
        deadline = time.monotonic() + 60
        while not tabs['view']['complete']:
            assert time.monotonic() < deadline, tabs
            time.sleep(.01); tabs = client.inspect('get_language_tabs')
        tab = next(t for t in tabs['view']['tabs'] if t['tab'] == 'python')
        assert tab['status'] == 'ready' and tab['reason'] is None, tab
        result['resolved'] = {'frames': [frame['name'] for segment in found['segments'] for frame in segment['frames']], 'tab': tab, 'pad_bytes': sum(sizes), 'total_limit': total}
        client.close(); client = None

        # Spend the budget on the pads first: now the interpreter's own image
        # is the one refused, and both replies name the budget.
        client = Client('control', None, options=['--attach', str(target.pid)])
        generation = client.stopped()['generation']
        for address in addresses[:total // each]:
            client.inspect('get_function_graph', generation=generation, address=hex(address))
        found, why = stack(client, generation=generation, tid=tid)
        assert why == 'PythonImageBudgetExceeded', (found, why)
        tabs = client.inspect('get_language_tabs')
        deadline = time.monotonic() + 60
        while not tabs['view']['complete']:
            assert time.monotonic() < deadline, tabs
            time.sleep(.01); tabs = client.inspect('get_language_tabs')
        tab = next(t for t in tabs['view']['tabs'] if t['tab'] == 'python')
        assert tab['status'] == 'unavailable' and tab['reason'] == 'PythonImageBudgetExceeded' and not tab['visible'], tab
        regions, page = modules(client)
        over = [f for f in page['load_failures'] if f['diagnostic'] == 'BinarySnapshotLimit' and f['path'] not in names]
        assert over, page['load_failures']  # the probe saw the interpreter image refused
        result['refused'] = {'error': why, 'tab': tab, 'load_failures': len(page['load_failures'])}
        client.close(); client = None
        target.stdin.write('\n'); target.stdin.flush()
        target.wait(timeout=10); assert target.returncode == 0, target.stderr.read()

        # A second mapped image defining the runtime symbol is still refused,
        # whichever of the two the symbols-only scan reaches first.
        (w/'decoy.c').write_text('char _PyRuntime[64] = "decoy";\nint xodb_pad(void) { return 7; }\n')
        subprocess.run(['cc', '-shared', '-fPIC', '-O1', str(w/'decoy.c'), '-o', str(w/'decoy.so')], check=True, timeout=60)
        target = subprocess.Popen([a.python, FIXTURE, str(w/'decoy.so')], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        assert target.stdout.readline(), target.stderr.read()
        client = Client('control', None, options=['--attach', str(target.pid)])
        generation = client.stopped()['generation']
        found, why = stack(client, generation=generation, tid=target.pid)
        assert why == 'PythonRuntimeAmbiguous', (found, why)
        assert str(w/'decoy.so') in {r['path'] for r in modules(client)[0]}  # the probe saw the decoy mapped
        result['ambiguous'] = {'error': why}
        client.close(); client = None
        target.stdin.write('\n'); target.stdin.flush()
        target.wait(timeout=10); assert target.returncode == 0, target.stderr.read()
        result['status'] = 'pass'
    finally:
        if client: result['transcript'] = client.transcript; client.close()
        if target.poll() is None: target.kill(); target.wait()
        for pad in pads: pad.unlink(missing_ok=True)
        (w/'results.json').write_text(json.dumps(result, indent=2)+'\n')
    print(f'Python image budget: stack and tab resolved with {len(pads)} padded images ({sum(sizes) >> 20} MiB mapped, {total >> 20} MiB budget); budget refusal named in the reply and the tab; a second image defining the runtime symbol refused')


if __name__ == '__main__':
    main()
