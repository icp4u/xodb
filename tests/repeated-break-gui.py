#!/usr/bin/env python3
"""Private GUI startup and SSH argv forwarding, using an owned local SSH stub."""
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import time

root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = root / '.work' / ('input-repeat-' + str(time.time_ns())[-10:])
work.mkdir(parents=True)
for name in ('tmp', 'cache', 'bin'):
    (work / name).mkdir()
spec = importlib.util.spec_from_file_location('private_input', root / 'tests/helpers/input.py')
h = importlib.util.module_from_spec(spec); spec.loader.exec_module(h)
h.WORK = str(work)
binary = root / 'zig-out/bin/xodb'
fixture = root / 'zig-out/bin/xodb-m1-fixture'
args = ['--break', 'main', '--break', 'change_value', '--break', 'main']
d = h.Display(str(root), ['--agent-scope', 'control', *args, '--', str(fixture)])
checks = []
try:
    definitions = d.tool('get_breakpoints')['definitions']
    assert [p['symbol'] for p in definitions] == ['main', 'change_value'], definitions
    for expected in ('main', 'change_value', 'change_value'):
        d.tool('continue', generation=d.session()['generation'])
        state = d.stopped('breakpoint'); assert state
        frames = d.tool('get_stack', tid=state['pid'])['frames']
        assert frames[0]['symbol'] == expected, frames
    checks.append('GUI installs both breakpoints, deduplicates main, and hits all stops')

    # The stub records the actual SSH command and relays the real GUI protocol
    # to a local owned server. No network, user SSH config, or remote host.
    stub = work / 'bin/ssh'
    stub.write_text('''#!/usr/bin/env python3
import json, os, subprocess, sys, threading
from pathlib import Path
out = Path(os.environ['XODB_TEST_SSH_RECORD'])
(out/'argv.json').write_text(json.dumps(sys.argv))
p = subprocess.Popen(['sh', '-c', sys.argv[-1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
def feed():
    try:
        while data := os.read(0, 65536):
            p.stdin.write(data); p.stdin.flush()
    except BrokenPipeError: pass
    finally: p.stdin.close()
t = threading.Thread(target=feed, daemon=True); t.start()
with (out/'responses.jsonl').open('wb') as log:
    while line := p.stdout.readline():
        log.write(line); log.flush(); sys.stdout.buffer.write(line); sys.stdout.buffer.flush()
sys.exit(p.wait(timeout=5))
''')
    stub.chmod(0o755)
    env = dict(d.env, PATH=str(work / 'bin') + os.pathsep + os.environ['PATH'], XODB_TEST_SSH_RECORD=str(work))
    with (work / 'ssh-gui.log').open('wb') as log:
        app = subprocess.Popen([str(binary), '--ssh', 'owned-fixture', '--remote-xodb', str(binary),
                                '--frames', '60', *args, '--', str(fixture)], env=env, stdout=log, stderr=log)
        d.procs.append(app)
        assert app.wait(timeout=25) == 0, (work / 'ssh-gui.log').read_text()
    forwarded = shlex.split(json.loads((work / 'argv.json').read_text())[-1])
    assert [forwarded[i + 1] for i, arg in enumerate(forwarded) if arg == '--break'] == ['main', 'change_value', 'main'], forwarded
    replies = [json.loads(line) for line in (work / 'responses.jsonl').read_text().splitlines()]
    views = [r['result']['structuredContent'] for r in replies if 'structuredContent' in r.get('result', {}) and 'breakpoints' in r['result']['structuredContent']]
    expected_lines = {i for i, line in enumerate((root / 'tests/fixtures/m1.c').read_text().splitlines(), 1) if 'void change_value(' in line or 'int main(' in line}
    # The physical GUI list also contains the hidden loader rendezvous.
    assert any({p['source']['line'] for p in v['breakpoints'] if p.get('source') and p['source']['path'].endswith('/m1.c')} == expected_lines for v in views), expected_lines
    checks.append('SSH forwards every option in order; remote GUI receives two installed breakpoints')
finally:
    d.close()
(work / 'results.json').write_text(json.dumps(checks, indent=2))
print('Repeated --break private GUI:', len(checks), 'checks passed;', work)
