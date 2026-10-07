#!/usr/bin/env python3
"""Owned logical evidence through the host: identities, exact counts and replay."""
import copy
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import time
from client import Client

root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = root / '.work' / ('frame-host-' + str(time.time_ns()))
work.mkdir(parents=True)


def ready(client, error=None):
    until = time.monotonic() + 20
    while True:
        status = client.inspect('get_frame_status')
        if status['status'] != 'pending':
            assert status['error_name'] == error, status
            return status
        assert time.monotonic() < until, status
        time.sleep(.002)


def denied(client, name, error, **args):
    r = client.tool(name, **args)
    if 'error' in r:
        assert error == 'InvalidArguments' and r['error']['code'] == -32602, r
        return
    assert r['result']['isError'], r
    assert r['result']['content'][0]['text'] == error, r


def write(name, records, tail=b''):
    p = work / name
    p.write_bytes(b''.join((json.dumps(r, separators=(',', ':')) + '\n').encode() for r in records) + tail)
    return p


def bundle(raw, metadata, stability=1):
    meta = json.dumps(metadata, separators=(',', ':')).encode()
    body = struct.pack('<IIIIQ', 1, stability, len(meta), 0, len(raw)) + hashlib.sha256(raw).hexdigest().encode() + meta + raw
    return b'XODBFRAM' + struct.pack('<IIQ', 1, 1, len(body)) + hashlib.sha256(body).hexdigest().encode() + body


# A real cooperating runtime export exercises the advertised workflow.
subprocess.run(['python3', 'tests/logical-frames/python_workload.py', str(work / 'python.jsonl'),
                str(work / 'python-meta.json'), '.25', '10'], check=True, timeout=30)
c = Client('control', None, options=['--open-frames', str(work / 'python.jsonl')])
try:
    s = ready(c)['sources'][0]
    assert s['language'] == 'python' and s['method'] and s['functions'] > 0, s
    fs = c.inspect('get_frame_functions', source_id=s['source_id'])['rows']
    assert any(f['code'] and f['code']['path'] and f['function']['first_line'] > 0 for f in fs), fs
    for tool in ('get_frame_threads', 'get_frame_stacks', 'get_frame_aggregate'):
        assert c.inspect(tool, source_id=s['source_id'])['rows']
finally:
    c.close()

# Derive synthetic cases from an owned producer header, with explicit identity.
header = json.loads((work / 'python.jsonl').read_text().splitlines()[0])
header['process'] = {'pid': 42, 'start_ticks': '123', 'boot_id': 'aaaaaaaa-0000-4000-8000-000000000001'}
header['collection']['method'] = 'synthetic_fixture'
header['clock'] = {'domain': 'CLOCK_MONOTONIC', 'unit': 'ns'}
records = [header,
    {'type': 'code', 'id': 'c1', 'kind': 'source_file', 'path': 'owned.py', 'sha256': 'a' * 64, 'bytes': 10},
    {'type': 'function', 'id': 'f1', 'name': 'hot', 'qualified': 'hot', 'code': 'c1', 'first_line': 1, 'frame_kind': 'interpreter'},
    {'type': 'thread', 'id': 't1', 'language_id': 'ident:1', 'name': 'worker', 'os_tid': 100, 'os_tid_source': 'native_id'},
    {'type': 'acquisition', 'seq': 1, 'start_ns': '100', 'end_ns': '200', 'stacks': 2}]
for i in range(2):
    records.append({'type': 'stack', 'id': 's' + str(i), 'acquisition': 1, 'thread': 't1', 'start_ns': '110', 'end_ns': '120',
        'trigger': 'timer', 'weight': str((1 << 64) - 1), 'state': 'partial' if i else 'complete',
        'omitted': None, 'reason': 'owned partial walk' if i else None,
        'frames': [{'function': 'f1', 'kind': 'interpreter', 'line': 2, 'provenance': 'runtime'}]})
