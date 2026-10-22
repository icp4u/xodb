#!/usr/bin/env python3
"""Private GUI: image progress keeps F8 responsive; Esc and close cancel."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', type=Path, required=True)
p.add_argument('--wrong-result', action='store_true')
a = p.parse_args()
root = Path(__file__).resolve().parents[1]; os.chdir(root); os.umask(0o022)
w = a.work.resolve(); w.mkdir(parents=True, mode=0o755)
for name in ('tmp', 'cache'): (w/name).mkdir(mode=0o755)
spec = importlib.util.spec_from_file_location('image_input', root/'tests/helpers/input.py')
h = importlib.util.module_from_spec(spec); spec.loader.exec_module(h)
h.WORK = str(w); h.HELPER = str(w/'vinput'); h.Display.reply_seconds = 30
for xml, stem in ((h.VPTR, 'virtual-pointer'), (h.VKBD, 'virtual-keyboard')):
    subprocess.run(['wayland-scanner', 'client-header', xml, str(w/(stem+'.h'))], check=True, timeout=10)
    subprocess.run(['wayland-scanner', 'private-code', xml, str(w/(stem+'.c'))], check=True, timeout=10)
subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-I', str(w), 'tests/helpers/vinput.c',
                str(w/'virtual-pointer.c'), str(w/'virtual-keyboard.c'), '-lwayland-client', '-lxkbcommon',
                '-lm', '-o', h.HELPER], check=True, timeout=30)
(w/'main.c').write_text('''
#include <stdio.h>
#include <unistd.h>
int main(void) { char b; puts("ready"); fflush(stdout); return read(0, &b, 1) < 0; }
asm(".pushsection .debug_xodb_payload,\\"\\",@progbits\\n.skip 16777216\\n.popsection");
''')
fixture = w/'image'
subprocess.run(['cc', '-g', '-O0', '-Wl,--build-id', str(w/'main.c'), '-o', str(fixture)], check=True, timeout=30)
os.truncate(fixture, 300 << 20)
target = subprocess.Popen([str(fixture)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
os.environ.update(XODB_METADATA_AGENT=str(root/'zig-out/bin/xodb-agent'), XODB_METADATA_DELAY='.005')
proxy = root/'tests/fixtures/metadata-agent-proxy.py'
d = None
result = {'status': 'running', 'load': os.getloadavg(), 'cpus': os.cpu_count()}
try:
    assert target.stdout.readline() == b'ready\n'
    d = h.Display(str(root), ['--agent-scope', 'control', '--runtime-agent', str(proxy),
                              '--attach', str(target.pid), '--image-limit', '1G'])
    stopped = d.wait(lambda s: s['state'] == 'stopped', seconds=30)
    assert stopped, d.tail()
    def request_image():
        reply = d.request('tools/call', {'name': 'get_language_stack',
                          'arguments': {'tid': target.pid, 'language': 'gdscript'}})
        assert reply.get('isError') and reply['content'][0]['text'] == 'DebugMetadataPending', reply
    request_image()
    deadline = time.monotonic() + 30
    while True:
        jobs = [j for j in d.tool('get_debug_metadata')['jobs'] if j['kind'] == 'image']
        assert len(jobs) == 1 and jobs[0]['state'] not in ('ready', 'failed', 'cancelled'), jobs
        if jobs[0]['image_total'] and jobs[0]['source_bytes']: break
        assert time.monotonic() < deadline, jobs
        time.sleep(.005)
    job = jobs[0]; result['pending'] = job
    result['progress_shot'] = d.shot('image-progress')
    # A real keyboard action must reach the owner while file I/O is active.
    d.keys('tap', 66)
    scoped = d.wait(lambda s: s['agent_scope'] == 'observe', seconds=10)
    assert scoped and scoped['state'] == 'stopped' and scoped['last_action']['action'] == 'set_agent_scope', scoped
    assert scoped['last_event_sequence'] == stopped['last_event_sequence'], scoped
    still = next(j for j in scoped['debug_metadata'] if j['id'] == job['id'])
    assert still['state'] not in ('ready', 'failed', 'cancelled'), still
    d.keys('tap', 1)
    cancelled = d.wait(lambda s: any(j['id'] == job['id'] and j['state'] == 'cancelled'
                                    for j in s['debug_metadata']), seconds=10)
    assert cancelled and cancelled['state'] == 'stopped', cancelled
    assert cancelled['last_event_sequence'] == stopped['last_event_sequence'], cancelled
    actual = next(j for j in cancelled['debug_metadata'] if j['id'] == job['id'])
    assert actual['state'] == ('ready' if a.wrong_result else 'cancelled'), actual
    result['cancelled'] = actual
    result['cancelled_shot'] = d.shot('image-cancelled')
    d.keys('tap', 66)
    assert d.wait(lambda s: s['agent_scope'] == 'control', seconds=10)
    d.tool('retry_debug_metadata', id=job['id'])
    request_image()
    pending = [j for j in d.tool('get_debug_metadata')['jobs'] if j['kind'] == 'image']
    assert pending and pending[0]['state'] not in ('ready', 'failed', 'cancelled'), pending
    d.keys('down', 42, 'tap', 16, 'up', 42)  # Shift+Q while transfer is pending
    assert d.app.wait(timeout=30) == 0, d.tail()
    result['close_pending'] = 'pass'; result['status'] = 'pass'
finally:
    if d: d.close()
    if target.poll() is None: target.kill()
    target.wait(timeout=10)
    fixture.unlink(missing_ok=True)
    if result['status'] != 'pass': result['status'] = 'failed'
    (w/'results.json').write_text(json.dumps(result, indent=2)+'\n')
print('Image GUI: progress, F8 while pending, Esc cancellation and close while pending pass')
