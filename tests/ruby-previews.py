#!/usr/bin/env python3
"""Live Ruby Symbol/Hash/Array previews match the owned runtime's own values."""
import argparse
import json
import os
from pathlib import Path
import queue
import re
import subprocess
import threading
from client import Client
from helpers.readonly import audit

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--ruby', required=True)
p.add_argument('--work', required=True, type=Path)
p.add_argument('--agent', type=Path)
p.add_argument('--strace', action='store_true')
a = p.parse_args()
root = Path(__file__).resolve().parents[1]; os.chdir(root); os.umask(0o022)
w = a.work.resolve(); w.mkdir(parents=True, mode=0o755)
os.environ['XDG_CACHE_HOME'] = str(w/'cache')
headers = json.loads(subprocess.check_output([a.ruby, '-rjson', '-rrbconfig', '-e',
    'puts JSON.generate(RbConfig::CONFIG.values_at("rubyhdrdir","rubyarchhdrdir"))'], text=True, timeout=30))
addon = w/'xodb_probe.so'
subprocess.run(['cc', '-g', '-O0', '-fno-omit-frame-pointer', '-fPIC', '-shared',
    *['-I'+h for h in headers], 'tests/fixtures/ruby/probe.c', '-o', str(addon)], check=True, timeout=60)
target = subprocess.Popen([a.ruby, 'tests/fixtures/ruby/previews.rb'], env=dict(os.environ, XODB_RUBY_PROBE=str(addon)),
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
lines = queue.Queue()
def drain():
    for line in target.stdout: lines.put(line)
thread = threading.Thread(target=drain, daemon=True); thread.start()
client = None; result = dict(status='running', stops=[], resources=[])

def usage(pid):
    stat = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
    rss = int(re.search(r'^VmRSS:\s*(\d+)', Path(f'/proc/{pid}/status').read_text(), re.M)[1])
    return dict(cpu_seconds=(int(stat[11])+int(stat[12]))/os.sysconf('SC_CLK_TCK'), rss_kib=rss)

def check(value, wanted):
    if 'diagnostic' in wanted:
        assert value['diagnostic'] == wanted['diagnostic'] and not value['children'], value
        return
    assert value['diagnostic'] is None and value['truncated'] == wanted.get('truncated', False), value
    for key in ('type', 'count', 'display'): assert value[key] == wanted[key], (value, wanted)
    assert [{k:row[k] for k in ('key','display')} for row in value['children']] == wanted['children'], (value,wanted)
    assert all(row['diagnostic'] is None and row['advisory'] for row in value['children']), value

try:
    assert lines.get(timeout=15) == 'ready\n'
    options = ['--attach', str(target.pid), *(['--runtime-agent', str(a.agent.resolve())] if a.agent else [])]
    client = Client('control', None, options=options)
    client.action('set_breakpoint', symbol='xodb_ruby_stop'); client.continue_initial_stop()
    target.stdin.write('go\n'); target.stdin.flush()
    prior = None
    for label in ('symbol', 'mapping', 'items', 'unicode', 'cycle_hash', 'cycle_array', 'subclass', 'compacted'):
        state = client.stopped('breakpoint', seconds=30); generation = state['generation']
        ground = json.loads(lines.get(timeout=15)); assert ground['label'] == label, ground
        stack = client.inspect('get_language_stack', tid=target.pid, language='ruby')
        si, fi = next((si,fi) for si,part in enumerate(stack['segments']) for fi,row in enumerate(part['frames']) if row['name']=='preview_values')
        args = dict(generation=generation, tid=target.pid, language='ruby', segment=si, frame=fi)
        measured = dict(frontend=client.p.pid)
        if a.agent: measured['agent'] = client.collector_pid()
        before = {k:usage(pid) for k,pid in measured.items()}
        registers = client.inspect('get_registers', tid=target.pid)
        data = client.inspect('get_language_locals', **args)
        assert data['diagnostic'] is None, data
        rows = {row['name']:row for row in reversed(data['rows']) if not row['hidden']}
        for name,wanted in ground['expected'].items():
            check(rows[name]['value'], wanted)
            evaluated = client.inspect('evaluate_language_expression', expression=name, **args)
            assert evaluated['diagnostic'] is None and len(evaluated['rows']) == 1, evaluated
            check(evaluated['rows'][0]['value'], wanted)
        leaf = client.inspect('evaluate_language_expression', expression='mapping[:state]', **args)
        check(leaf['rows'][0]['value'], ground['expected']['symbol'])
        native = client.inspect('list_locals', tid=target.pid, frame=0)
        value = next(row['value']['visualization']['ruby']['value'] for row in native['locals'] if row['name']=='value')
        check(value, ground['expected'][ground['native']])
        if a.strace and label == 'symbol':
            def observe():
                client.inspect('get_language_locals', **args)
                client.inspect('evaluate_language_expression', expression='mapping[:state]', **args)
                client.inspect('list_locals', tid=target.pid, frame=0)
            result['readonly'] = audit(client, target.pid, w/'readonly.strace', observe)
        if prior:
            stale = client.tool('evaluate_language_expression', expression='symbol', **prior)['result']
            assert stale.get('isError') and stale['content'][0]['text']=='StaleSnapshot', stale
        assert client.inspect('get_registers',tid=target.pid)==registers and client.session()['generation']==generation
        prior = args
        result['stops'].append(dict(ground=ground, locals=data, native=value))
        result['resources'].append(dict(phase=label, before=before, after={k:usage(pid) for k,pid in measured.items()}, load=os.getloadavg()))
        client.action('continue')
    target.wait(timeout=15); assert target.returncode == 0, target.stderr.read()
    result['status'] = 'pass'
    result['measurement_scope'] = 'stopped preview requests after runtime metadata ready; not isolated reader overhead'
    result['measurement_status'] = 'not-measurable' if any(max(r['load'])>len(os.sched_getaffinity(0)) for r in result['resources']) else 'measured'
finally:
    if client: result['transcript']=client.transcript; client.close()
    if target.poll() is None: target.kill()
    target.wait(timeout=10); thread.join(timeout=2)
    result['target_stderr']=target.stderr.read()
    (w/'results.json').write_text(json.dumps(result,indent=2)+'\n')
print('Ruby previews: native VALUEs, named locals, Symbol path leaf, replacements, GC, stale generation and read-only invariants passed')