records.append({'type': 'end', 'records': len(records), 'acquisitions': 1, 'stacks': 2, 'status': 'complete'})
path = write('exact.jsonl', records)
c = Client('control', None, options=['--open-frames', str(path)])
try:
    tools = {t['name']: t for t in c.call('tools/list')['result']['tools']}
    for name in ('import_logical_frames', 'import_jit_map', 'prepare_jit_profile', 'save_frames'):
        assert tools[name]['annotations']['xodbSessionAccess'] == 'controller'
    status = ready(c)
    s = status['sources'][0]
    sid = s['source_id']
    assert s['total_weight'] == str(2 * ((1 << 64) - 1)), s
    agg = c.inspect('get_frame_aggregate', source_id=sid)
    assert agg['rows'][0]['inclusive'] == s['total_weight'], agg
    assert agg['summary']['partial_weight'] == str((1 << 64) - 1), agg
    denied(c, 'get_frame_functions', 'StaleFrameSource', source_id='0' * 64)
    denied(c, 'get_frame_functions', 'InvalidArguments', source_id=sid, limit=65)
    citation = c.inspect('get_frame_citation', source_id=sid, basis='source', offset=0, length=256)
    assert bytes.fromhex(citation['bytes']) == path.read_bytes()[:256]
    c.inspect('select_frame_aggregate', source_id=sid, thread=0)
    ready(c)
    saved = work / 'saved.xof'
    c.inspect('save_frames', path=str(saved))
    assert ready(c)['publication']['state'] == 'published'
    path.unlink()
    c.inspect('open_frame_bundle', path=str(saved))
    restored = ready(c)['sources'][0]
    assert restored['source_id'] == sid and restored['selected_thread'] == 0
    assert c.inspect('get_frame_aggregate', source_id=sid)['rows'] == agg['rows']
    assert c.inspect('get_frame_citation', source_id=sid, basis='source', offset=0, length=256) == citation

    old = work / 'old.xof'
    raw = write('retained.jsonl', records).read_bytes()
    old.write_bytes(bundle(raw, {'algorithm': 'historical-v0'}))
    c.inspect('open_frame_bundle', path=str(old))
    stale = ready(c)['sources'][0]
    assert stale['aggregate_stale'] and stale['source_id'] == sid, stale
    denied(c, 'get_frame_aggregate', 'FrameAggregateStale', source_id=sid)
    assert c.inspect('get_frame_functions', source_id=sid)['rows']
    c.inspect('select_frame_aggregate', source_id=sid)
    assert not ready(c)['sources'][0]['aggregate_stale']

    malformed = write('malformed.jsonl', [{'not': 'a header'}])
    c.inspect('import_logical_frames', path=str(malformed), kind='logical', replace=0)
    assert ready(c, 'FrameSchemaInvalid')['sources'][0]['source_id'] == sid
    truncated = write('truncated.jsonl', records[:-1], b'{"type":')
    c.inspect('import_logical_frames', path=str(truncated), kind='logical', replace=0)
    assert ready(c)['sources'][0]['input_incomplete']
    wrong = copy.deepcopy(records)
    wrong[3]['pid'] = 43
    c.inspect('import_logical_frames', path=str(write('mismatch.jsonl', wrong)), kind='logical', replace=0)
    ready(c, 'FrameInvalidIdentity')
    clockless = copy.deepcopy(records)
    clockless[0].update(clock=None, clock_unavailable='owned missing-clock case')
    c.inspect('import_logical_frames', path=str(write('clockless.jsonl', clockless)), kind='logical', replace=0)
    ready(c, 'FrameInvalidClock')
    native = copy.deepcopy(records)
    native[2].update(code=None, first_line=None, frame_kind='native')
    for row in native:
        if row['type'] == 'stack':
            row['frames'][0].update(kind='native', line=None, pc='0xffffffffffffffff')
    c.inspect('import_logical_frames', path=str(write('high-pc.jsonl', native)), kind='logical', replace=0)
    high = ready(c)['sources'][0]
    row = c.inspect('get_frame_stack', source_id=high['source_id'], stack=0)['rows'][0]
    assert row['frame']['pc'] == (1 << 64) - 1 and row['native_authority'] is False, row
    fifo = work / 'fifo'; os.mkfifo(fifo)
    c.inspect('import_logical_frames', path=str(fifo), kind='logical', replace=0)
    ready(c, 'FrameReadFailed')
    # The old successfully published source survives every failed replacement.
    assert c.inspect('get_frame_status')['source_count'] == 1
    large = work / 'oversize'
    with large.open('wb') as f: f.truncate(64 * 1024 * 1024 + 1)
    c.inspect('import_logical_frames', path=str(large), kind='logical', replace=0)
    ready(c, 'FrameInputLimit')
    for _ in range(7):
        c.inspect('import_logical_frames', path=str(work / 'retained.jsonl'), kind='logical')
        ready(c)
    assert c.inspect('get_frame_status')['source_count'] == 8
    denied(c, 'import_logical_frames', 'FrameSourceLimit', path=str(work / 'retained.jsonl'), kind='logical')
finally:
    (work / 'transcript.json').write_text(json.dumps(c.transcript, indent=2))
    c.close()

c = Client('observe', None, options=['--open-frames', str(work / 'saved.xof')])
try:
    sid = ready(c)['sources'][0]['source_id']
    assert c.inspect('get_frame_functions', source_id=sid)['rows']
    for tool, args in [('import_logical_frames', {'path': 'unused', 'kind': 'logical'}),
                       ('select_frame_aggregate', {'source_id': sid}), ('save_frames', {'path': 'unused'}),
                       ('cancel_frame_job', {}), ('import_jit_map', {})]:
        denied(c, tool, 'AgentScopeDenied', **args)
    tools = {t['name']: t for t in c.call('tools/list')['result']['tools']}
    for name in ('get_frame_status', 'get_frame_stack', 'get_jit_stack', 'get_jit_candidates'):
        assert tools[name]['annotations']['xodbSessionAccess'] == 'observer'
    for name in ('import_logical_frames', 'import_jit_map', 'prepare_jit_profile', 'save_frames'):
        assert name not in tools, name
finally:
    c.close()
print('Frame host: real Python source locations, exact 128-bit weights, replay, stale analysis, typed failures, limits and permissions:', work.relative_to(root))
