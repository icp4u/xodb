#!/usr/bin/env python3
"""A follow session must not steal the sidecar starter's exit status.

The starter exits 4 only after the debuggee exists, so following is already
armed. XODB_TEST_REAP_BEFORE_HELPER_WAIT runs the orphan reap once that
starter is a zombie, before its wait. Exit 4 must still arrive as
SidecarNotConfigured.
"""
import os
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
os.environ.pop('XODB_RUNTIME_AGENT', None)

from client import Client

ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)
work = Path(sys.argv[sys.argv.index('--work') + 1]).resolve()
run = work / 'run'
run.mkdir(parents=True, exist_ok=True)
(work / 'ghidra-home').mkdir(exist_ok=True)

starter = work / 'starter'
starter.write_text("""#!/usr/bin/env python3
import os
import sys
import time
from pathlib import Path

ppid = os.getppid()
me = str(os.getpid())
for _ in range(100):
    found = False
    for entry in Path('/proc').iterdir():
        if not entry.name.isdecimal() or entry.name == me:
            continue
        try:
            text = (entry / 'status').read_text()
        except OSError:
            continue
        pid_text = tg_text = pp_text = None
        for line in text.splitlines():
            if line.startswith('Pid:'):
                pid_text = line.split()[1]
            elif line.startswith('Tgid:'):
                tg_text = line.split()[1]
            elif line.startswith('PPid:'):
                pp_text = line.split()[1]
        if pid_text and pid_text == tg_text and pid_text == entry.name and pp_text == str(ppid):
            found = True
            break
    if found:
        time.sleep(0.2)
        raise SystemExit(4)
    time.sleep(0.05)
raise SystemExit(4)
""")
starter.chmod(0o755)

os.environ.update(
    XDG_RUNTIME_DIR=str(run),
    XODB_GHIDRA_SOCKET=str(run / 'sidecar.sock'),
    XODB_GHIDRA_SIDECAR=str(starter),
    XODB_GHIDRA_HOME=str(work / 'ghidra-home'),
    XODB_LOG='sidecar=debug',
    XODB_TEST_REAP_BEFORE_HELPER_WAIT='1',
)

chunks = []

def drain(stream):
    while True:
        block = stream.read(4096)
        if not block:
            break
        chunks.append(block)

client = Client('mutate', '/bin/sleep', args=('30',), options=('--follow-forks',), reply_seconds=20)
thread = threading.Thread(target=drain, args=(client.p.stderr,), daemon=True)
thread.start()
try:
    deadline = time.monotonic() + 20
    processes = None
    while time.monotonic() < deadline:
        processes = client.inspect('get_processes', start=0, limit=8)
        if processes['processes'] and processes['processes'][0]['following']:
            break
        time.sleep(0.05)
    else:
        raise SystemExit(f'follow never armed: {processes}')
    while time.monotonic() < deadline:
        text = b''.join(chunks)
        if b'SidecarNotConfigured' in text:
            break
        if b'SidecarStarterFailed' in text:
            raise SystemExit('starter wait lost the exit status')
        time.sleep(0.05)
    else:
        raise SystemExit('starter result did not arrive: ' + b''.join(chunks).decode(errors='replace')[-500:])
    text = b''.join(chunks)
    if b'SidecarStarterFailed' in text:
        raise SystemExit('starter reported failure after a configured exit')
    if b'UnsupportedTargetArchitecture' in text:
        raise SystemExit('architecture error name diverged')
finally:
    client.p.stdin.close()
    client.p.wait(timeout=20)
    thread.join(timeout=5)

print('reap-helpers: pass')
