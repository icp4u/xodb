#!/usr/bin/env python3
"""Fast component lane: sparse 768 MiB of owned DSOs; exact symbol and code oracle.

RSS/CPU are evidence. The ordinary path must not report a whole-image budget
failure during a name-only scan. --baseline records the old behavior as well.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time
from client import Client

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', type=Path, default=Path('.work/module-symbols'))
p.add_argument('--binary', type=Path, default=Path('zig-out/bin/xodb'))
p.add_argument('--baseline', action='store_true')
p.add_argument('--wrong-result', action='store_true', help='plant an incorrect function-address oracle')
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
w = a.work.resolve()
w.mkdir(parents=True, exist_ok=True)
started = time.monotonic()
for i in range(12):
    source = w / f'library{i}.c'
    source.write_text(f'__attribute__((noinline)) int module_marker_{i}(void) {{ return {1000+i}; }}\n')
    library = w / f'lib{i:02}.so'
    subprocess.run(['cc', '-shared', '-fPIC', '-g', '-O0', str(source), '-o', str(library)], check=True, timeout=30)
    with library.open('r+b') as f:
        f.truncate(64 * 1024 * 1024)
fixture = w / 'fixture'
subprocess.run(['cc', '-g', '-O0', '-Itests', 'tests/fixtures/module-symbols.c', '-ldl', '-o', str(fixture)], check=True, timeout=30)
os.environ['XODB_BIN'] = str(a.binary.resolve())


def usage(pid):
    fields = Path(f'/proc/{pid}/stat').read_text().rsplit(') ', 1)[1].split()
    return dict(cpu_seconds=(int(fields[11])+int(fields[12]))/os.sysconf('SC_CLK_TCK'),
                rss_bytes=int(Path(f'/proc/{pid}/statm').read_text().split()[1])*os.sysconf('SC_PAGESIZE'))


def action(client, name, **arguments):
    deadline = time.monotonic()+15
    while True:
        reply = client.tool(name, generation=client.session()['generation'], **arguments)
        result = reply.get('result', {})
        if result.get('isError') and result.get('content') == [{'type':'text','text':'StaleSnapshot'}]:
            assert time.monotonic()<deadline, reply
            continue
        assert 'error' not in reply and not result.get('isError'), reply
        return result['structuredContent']


c = Client('control', str(fixture), args=[str(w), str(w/'oracle')])
report = dict(status='running', baseline=a.baseline)
try:
    c.stopped()
    action(c, 'set_breakpoint', symbol='modules_stop')
    c.continue_initial_stop()
    state = c.stopped('breakpoint')
    expected = {name:int(address,16) for name,address in (line.split() for line in (w/'oracle').read_text().splitlines())}
    if a.wrong_result:
        expected['module_marker_0'] += 1
    before = usage(c.p.pid)
    # The first dlopen is normally the last DSO in ascending VMA order.
    # Ask for every symbol, so placement ordering cannot hide a full scan.
    requested = {}
    for i in range(12):
        ident = action(c, 'set_breakpoint', symbol=f'module_marker_{i}')['id']
        requested[f'module_marker_{i}'] = ident
        deadline = time.monotonic()+15
        while True:
            rows = c.inspect('get_breakpoints')['breakpoints']
            if not next(row for row in rows if row['id']==ident)['pending']:
                break
            assert time.monotonic()<deadline, rows
            time.sleep(.002)
    after = usage(c.p.pid)
    state = c.session()
    report['session'] = state
    breakpoints = c.inspect('get_breakpoints')['breakpoints']
    for name, ident in requested.items():
        actual = next(row for row in breakpoints if row['id'] == ident)
        assert not actual['pending'] and actual['address'] == expected[name], (name,actual,expected[name])
    rows = []
    cursor = None
    failures = []
    while True:
        page = c.inspect('list_modules', **({'cursor':cursor} if cursor else {}))
        rows.extend(page['regions'])
        failures.extend(page['load_failures'])
        cursor = page['next']
        if cursor is None:
            break
    if not a.baseline:
        assert not any(x['diagnostic']=='BinarySnapshotLimit' for x in failures), failures
    action(c, 'continue')
    stopped = c.stopped('breakpoint')
    # The fixture executes marker zero first, independently of lookup order.
    report.update(before=before, after=after, expected=expected,
                  stopped=stopped, failures=failures, load=os.getloadavg())
    registers = c.inspect('get_registers', tid=stopped['pid'])
    report['registers'] = registers
    values = registers['registers']
    pc_name = next(key for key in ('rip','pc','nip','csr_era') if key in values)
    assert int(values[pc_name],16) == expected['module_marker_0'], registers
    report['status'] = 'pass'
finally:
    c.close()
    report['diagnostics'] = c.p.stderr.read().decode(errors='replace')
    report['elapsed_seconds'] = time.monotonic()-started
    (w/'results.json').write_text(json.dumps(report, indent=2)+'\n')
assert ('BinarySnapshotLimit' in report['diagnostics']) == a.baseline, report['diagnostics']
print(json.dumps({key:report[key] for key in ('status','baseline','before','after','elapsed_seconds')}))
