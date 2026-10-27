#!/usr/bin/env python3
"""Startup capture opens and remains in flames on a private compositor."""
import importlib.util
import os
from pathlib import Path
import tempfile
import time

root = Path(__file__).resolve().parents[1]
os.chdir(root)
spec = importlib.util.spec_from_file_location('input_repro', root / 'tests/helpers/input.py')
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
work = Path(tempfile.mkdtemp(prefix='xpf-', dir=Path.home() / 'tmp'))
work.chmod(0o755)
for name in ('tmp', 'cache', 'cache/mesa', 'cache/nvidia'):
    (work / name).mkdir(parents=True, exist_ok=True)
h.WORK = str(work)
stop = work / 'target.stop'
ready = work / 'target.ready'
display = None


def displayed_graph(profile):
    view = profile['displayed_view']
    if not view or not view['visible'] or not view['view_id']:
        return None
    args = dict(capture_id=view['capture_id'], revision=view['revision'],
                view_id=view['view_id'], start=0, limit=64)
    response = display.request('tools/call', {'name': 'get_flamegraph', 'arguments': args})
    if not response or response.get('isError'):
        return None
    page = response['structuredContent']
    if page.get('pending'):
        return None
    rows = list(page['nodes'])
    while page['next'] is not None:
        args['start'] = page['next']
        response = display.request('tools/call', {'name': 'get_flamegraph', 'arguments': args})
        if not response or response.get('isError'):
            return None
        page = response['structuredContent']
        if page.get('pending'):
            return None
        rows += page['nodes']
    return rows


try:
    display = h.Display(str(root), [
        '--agent-scope', 'control', '--start-profile', '--profile-hz', '997',
        '--profile-duration', '0', '--',
        './zig-out/bin/xodb-profile-start-fixture', str(stop), str(ready),
    ])
    first = display.tool('get_profile')
    assert first['capture'] is not None and first['capture']['status'] == 'collecting', first
    deadline = time.monotonic() + 30 * h.load_scale()
    ready_samples = None
    ready_view_samples = None
    while time.monotonic() < deadline:
        profile = display.tool('get_profile')
        view = profile['displayed_view']
        if ready.exists() and view and view['visible']:
            if ready_samples is None:
                ready_samples = profile['capture']['stored_samples']
                ready_view_samples = view['sample_count']
            if (profile['capture']['stored_samples'] >= ready_samples + 150 and
                    view['sample_count'] > ready_view_samples):
                break
        time.sleep(.03)
    else:
        raise AssertionError(display.tail())
    assert profile['displayed_view']['visible'], profile
    assert profile['capture']['status'] == 'collecting', profile
    constructor_ns = int(ready.read_text())
    assert constructor_ns and first['capture']['started_ns'] < constructor_ns, (first, constructor_ns)

    stop.write_text('stop\n')
    deadline = time.monotonic() + 20 * h.load_scale()
    while True:
        session = display.session()
        profile = display.tool('get_profile')
        if session['state'] == 'exited' and profile['capture']['status'] != 'collecting':
            break
        assert time.monotonic() < deadline, (session, profile, display.tail())
        time.sleep(.03)

    # The final graph remains selected after target exit and still contains the
    # constructor-only function from before main.
    deadline = time.monotonic() + 15 * h.load_scale()
    final_rows = None
    while time.monotonic() < deadline:
        profile = display.tool('get_profile')
        final_rows = displayed_graph(profile)
        if final_rows is not None:
            names = {node['name'] for node in final_rows}
            if {'profile_startup_hot', 'profile_late_hot'} <= names:
                break
        time.sleep(.03)
    assert profile['displayed_view']['visible'], profile
    assert {'profile_startup_hot', 'profile_late_hot'} <= {node['name'] for node in final_rows or ()}
    display.app.stdin.close()
    assert display.app.wait(timeout=10) == 0, display.tail()
    print('PASS: private GUI opens live startup flames and retains the final constructor graph')
finally:
    if display is not None:
        display.close()
