#!/usr/bin/env python3
"""Real capture -> removed build -> offline queries -> copy -> second reopen.

All files/targets are owned fixtures. No live GUI and no user processes.
"""
from datetime import datetime
from pathlib import Path
import hashlib, json, os, shutil, stat, subprocess, time
from client import Client
root = Path(__file__).resolve().parents[1]
os.chdir(root)
run = root / '.work' / ('m2-archive-' + datetime.now().strftime('%Y%m%dT%H%M%S%f'))
(run / 'build').mkdir(parents=True)
(run / 'backups').mkdir()
fixture = run / 'build' / 'profile-fixture'
shutil.copy2(root / 'zig-out/bin/xodb-profile-fixture', fixture)

def error(response, name):
    assert response['result']['isError'] and response['result']['content'][0]['text'] == name, response

def ready(c):
    deadline = time.monotonic() + 15
    while True:
        state = c.inspect('get_archive_status')
        if state['job']['done']:
            assert state['job']['error_name'] is None, state
            return state
        assert time.monotonic() < deadline, state
        time.sleep(.005)

def save(c, path):
    cap = c.inspect('get_profile')['capture']
    result = c.action('save_capture_archive', capture_id=cap['id'], revision=cap['revision'], path=str(path))
    state = ready(c)
    assert state['job']['id'] == result['job_id']
    return state['job']['publication']

def graph(c, **filters):
    cap = c.inspect('get_profile')['capture']
    kw = dict(capture_id=cap['id'], revision=cap['revision'], **filters)
    deadline = time.monotonic() + 15
    while True:
        result = c.tool('get_flamegraph', **kw)
        if not result['result']['isError']:
            first = result['result']['structuredContent']
            if not first.get('pending'): break
            kw['view_id'] = first['view_id']
            assert time.monotonic() < deadline
            time.sleep(.002)
            continue
        error(result, 'ArchiveViewPending')
        assert time.monotonic() < deadline
        ready(c)
    kw.pop('view_id', None)
    rows = first['nodes'][:]
    while first['next'] is not None:
        first = c.inspect('get_flamegraph', **kw, start=first['next'], **({'view_id':first['view_id']} if first['view_id'] else {}))
        rows += first['nodes']
    return dict(first, nodes=rows)

def normalized(g):
    return [(n['parent'], n['name'], n['kind'], n['module_id'], n['mapping_id'], n['address'], n['inclusive'], n['self']) for n in g['nodes']]

