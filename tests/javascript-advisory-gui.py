#!/usr/bin/env python3
"""Extent advisories and truncation stay visible on a private display."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import select
import subprocess
import time

root = Path(__file__).resolve().parent.parent
os.chdir(root)
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--node', required=True)
p.add_argument('--include', default='/usr/include/node')
p.add_argument('--work', required=True, type=Path)
args = p.parse_args()
os.umask(0o022)
work = (args.work/'.work/input-js-advisory').resolve()
work.mkdir(parents=True, mode=0o755)
spec = importlib.util.spec_from_file_location('private_input', root/'tests/helpers/input.py')
h = importlib.util.module_from_spec(spec); spec.loader.exec_module(h)
h.WORK = str(work)
for name in ('tmp', 'cache/mesa', 'cache/nvidia'):
    (work/name).mkdir(parents=True, exist_ok=True)
for xml, stem in ((h.VPTR, 'virtual-pointer'), (h.VKBD, 'virtual-keyboard')):
    subprocess.run(['wayland-scanner', 'client-header', xml, str(work/(stem+'.h'))], check=True, timeout=10)
    subprocess.run(['wayland-scanner', 'private-code', xml, str(work/(stem+'.c'))], check=True, timeout=10)
h.HELPER = str(work/'vinput')
subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-I', str(work), 'tests/helpers/vinput.c',
                str(work/'virtual-pointer.c'), str(work/'virtual-keyboard.c'),
                '-lwayland-client', '-lxkbcommon', '-lm', '-o', h.HELPER], check=True, timeout=60)
addon = work/'probe.node'
subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++20', '-g', '-O0', '-fno-omit-frame-pointer',
                '-fPIC', '-shared', '-I'+args.include, '-DNODE_GYP_MODULE_NAME=xodb_probe',
                'examples/node-probe.cc', '-o', str(addon)], check=True, timeout=90)
fixture = work/'advisory.js'
fixture.write_text('''const addon = require(process.env.XODB_NODE_PROBE);
const large = Buffer.from('λ'.repeat(1000000)).toString();
process.stdout.write('ready\\n');
process.stdin.once('data', () => {
  addon.probe(large);
  addon.probe([large, 42]);
  addon.probe(42);
  process.exit(0);
});
''')
target = subprocess.Popen([args.node, str(fixture)], env=dict(os.environ, XODB_NODE_PROBE=str(addon)),
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
d = None
results = []
try:
    assert select.select([target.stdout], [], [], 10)[0] and target.stdout.readline() == b'ready\n'
    d = h.Display(str(root), ['--agent-scope', 'control', '--attach', str(target.pid)])
    d.tool('set_breakpoint', generation=d.session()['generation'], symbol='xodb_node_stop')
    d.tool('continue', generation=d.session()['generation'])
    target.stdin.write(b'go\n'); target.stdin.flush()
    for case in ('string', 'array', 'smi'):
        assert d.stopped('breakpoint')
        deadline = time.monotonic() + 30
        pending = []
        while True:
            value = d.tool('evaluate_expression', tid=target.pid, frame=0, expression='value')['value']
            if value['visualization'] is not None:
                break
            pending.append(value)
            (work/('pending-'+case+'.json')).write_text(json.dumps(pending, indent=2)+'\n')
            assert value['diagnostic'] == 'DebugMetadataPending' and time.monotonic() < deadline, value
            time.sleep(.02)
        preview = value['visualization']
        assert preview['extent_advisory'] == (case != 'smi'), value
        if case == 'array':
            child = preview['javascript']['items'][0]
            assert child['truncated'] and child['extent_advisory'] and child['display'].endswith('...'), child
            assert child['diagnostic'] == 'JavaScriptStringExtentUnproved', child
        if case == 'string':
            d.keys('tap', 18, 'tap', 47, 'tap', 30, 'tap', 38, 'tap', 22, 'tap', 18, 'tap', 28)
        # A previous value (or its stale running frame) must not satisfy the
        # next case merely because its advisory text is still on screen.
        def presented(text):
            return ('continue' in text and 'breakpoint' in text and 'stale:' not in text and
                    {'string': 'string', 'array': 'array(2)', 'smi': 'smi 42'}[case] in text and
                    ('extent unproved' in text) == (case != 'smi'))
        visible = h.ocr_until(d, 'advisory-'+case, presented)
        assert presented(visible), visible
        results.append(dict(case=case, value=value, visible=visible))
        if case != 'smi':
            d.tool('continue', generation=d.session()['generation'])
    (work/'results.json').write_text(json.dumps(results, indent=2)+'\n')
finally:
    if d: d.close()
    if target.poll() is None: target.kill()
    target.wait(timeout=5)
    (work/'target-stderr.txt').write_bytes(target.stderr.read())
print('JavaScript extent advisory: string/container dim label, item truncation and clean next stop passed')
