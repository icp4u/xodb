#!/usr/bin/env python3
"""Reviewed JVM fixture bytes through session import, typed pages and replay."""
import json
import os
from pathlib import Path
import re
import time
from client import Client

root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = root / '.work' / ('frame-jvm-' + str(time.time_ns()))
work.mkdir(parents=True)
fixtures = (root / 'tests/jvm/test_evidence.c').read_text()


def fixture(name):
    # Reuse the component's literal fixtures, not another importer or oracle.
    body = re.search(r'static const char ' + name + r'\[\] =\s*(.*?);', fixtures, re.S).group(1)
    return ''.join(json.loads(token) for token in re.findall(r'"(?:[^"\\]|\\.)*"', body)).encode()


def ready(c):
    until = time.monotonic() + 20
    while True:
        s = c.inspect('get_frame_status')
        if s['status'] != 'pending':
            assert s['error_name'] is None, s
            return s
        assert time.monotonic() < until, s
        time.sleep(.003)


c = Client('control', None)
try:
    for index, (name, kind) in enumerate((('jfr', 'jfr'), ('probes', 'coroutines'), ('print', 'thread_print'))):
        raw = fixture(name)
        path = work / (name + '.input'); path.write_bytes(raw)
        c.inspect('import_logical_frames', path=str(path), kind=kind)
        s = ready(c)['sources'][index]
        key = dict(source=index, source_id=s['source_id'])
        frames = c.inspect('get_frame_stack', **key, stack=0)['rows']
        threads = c.inspect('get_frame_threads', **key)['rows']
        stacks = c.inspect('get_frame_stacks', **key)['rows']
        assert frames and threads and stacks and all(r['jvm'] for r in frames)
        assert all(not r['jvm']['native_authority'] for r in frames)
        if kind == 'jfr':
            assert any(r['jvm']['inlined'] for r in frames)
            assert any(r['jvm']['jvm_native_method'] for r in frames)
            assert any(r['jvm']['is_virtual'] == 1 for r in threads), threads
        elif kind == 'coroutines':
            assert any(r['jvm']['parent_doc_thread'] != 4294967295 for r in threads), threads
        else:
            assert any(r['jvm']['heuristic_text'] for r in frames)
        cited = stacks[0]['jvm']
        cite = c.inspect('get_frame_citation', **key, basis='source', offset=cited['source_offset'], length=min(4096, cited['source_length']))
        assert bytes.fromhex(cite['bytes']) == raw[cited['source_offset']:cited['source_offset'] + cite['length']]
        path.unlink()
        assert c.inspect('get_frame_stack', **key, stack=0)['rows'] == frames
    ids = [s['source_id'] for s in ready(c)['sources']]
    saved = work / 'jvm.xof'
    c.inspect('save_frames', path=str(saved)); ready(c)
    c.inspect('open_frame_bundle', path=str(saved))
    assert [s['source_id'] for s in ready(c)['sources']] == ids
finally:
    (work / 'rpc.json').write_text(json.dumps(c.transcript, indent=2)); c.close()
print('JVM host: JFR inline/native methods, virtual threads, coroutine parents, text provenance and retained source citations:', work.relative_to(root))