class Offline(Client):
    def __init__(self, path, symbols=None, trace=None, reanalyze=False, scope='control'):
        cmd = ['./zig-out/bin/xodb', '--headless', '--mcp', '--agent-scope', scope, '--open-capture', str(path)]
        if symbols: cmd += ['--symbols', str(symbols)]
        if reanalyze: cmd += ['--resolve-capture-symbols']
        if trace: cmd = ['strace', '-f', '-e', 'trace=ptrace,perf_event_open,process_vm_readv,fsync,fdatasync,syncfs', '-o', str(trace), *cmd]
        self.transcript, self.id = [], 0
        self.p = subprocess.Popen(cmd, bufsize=0, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.call('initialize', {'protocolVersion':'2025-06-18','capabilities':{},'clientInfo':{'name':'archive-test','version':'1'}})
        self.p.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        ready(self)

original = run / 'original.xcap'
c = Client('control', str(fixture), args=['2', 'threads'])
try:
    bp = c.action('set_breakpoint', symbol='profile_ready')['id']
    c.action('continue'); c.stopped('breakpoint'); c.action('remove_breakpoint', id=bp)
    cap = c.action('start_profile', frequency_hz=199, context_switch=True)['capture']
    c.action('continue'); time.sleep(.6)
    cap = c.action('stop_profile', capture_id=cap['id'])['capture']
    # Saving must not rely on any graph query having warmed the cache.
    published = save(c, original)
    assert published['state'] == 'published' and not published['cleanup_error'], published
    assert stat.S_IMODE(original.stat().st_mode) == 0o600
    saved_sha = hashlib.sha256(original.read_bytes()).hexdigest()
    assert published['sha256'] == saved_sha
    expected = graph(c)
    assert expected['samples'] > 20 and any(n['name'] == 'hot_hash' for n in expected['nodes'])
    cap = c.inspect('get_profile')['capture']
    first_samples = c.inspect('get_profile_samples', capture_id=cap['id'], revision=cap['revision'], limit=16)['samples']
    filters = dict(tid=cap['threads'][0]['perf']['tid'], from_ns=0, to_ns=300000000)
    expected_filtered = graph(c, **filters)
    deadline = time.monotonic() + 5
    while c.session()['state'] != 'exited':
        assert time.monotonic() < deadline
        time.sleep(.02)
finally:
    (run / 'live-rpc.json').write_text(json.dumps(c.transcript, indent=2) + '\n')
    c.close()
# Back up before removing the original fixture build path.
shutil.copytree(run / 'build', run / 'backups' / 'build')
(run / 'build').rename(run / 'retired-build')
assert not fixture.exists()

trace = run / 'offline-syscalls.log'
o = Offline(original, trace=trace)
try:
    state = o.inspect('get_archive_status')
    assert state['offline'] and state['artifact_sha256'] == saved_sha
    origin = state['recorded_origin']
    assert origin['pid'] == cap['pid'] and origin['capture_id'] == cap['id'] and origin['boot_id'] is not None
    assert origin['stack_registers'] == 'not_recorded'
    assert origin['annotation_count'] > 0 and all(i['status'] == 'not_requested' for i in origin['images'])
    actual = graph(o)
    assert normalized(actual) == normalized(expected)
    cap2 = o.inspect('get_profile')['capture']
    assert o.session()['pid'] == 0 and cap2['pid'] == 0
    samples = o.inspect('get_profile_samples', capture_id=cap2['id'], revision=cap2['revision'], limit=16)
    assert samples['samples'] == first_samples and samples['artifact_sha256'] == saved_sha
    hot = next(n for n in actual['nodes'] if n['name'] == 'hot_hash')
    kw = dict(capture_id=cap2['id'], revision=cap2['revision'], node=hot['id'])
    error(o.tool('get_profile_frame', **kw), 'ArchiveViewRequired')
    error(o.tool('get_profile_frame', **kw, view_id='stale'), 'StaleArchiveView')
    detail = o.inspect('get_profile_frame', **kw, view_id=actual['view_id'])
    assert detail['source']['path'].endswith('tests/fixtures/profile.c') and not detail['instructions']
    filtered = graph(o, **filters)
    assert normalized(filtered) == normalized(expected_filtered)
    assert filtered['view_id'] != actual['view_id']
    error(o.tool('get_flamegraph', capture_id=cap2['id'], revision=cap2['revision'], start=1, **filters), 'ArchiveViewRequired')
    error(o.tool('get_flamegraph', capture_id=cap2['id'], revision=cap2['revision'], start=1, view_id=actual['view_id'], **filters), 'StaleArchiveView')
    assert graph(o)['view_id'] == actual['view_id']
    error(o.tool('cancel_archive_job', generation=o.session()['generation'], job_id=999999), 'StaleArchiveJob')
    error(o.tool('continue', generation=o.session()['generation']), 'OfflineSession')
    error(o.tool('read_memory', address='0x1', length=1), 'OfflineSession')
    error(o.tool('add_profile_intervals', generation=o.session()['generation'], capture_id=cap2['id'], revision=cap2['revision'], source='test', intervals=[dict(from_ns=0,to_ns=1,label='x')]), 'ArchiveImmutable')
    copy = run / 'copy.xcap'
    assert save(o, copy)['state'] == 'published'
    assert copy.read_bytes() == original.read_bytes()
    assert save(o, copy)['error_name'] == 'ArchiveExists'
    link = run / 'symlink.xcap'; link.symlink_to(copy)
    assert save(o, link)['error_name'] == 'ArchiveExists' and link.is_symlink()
    # Directory read permission is not required for no-sync publication.
    write_only = run / 'write-only'; write_only.mkdir(mode=0o300)
    try: assert save(o, write_only / 'saved.xcap')['state'] == 'published'
    finally: write_only.chmod(0o700)
finally:
    (run / 'offline-rpc.json').write_text(json.dumps(o.transcript, indent=2) + '\n')
    o.close()
for call in ('ptrace(', 'perf_event_open(', 'process_vm_readv(', 'fsync(', 'fdatasync(', 'syncfs('):
    assert call not in trace.read_text(), call

again = Offline(copy)
try:
    assert again.inspect('get_archive_status')['recorded_origin'] == origin
    assert graph(again)['view_id'] == actual['view_id']
finally: again.close()

observer = Offline(original, scope='observe')
try:
    observed = observer.inspect('get_profile')['capture']
    response = observer.tool('save_capture_archive', generation=observer.session()['generation'], capture_id=observed['id'], revision=observed['revision'], path=str(run/'forbidden.xcap'))
    assert response['result']['isError'] and not (run/'forbidden.xcap').exists(), response
    error(observer.tool('get_profile_samples', capture_id=observed['id'], revision=observed['revision']+1), 'StaleProfile')
finally: observer.close()
# CLI shutdown stops and drains a still-active capture before saving.
active_path = run / 'active-close.xcap'
active = Client('control', './zig-out/bin/xodb-profile-fixture', args=['3'], options=['--capture-out',str(active_path)])
try:
    active.action('start_profile')
finally: active.close()
closed = Offline(active_path)
try:
    assert closed.inspect('get_profile')['capture']['status'] == 'manual'
    assert graph(closed)['samples'] == 0
finally: closed.close()

assets = run / 'assets'; assets.mkdir()
for image in origin['images']:
    digest = bytes(image['identity']['sha256']).hex()
    src = Path(image['path'])
    if src == fixture: src = run / 'retired-build' / fixture.name
    if not (assets / digest).exists(): shutil.copy2(src, assets / digest)
reanalyzed = Offline(original, symbols=assets, reanalyze=True)
try:
    assert reanalyzed.inspect('get_archive_status')['view_basis'] == 'verified_assets_reanalysis'
    regenerated = graph(reanalyzed)
    assert normalized(regenerated) == normalized(actual)
    assert regenerated['view_id'] != actual['view_id']
    assert save(reanalyzed, run / 'reanalysis-copy.xcap')['state'] == 'published'
    assert (run / 'reanalysis-copy.xcap').read_bytes() == original.read_bytes()
finally: reanalyzed.close()
resolved = Offline(original, symbols=assets)
try:
    reports = resolved.inspect('get_archive_status')['recorded_origin']['images']
    assert all(r['status'] == 'verified' for r in reports), reports
    with_assets = graph(resolved)
    assert normalized(with_assets) == normalized(actual)
    assert with_assets['view_id'] != actual['view_id']
    cap3 = resolved.inspect('get_profile')['capture']
    kwargs = dict(capture_id=cap3['id'], revision=cap3['revision'], node=hot['id'], view_id=with_assets['view_id'])
    before = resolved.inspect('get_profile_frame', **kwargs)
    assert before['instructions']
    image = next(i for i in origin['images'] if i['path'] == str(fixture))
    candidate = assets / bytes(image['identity']['sha256']).hex()
    shutil.copy2(candidate, run / 'backups' / 'asset-before-truncate')
    with candidate.open('wb'): pass
    after = resolved.inspect('get_profile_frame', **kwargs)
    assert after['instructions'] == before['instructions']
    assert save(resolved, run / 'after-truncate.xcap')['state'] == 'published'
    assert (run / 'after-truncate.xcap').read_bytes() == original.read_bytes()
finally: resolved.close()

oversized = run / 'oversized.xcap'
with oversized.open('xb') as f: f.truncate(256 * 1024 * 1024 + 1)
fifo = run / 'fifo'; os.mkfifo(fifo)
for bad, expected_error in ((oversized, 'ArchiveTooLarge'), (fifo, 'ArchiveNotRegular'), (run/'absent', 'ArchiveOpenFailed')):
    result = subprocess.run(['./zig-out/bin/xodb','--headless','--mcp','--open-capture',str(bad)], input=b'', capture_output=True, timeout=5)
    assert result.returncode != 0 and expected_error.encode() in result.stderr, result
fifo_assets = run / 'fifo-assets'; fifo_assets.mkdir()
image = next(i for i in origin['images'] if i['path'] == str(fixture))
os.mkfifo(fifo_assets / bytes(image['identity']['sha256']).hex())
f = Offline(original, symbols=fifo_assets)
try:
    report = next(i for i in f.inspect('get_archive_status')['recorded_origin']['images'] if i['id'] == image['id'])
    assert report['status'] == 'unreadable'
finally: f.close()
# CLI save failures must be visible to machine callers.
result = subprocess.run(['./zig-out/bin/xodb','--headless','--mcp','--open-capture',str(original),'--capture-out',str(original)], input=b'', capture_output=True, timeout=15)
assert result.returncode != 0 and b'ArchiveExists' in result.stderr
result = subprocess.run(['./zig-out/bin/xodb','--headless','--mcp','--capture-out',str(run/'no-capture')], input=b'', capture_output=True, timeout=5)
assert result.returncode != 0 and b'NoProfile' in result.stderr
assert not list(run.rglob('*.tmp'))
print('PASS: archive origin, recorded labels/source, raw samples, second save/reopen, offline controls/view guards, owned assets after truncation, filtered views/reanalysis, oversized/FIFO rejection, no-overwrite, no-sync syscall trace and CLI errors')
print(run)
