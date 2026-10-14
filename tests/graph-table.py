#!/usr/bin/env python3
"""Fast private GUI lane: neutral table, bidirectional selection and observer MCP."""
import argparse
import csv
import io
import importlib.util
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--binary')
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = root / '.work' / ('input-table' + str(time.time_ns())[-5:])
work.mkdir(parents=True)
for name in ('tmp', 'cache'):
    (work / name).mkdir()
spec = importlib.util.spec_from_file_location('private_input', root / 'tests/helpers/input.py')
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
h.WORK = str(work)
for xml, stem in ((h.VPTR, 'virtual-pointer'), (h.VKBD, 'virtual-keyboard')):
    subprocess.run(['wayland-scanner', 'client-header', xml, str(work / (stem + '.h'))], check=True)
    subprocess.run(['wayland-scanner', 'private-code', xml, str(work / (stem + '.c'))], check=True)
h.HELPER = str(work / 'vinput')
subprocess.run(['cc', '-I', str(work), 'tests/helpers/vinput.c', str(work / 'virtual-pointer.c'),
                str(work / 'virtual-keyboard.c'), '-lwayland-client', '-lxkbcommon', '-lm', '-o', h.HELPER], check=True)
os.environ['XODB_OVERVIEW_AUDIT'] = '1'
checks = []
d = None
started = time.monotonic()
measurements = {'load': os.getloadavg(), 'cpus': len(os.sched_getaffinity(0))}
def rss():
    return int(Path('/proc', str(d.app.pid), 'stat').read_text().rsplit(')', 1)[1].split()[21]) * os.sysconf('SC_PAGE_SIZE')
def rows(kind):
    return [dict(re.findall(r'(\w+)=([^ ]+)', line)) for line in h.complete_lines(d.log)
            if line.startswith('xodb: ' + kind + ' ')]
def until(fn):
    deadline = time.monotonic() + 10 * h.load_scale()
    while not fn():
        assert d.alive() and time.monotonic() < deadline, d.tail()
        time.sleep(.01)
def check(name, ok):
    assert ok, name + ': ' + d.tail()
    checks.append(name)
    print('PASS ' + name, flush=True)
def click(row):
    d.keys('click', round(float(row['x'])), round(float(row['y'])))
def shared_graph(path):
    with socket.socket(socket.AF_UNIX) as peer:
        peer.settimeout(5)
        peer.connect(str(path))
        with peer.makefile('rb') as stream:
            def request(serial, method, params):
                peer.sendall((json.dumps(dict(jsonrpc='2.0', id=serial, method=method, params=params)) + '\n').encode())
                while True:
                    response = json.loads(stream.readline())
                    if response.get('id') == serial:
                        return response['result']
            request(1, 'initialize', dict(protocolVersion='2025-06-18', capabilities={}, clientInfo=dict(name='graph-observer', version='1')))
            peer.sendall(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
            return request(2, 'tools/call', dict(name='get_graph', arguments=dict(kind='descriptors', scope='current')))['structuredContent']
try:
    d = h.Display.__new__(h.Display)
    h.Display.__init__(d, str(root), ['--overview', '--galaxy-demo', '24:idle', '--session-socket', str(work / 'observer.sock')], trace=False, binary=a.binary)
    until(lambda: rows('galaxy-pick'))
    measurements['galaxy_rss_bytes'] = rss()
    graph = d.tool('get_graph', kind='descriptors', scope='current')
    nodes = [n for n in graph['nodes'] if n['entity'] == 'node']
    ids = {n['id'] for n in graph['nodes']}
    check('observer gets the visible bounded synthetic model', graph['synthetic'] and graph['source'] == 'visible_gui_model' and len(nodes) == 24)
    check('every exported edge resolves to exact model endpoints', graph['edges'] and all(e['source'] in ids and e['target'] in ids for e in graph['edges']))
    peer_graph = shared_graph(work / 'observer.sock')
    check('shared observer sees the identical graph without a control lease', peer_graph == graph)
    star = rows('galaxy-pick')[-1]
    click(star)
    d.keys('tap', 47)  # V table
    until(lambda: rows('graph-table'))
    measurements['table_rss_bytes'] = rss()
    selected = [r for r in rows('graph-table-row') if r['type'] == 'node' and r['selected'] == '1']
    check('star selection becomes that star\'s selected table row', bool(selected) and selected[-1]['id'] == star['anchor'])
    target = next(r for r in reversed(rows('graph-table-row')) if r['type'] == 'node' and r['id'] != selected[-1]['id'])
    click(target)
    until(lambda: any(r['id'] == target['id'] and r['selected'] == '1' for r in rows('graph-table-row')))
    d.keys('tap', 47)
    until(lambda: rows('galaxy-look')[-1]['camera'] == '0' and float(rows('galaxy-look')[-1]['zoom']) > 1)
    check('table selection frames the same star when returning', rows('galaxy-pick')[-1]['node'] == target['id'])
    d.keys('tap', 47)
    until(lambda: rows('graph-table')[-1]['cursor'] != '0')
    unfolded = int(rows('graph-table')[-1]['rows'])
    d.keys('tap', 57)  # Space fold selected cluster
    until(lambda: int(rows('graph-table')[-1]['folded']) > 0)
    check('cluster rows fold without changing the source model', int(rows('graph-table')[-1]['rows']) < unfolded and len(d.tool('get_graph', kind='descriptors')['nodes']) == len(graph['nodes']))
    d.keys('tap', 53)  # / captures text
    d.keys('tap', 16, 'tap', 22, 'tap', 23, 'tap', 20)  # quit
    until(lambda: rows('graph-table')[-1]['filter'] == '4')
    check('typed global hotkeys stay in the table filter', d.alive() and rows('graph-table')[-1]['rows'] == '0')
    d.keys('tap', 1, 'tap', 1)  # finish editing, clear filter
    until(lambda: rows('graph-table')[-1]['filter'] == '0')
    d.keys('tap', 15)  # Tab edge rows
    until(lambda: rows('graph-table')[-1]['edges'] == '1')
    check('table exposes the same complete edge set', int(rows('graph-table')[-1]['rows']) == len(graph['edges']))
    d.keys('tap', 19)  # R reverse
    until(lambda: rows('graph-table')[-1]['reverse'] == '1')
    check('reverse ordering is explicit', True)
    d.keys('down', 29, 'tap', 46, 'up', 29)  # Ctrl+C, private clipboard only
    copied = subprocess.run(['wl-paste', '--no-newline'], env=d.env, capture_output=True, text=True, check=True, timeout=5).stdout
    exported_rows = list(csv.DictReader(io.StringIO(copied), delimiter='\t'))
    measurements['copied_rss_bytes'] = rss()
    check('copied TSV preserves every edge ID and both endpoint IDs',
          {r['id'] for r in exported_rows} == {e['id'] for e in graph['edges']} and
          {(r['source_id'], r['target_id']) for r in exported_rows} == {(e['source'], e['target']) for e in graph['edges']})
    h.ocr_until(d, 'table-edges', lambda text: 'edges' in text and 'source' in text)
finally:
    if d:
        d.close()
    (work / 'results.json').write_text(json.dumps({'checks': checks, 'seconds': time.monotonic() - started, 'measurements': measurements}, indent=2) + '\n')
