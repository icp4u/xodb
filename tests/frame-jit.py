#!/usr/bin/env python3
"""Check host labels against an owned Node capture and its declared jitdump.

frame-jit.py CAPTURE.xoc JITDUMP DECLARATION.json
The declaration records the process incarnation and measured clock scope.
"""
import copy
import hashlib
import json
import os
from pathlib import Path
import struct
import sys
import time
from client import Client

capture, dump, declaration = [Path(x).resolve() for x in sys.argv[1:4]]
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = root / '.work' / ('frame-jit-' + str(time.time_ns()))
work.mkdir(parents=True)
meta = json.loads(declaration.read_text())
raw = dump.read_bytes()
owned = work / 'owned.dump'; owned.write_bytes(raw)
checks = []


def ready(c, archive=False):
    until = time.monotonic() + 30
    while True:
        s = c.inspect('get_archive_status' if archive else 'get_frame_status')
        if s['job']['done'] if archive else s['status'] != 'pending':
            assert (s['job']['error_name'] if archive else s['error_name']) is None, s
            return s
        assert time.monotonic() < until, s
        time.sleep(.003)


def opened():
    c = Client('control', None, options=['--open-capture', str(capture)])
    ready(c, True)
    cap = c.inspect('get_profile')['capture']
    return c, dict(capture_id=cap['id'], revision=cap['revision'])


def prepare(c, key, start=0, limit=1):
    c.inspect('prepare_jit_profile', **key, start=start, limit=limit)
    ready(c)
    return c.inspect('get_jit_profile', **key, start=start, limit=limit)


c, key = opened()
try:
    c.inspect('import_jit_map', path=str(owned), kind='jitdump', declaration=meta); ready(c)
    count = c.inspect('get_profile_samples', **key)['total']
    found = None
    for start in range(0, count, 64):
        labels = prepare(c, key, start, min(64, count-start))
        for s in labels['samples']:
            if s['leaf'] and s['leaf']['outcome'] == 'resolved':
                rows = c.inspect('get_jit_candidates', **key, ordinal=s['ordinal'])['rows']
                if any('hot_mix' in r['candidate']['name'] for r in rows):
                    found = s
                    break
        if found: break
    assert found, 'owned hot_mix did not resolve'
    ordinal = found['ordinal']
    before = c.inspect('get_profile_samples', **key, start=ordinal, limit=1)['samples'][0]
    assert before['sample']['ip'] == found['leaf']['raw_pc']
    stack = c.inspect('get_jit_stack', **key, ordinal=ordinal, limit=64)
    assert len(stack['rows']) <= 64
    checks.append('64-sample summaries, caller pages, candidates and raw PC preservation')

    saved = work / 'jit.xof'
    c.inspect('save_frames', path=str(saved)); ready(c)
    owned.unlink()
    c.inspect('open_frame_bundle', path=str(saved)); ready(c)
    again = prepare(c, key, ordinal)['samples'][0]
    assert again == found, (again, found)
    checks.append('JIT replay after input deletion')

    # Same producer evidence except every code index now names another object.
    changed = bytearray(raw)
    at = struct.unpack_from('<I', changed, 8)[0]
    while at < len(changed):
        kind, size = struct.unpack_from('<II', changed, at)
        assert size >= 16 and at + size <= len(changed)
        if kind == 0:
            index = struct.unpack_from('<Q', changed, at + 48)[0]
            struct.pack_into('<Q', changed, at + 48, index + 1000000)
        at += size
    conflict = work / 'conflicting.dump'; conflict.write_bytes(changed)
    c.inspect('import_jit_map', path=str(conflict), kind='jitdump', declaration=meta); ready(c)
    ambiguous = prepare(c, key, ordinal)['samples'][0]
    assert ambiguous['leaf']['outcome'] == 'ambiguous', ambiguous
    candidates = c.inspect('get_jit_candidates', **key, ordinal=ordinal)
    assert candidates['total'] >= 2, candidates
    checks.append('conflicting code objects remain ambiguous with separate citations')
    # Save the ambiguity for GUI and replay checks.
    c.inspect('save_frames', path=str(work / 'ambiguous.xof')); ready(c)
    assert c.inspect('get_profile_samples', **key, start=ordinal, limit=1)['samples'][0]['sample'] == before['sample']
finally:
    (work / 'rpc.json').write_text(json.dumps(c.transcript, indent=2)); c.close()

owned.write_bytes(raw)
for case in ('missing-clock', 'missing-incarnation', 'wrong-incarnation', 'perfmap', 'unverified-read'):
    c, key = opened()
    try:
        m = copy.deepcopy(meta)
        path, kind = owned, 'jitdump'
        if case == 'missing-clock': m['clock'] = {'kind': 'unknown'}
        if case == 'missing-incarnation': m.pop('start_ticks'); m.pop('boot_id')
        if case == 'wrong-incarnation': m['start_ticks'] += 1
        if case == 'perfmap':
            path, kind = work / 'owned.map', 'perfmap'
            path.write_text(f"{found['leaf']['raw_pc']:x} 1 owned_perfmap_label\n")
        if case == 'unverified-read':
            b = bytearray((work / 'jit.xof').read_bytes())
            struct.pack_into('<I', b, 88 + 4, 2)
            b[24:88] = hashlib.sha256(b[88:]).hexdigest().encode()
            path = work / 'unverified.xof'; path.write_bytes(b)
            c.inspect('open_frame_bundle', path=str(path)); ready(c)
        else:
            c.inspect('import_jit_map', path=str(path), kind=kind, declaration=m); ready(c)
        result = prepare(c, key, ordinal)['samples'][0]['leaf']
        assert result['outcome'] != 'resolved', (case, result)
        if case == 'unverified-read':
            assert result['outcome'] == 'unverified' and result['resolver_outcome'] == 'resolved', result
        if case == 'perfmap': assert result['outcome'] == 'unverified', result
        if case == 'wrong-incarnation': assert result['total_candidates'] == 0, result
        checks.append(case)
    finally:
        (work / (case + '.json')).write_text(json.dumps(c.transcript, indent=2)); c.close()
(work / 'results.json').write_text(json.dumps({'checks': checks, 'ordinal': ordinal, 'resolved': found, 'ambiguous': ambiguous}, indent=2))
print('Host JIT labels:', len(checks), 'checks passed;', work.relative_to(root))
