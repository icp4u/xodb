#!/usr/bin/env python3
"""Race a secondary Wayland queue reader against xodb's private Vulkan GUI."""
from datetime import datetime
from pathlib import Path
import json
import os
import select
import subprocess
import sys
import time

root = Path(__file__).resolve().parents[1]
os.chdir(root)
expect_stall = '--expect-stall' in sys.argv
attach_fixture = '--attach-fixture' in sys.argv
run = root / '.work' / ('wl-race-' + datetime.now().strftime('%Y%m%dT%H%M%S%f'))
run.mkdir()
for name in ('runtime', 'tmp', 'cache'):
    (run / name).mkdir(mode=0o700)
env = dict(os.environ)
for name in ('DISPLAY', 'WAYLAND_DISPLAY', 'SWAYSOCK', 'DBUS_SESSION_BUS_ADDRESS'):
    env.pop(name, None)
env.update(XDG_RUNTIME_DIR=str(run/'runtime'), TMPDIR=str(run/'tmp'),
           XDG_CACHE_HOME=str(run/'cache'), __GL_SHADER_DISK_CACHE_PATH=str(run/'cache'),
           WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='1', WLR_LIBINPUT_NO_DEVICES='1')
(run/'sway.conf').write_text('xwayland disable\noutput HEADLESS-1 mode 1280x800\noutput * bg #0b0f16 solid_color\ndefault_border none\n')
fault = run/'race.so'
subprocess.run(['cc', '-shared', '-fPIC', '-Wall', '-Wextra', '-Werror',
                'tests/wayland-read-race.c', '-ldl', '-pthread', '-lwayland-client',
                '-o', str(fault)], env=env, check=True)
sway = app = target = None
try:
    with (run/'sway.log').open('wb') as log:
        sway = subprocess.Popen(['sway', '--unsupported-gpu', '--config', str(run/'sway.conf')],
                                env=env, stdout=log, stderr=subprocess.STDOUT)
    deadline = time.monotonic()+10
    while True:
        sockets = [p for p in (run/'runtime').glob('wayland-*') if not p.name.endswith('.lock')]
        ipc = list((run/'runtime').glob('sway-ipc*.sock'))
        if sockets and ipc:
            break
        assert sway.poll() is None and time.monotonic() < deadline, (run/'sway.log').read_text()
        time.sleep(.02)
    env.update(WAYLAND_DISPLAY=sockets[0].name, SWAYSOCK=str(ipc[0]))
    target_args = []
    if attach_fixture:
        with (run/'target.log').open('wb') as log:
            target = subprocess.Popen(['./zig-out/bin/xodb-profile-fixture', '30', 'many', '57'],
                                      env=env, stdout=log, stderr=subprocess.STDOUT)
        deadline = time.monotonic()+5
        while len(list(Path(f'/proc/{target.pid}/task').iterdir())) != 58:
            assert target.poll() is None and time.monotonic() < deadline
            time.sleep(.01)
        target_args = ['--attach', str(target.pid)]
    app_env = dict(env, LD_PRELOAD=str(fault), XODB_TEST_READ_RACE=str(run/'gate'))
    with (run/'xodb.log').open('wb') as log:
        app = subprocess.Popen(['./zig-out/bin/xodb', '--mcp', *target_args], env=app_env,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, bufsize=0)
    serial = 0
    def request(method, params, timeout=5):
        global serial
        serial += 1
        app.stdin.write((json.dumps(dict(jsonrpc='2.0', id=serial, method=method, params=params))+'\n').encode())
        app.stdin.flush()
        if not select.select([app.stdout], [], [], timeout)[0]:
            return None
        reply = json.loads(app.stdout.readline())
        assert reply['id'] == serial, reply
        return reply
    assert request('initialize', {'protocolVersion':'2025-06-18', 'capabilities':{},
                                  'clientInfo':{'name':'read-race', 'version':'1'}})
    app.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
    app.stdin.flush()
    time.sleep(1.5)  # settle the initial render and window configuration
    state = request('tools/call', {'name':'get_session','arguments':{}})['result']['structuredContent']
    if target:
        assert state['pid'] == target.pid and state['state'] == 'stopped' and len(state['threads']) == 58, state
    (run/'gate').touch()
    deadline = time.monotonic()+3
    while 'before poll returns' not in (run/'xodb.log').read_text():
        assert app.poll() is None and time.monotonic() < deadline, (run/'xodb.log').read_text()
        time.sleep(.01)
    response = request('tools/call', {'name':'get_session','arguments':{}}, timeout=1)
    if expect_stall:
        assert response is None, response
        assert 'consumed readiness' in (run/'xodb.log').read_text()
        print('Baseline reproduced: a competing reader stalls the GUI/MCP loop.', flush=True)
    else:
        assert response is not None, (run/'xodb.log').read_text()
        assert 'waiting for main reader' in (run/'xodb.log').read_text()
        for _ in range(5):
            assert request('tools/call', {'name':'get_session','arguments':{}}, timeout=1)
            time.sleep(.02)
        print('Fixed: competing reader completes and GUI/MCP stays responsive.', flush=True)
    # A compositor close wakes even the old blocked dispatch: the old log still
    # says clean shutdown, matching the reported symptom without a crash.
    subprocess.run(['swaymsg', '[app_id="xodb"]', 'kill'], env=env, check=True,
                   capture_output=True, timeout=5)
    assert app.wait(timeout=5) == 0, (run/'xodb.log').read_text()
    assert 'clean shutdown' in (run/'xodb.log').read_text()
    if not expect_stall:
        assert 'reason=compositor_close' in (run/'xodb.log').read_text()
    if target:
        assert target.poll() is None, 'Attached process was killed'
        status = Path(f'/proc/{target.pid}/status').read_text()
        assert 'TracerPid:\t0' in status, status
        assert not Path(f'/proc/{target.pid}/stat').read_text().split(') ')[1].startswith(('t', 'T')), status
        print('Owned 58-thread attach, responsive GUI, detach and target survival passed.', flush=True)
finally:
    if app and app.poll() is None:
        app.kill()
        app.wait()
    if target and target.poll() is None:
        target.kill()
        target.wait()
    if sway:
        sway.terminate()
        try:
            sway.wait(timeout=5)
        except subprocess.TimeoutExpired:
            sway.kill()
            sway.wait()
    print('Artifacts:', run, flush=True)
