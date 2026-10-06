#!/usr/bin/env python3
"""Exercise shared-session human override on a private headless compositor."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
from types import SimpleNamespace


def main():
    os.umask(0o022)
    root = Path(__file__).resolve().parents[1]
    spec = importlib.util.spec_from_file_location('shared_clients', root/'tests/shared-sessions.py')
    shared = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(shared)
    # Sway and session sockets live in the runtime directory, so its path must
    # leave room for sway-ipc.UID.PID.sock within the 107-byte socket limit.
    # Without an explicit test directory, follow the other GUI tests and use
    # the checkout's .work, whose length release-check already bounds.
    if os.environ.get('XODB_TEST_TMPDIR'):
        work = Path(tempfile.mkdtemp(prefix='xsg-', dir=os.environ['XODB_TEST_TMPDIR'])).resolve()
        runtime = work/'.work/input-shared/rt'
    else:
        work = root/'.work'/('input-shared-'+str(time.time_ns())[-10:])
        runtime = work/'rt'
    assert len(os.fsencode(runtime)) <= 72, 'Use a shorter checkout or XODB_TEST_TMPDIR for Sway sockets'
    work.mkdir(mode=0o755, parents=True, exist_ok=True)
    work.chmod(0o755)
    runtime.mkdir(mode=0o700, parents=True)
    for name in ('tmp', 'cache'):
        (work/name).mkdir(mode=0o755)
    config = work/'sway.conf'
    config.write_text('xwayland disable\noutput HEADLESS-1 mode 1280x800\n'
                      'output * bg #0b0f16 solid_color\ndefault_border none\n'
                      'focus_follows_mouse no\nseat seat0 hide_cursor 100\n')
    env = dict(os.environ)
    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'SWAYSOCK', 'DBUS_SESSION_BUS_ADDRESS'):
        env.pop(key, None)
    env.update(XDG_RUNTIME_DIR=str(runtime), TMPDIR=str(work/'tmp'), XDG_CACHE_HOME=str(work/'cache'),
               WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='1', WLR_LIBINPUT_NO_DEVICES='1', XODB_TEST_PRIVATE_DISPLAY='1')
    if os.environ.get('XODB_TEST_COMPOSITOR_RENDERER'):
        env['WLR_RENDERER'] = os.environ['XODB_TEST_COMPOSITOR_RENDERER']
    processes = []
    host = SimpleNamespace(path=runtime/'s', clients=[])
    try:
        with (work/'sway.log').open('wb') as log:
            sway = subprocess.Popen(['sway', '--unsupported-gpu', '--config', str(config)], env=env,
                                    stdout=log, stderr=subprocess.STDOUT)
        processes.append(sway)
        deadline = time.monotonic()+10
        while True:
            displays = [p for p in runtime.glob('wayland-*') if not p.name.endswith('.lock')]
            ipcs = list(runtime.glob('sway-ipc*.sock'))
            if displays and ipcs:
                break
            assert sway.poll() is None, (work/'sway.log').read_text()
            assert time.monotonic() < deadline, 'Private compositor did not start'
            time.sleep(.03)
        env.update(WAYLAND_DISPLAY=displays[0].name, SWAYSOCK=str(ipcs[0]))
        protocols = (
            ('/usr/share/wlr-protocols/unstable/wlr-virtual-pointer-unstable-v1.xml', 'virtual-pointer'),
            ('/usr/lib/wayland-debug/resources/protocols/wlroots/protocol/virtual-keyboard-unstable-v1.xml', 'virtual-keyboard'))
        for protocol, stem in protocols:
            for mode, suffix in (('client-header', '.h'), ('private-code', '.c')):
                subprocess.run(['wayland-scanner', mode, protocol, str(work/(stem+suffix))], check=True)
        pointer = work/'vinput'
        subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-I', str(work), str(root/'tests/helpers/vinput.c'),
                        str(work/'virtual-pointer.c'), str(work/'virtual-keyboard.c'), '-lwayland-client',
                        '-lxkbcommon', '-lm', '-o', str(pointer)], check=True, env=env)
        def inject(*events):
            subprocess.run([str(pointer), '1280', '800', 'layout', 'us', *events], env=env, check=True, timeout=5)
        binary = Path(os.environ.get('XODB_BIN', root/'zig-out/bin/xodb')).resolve()
        command = [str(binary), '--session-socket', str(host.path), '--agent-scope', 'control']
        if os.environ.get('XODB_RUNTIME_AGENT'):
            command += ['--runtime-agent', str(Path(os.environ['XODB_RUNTIME_AGENT']).resolve())]
        command += ['--source', str(root/'tests/fixtures/m1.c'), '--', str(root/'zig-out/bin/xodb-m1-fixture'), 'w']
        with (work/'xodb.log').open('wb') as log:
            app = subprocess.Popen(command, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=log)
        processes.append(app)
        shared.eventually(lambda: host.path.exists(), bool, 'session socket')
        owner = shared.Client(host, 'controller')
        observer = shared.Client(host, 'observer')
        snap = shared.eventually(owner.session, lambda s:s['state']=='stopped', 'initial stop')
        target_pid = snap['pid']
        identity = shared.process_identity(target_pid)
        claim = owner.claim()
        owner_id = claim['client_id']
        assert observer.info()['controller_id'] == owner_id
        time.sleep(.5)
        subprocess.run(['grim', '-o', 'HEADLESS-1', str(work/'controller.png')], env=env, check=True, timeout=5)

        inject('tap', '66')
        shared.eventually(observer.info, lambda s:s['scope']=='observe' and s['controller_id'] is None, 'human revocation')
        shared.expect_error(owner.raw('continue', generation=owner.session()['generation']), 'AgentScopeDenied')
        assert owner.session()['state'] == 'stopped'
        inject('click', '700', '65')
        shared.eventually(observer.info, lambda s:s['scope']=='control', 'human grant')
        shared.expect_error(owner.raw('continue', generation=owner.session()['generation']), 'ControlLeaseRequired')
        new_owner = observer.claim()['client_id']
        assert new_owner != owner_id and owner.info()['controller_id'] == new_owner
        # Revoke + grant in one queued key burst must not resurrect this lease.
        inject('burst', '2', '66', '66')
        shared.eventually(owner.info, lambda s:s['scope']=='control' and s['controller_id'] is None, 'double F8 revoke')
        shared.expect_error(observer.raw('continue', generation=observer.session()['generation']), 'ControlLeaseRequired')
        journal = owner.tool('get_session_events', after=0, limit=128)
        assert any(e['kind']=='revoked' and e['client_id']==new_owner for e in journal['events']), journal
        observer.claim()
        observer.tool('release_session_control')
        owner.close()
        observer.close()
        time.sleep(.1)
        reconnect = shared.Client(host, 'reconnect')
        assert reconnect.session()['pid'] == target_pid
        assert reconnect.info()['controller_id'] is None
        time.sleep(.2)
        subprocess.run(['grim', '-o', 'HEADLESS-1', str(work/'no-controller.png')], env=env, check=True, timeout=5)
        app.send_signal(signal.SIGINT)
        assert app.wait(timeout=10) == 0, (work/'xodb.log').read_text()
        assert not host.path.exists()
        current = shared.process_identity(target_pid)
        assert current is None or current[0] != identity[0] or current[1] == 'Z', current
        (work/'result.json').write_text(json.dumps({'status':'passed', 'controller':owner_id,
            'successor':new_owner, 'human_scope_revocation':True, 'zero_client_reconnect':True,
            'client_transcripts':[p.transcript for p in host.clients]}, indent=2)+'\n')
        print('Shared-session private GUI: ownership, human revocation, regrant, reconnect and cleanup passed:', work)
    finally:
        for client in host.clients:
            client.close()
        for proc in reversed(processes):
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=5)


if __name__ == '__main__':
    main()
