#!/usr/bin/env python3
"""Fast component: every partial-write boundary in the GUI trace readers."""
import argparse
import ast
import importlib.util
import json
import os
from pathlib import Path
import re
import time
from types import SimpleNamespace

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', type=Path, required=True)
p.add_argument('--wrong-result', action='store_true')
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
os.umask(0o022)
w = a.work.resolve()
w.mkdir(parents=True)
log = w/'trace.log'
spec = importlib.util.spec_from_file_location('private_input', root/'tests/helpers/input.py')
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
started = time.monotonic()
checks = 0

# Split UTF-8, CRLF, blank rows, invalid UTF-8 and a Unicode line separator.
# Only the producer's literal LF terminates a record.
records = [b'frame=1\n', 'name=\u00e9\u2028x\r\n'.encode(), b'\n', b'invalid=\xff\n']
data = b''.join(records)
for end in range(len(data)+1):
    log.write_bytes(data[:end])
    expected = []
    at = 0
    for record in records:
        at += len(record)
        if at <= end:
            expected.append(record[:-1].removesuffix(b'\r').decode('utf-8', errors='replace'))
    if a.wrong_result:
        expected.append('unfinished')
    assert h.complete_lines(log) == expected, ('complete records', end, expected)
    checks += 1

# Compile only each real parser function, without launching its script's GUI.
# This exercises the actual consumer at every boundary, not a second parser.
cases = (
    ('gibson-gui.py', 'latest', b'xodb: gibson frame=1 towers=9 unknown=0\n',
     b'xodb: gibson frame=2 towers=17 unknown=3\n'),
    ('scene3d-gui.py', 'latest', b'scene3d frame=1 gpu_ns=null size=1280x720\n',
     b'scene3d frame=2 gpu_ns=123456 size=3840x2160\n'),
    ('memdefrag-modern-gui.py', 'field', b'xodb: memmap deep x=1 y=2 pitch=3 cols=4 count=8\n',
     b'xodb: memmap deep x=5 y=6 pitch=7 cols=8 count=16\n'),
    ('gibson-camera.py', 'rows', b'xodb: gibson frame=1 cx=1 focused=true\n',
     b'xodb: gibson frame=2 cx=-1.25 focused=false\n'),
    ('deepmap-gui.py', 'field', b'xodb: memmap deep x=1 y=2 count=8 pending=0\n',
     b'xodb: memmap deep x=5 y=6 count=16 pending=12\n'),
    ('memdefrag-win95-gui.py', 'layout_rows', b'xodb: overview layout 1280x720 overlaps=0 boxes=12\n',
     b'xodb: overview layout 1920x1080 overlaps=0 boxes=24\n'),
    ('helpers/language_selection.py', 'check_layout',
     b'xodb: language layout tab=python boxes=12 overlaps=0 selected_reason=reader \n',
     b'xodb: language layout tab=python boxes=24 overlaps=0 selected_reason=reader \n'),
)
for file, function, previous, following in cases:
    source = ast.parse((root/'tests'/file).read_text())
    selected = [node for node in source.body if isinstance(node, ast.FunctionDef) and node.name == function]
    assert len(selected) == 1, (file, function)
    display = SimpleNamespace(log=str(log))
    namespace = dict(h=h, Path=Path, re=re, d=display, complete_lines=h.complete_lines,
                     log=lambda: log.read_text())
    exec(compile(ast.Module(body=selected, type_ignores=[]), file, 'exec'), namespace)
    reader = namespace[function]
    def parse():
        if function != 'check_layout':
            return reader()
        # A completed prior row returns immediately; a missing row must reach
        # the existing bounded-wait assertion, without a real 20-second delay.
        ticks = iter((0, 21))
        namespace['time'] = SimpleNamespace(monotonic=lambda: next(ticks))
        return reader(display, 'python', 'reader')
    log.write_bytes(previous)
    expected_previous = parse()
    log.write_bytes(previous+following)
    expected_next = parse()
    assert expected_previous != expected_next, 'fixture must observe the completed next row'
    for end in range(len(following)+1):
        log.write_bytes(previous+following[:end])
        expected = expected_next if end == len(following) else expected_previous
        assert parse() == expected, (file, 'partial prefix', end, expected)
        checks += 1
    # Truncation must not return a stale prior row or an incomplete replacement.
    log.write_bytes(following[:-1])
    if function == 'check_layout':
        try:
            parse()
        except AssertionError as e:
            assert e.args[0][0] == 'language layout condition not observed', e
        else:
            raise AssertionError((file, 'truncated partial record accepted'))
        # Waiting for LF must not suppress an actual completed overlap.
        bad = following.replace(b'overlaps=0', b'overlaps=1')
        log.write_bytes(previous+bad[:-1])
        assert parse() == expected_previous, (file, 'unfinished overlap row')
        log.write_bytes(previous+bad)
        try:
            parse()
        except AssertionError as e:
            assert e.args[0][0] == 'overlapping language text', e
        else:
            raise AssertionError((file, 'completed overlap ignored'))
        checks += 2
    else:
        assert parse() in ({}, [], None), (file, 'truncated partial record')
    checks += 1
result = dict(status='pass', checks=checks, consumers=len(cases), seconds=time.monotonic()-started)
(w/'results.json').write_text(json.dumps(result, indent=2)+'\n')
print(json.dumps(result))
