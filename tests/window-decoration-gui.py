#!/usr/bin/env python3
"""Fast GUI lane: which window frame each look asks the compositor for.

The default looks request the compositor's title bar (xdg-decoration,
server-side); a look that draws its own asks for none (client-side), also
when the theme key switches look in an open window. A compositor without the
protocol is stood in for by a relay that drops the global on the way to the
client. Requests and replies are read from WAYLAND_DEBUG and from the input
trace. Only a private headless compositor is used. Evidence stays in .work.
"""
import array
import importlib.util
import json
import os
from pathlib import Path
import re
import select
import signal
import socket
import struct
import subprocess
import threading
import time

started = time.monotonic()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = root / '.work' / ('input-deco-' + str(time.time_ns())[-8:])
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
replay = work / 'replay.jsonl'
subprocess.run(['python3', '-B', 'tests/fixtures/overview-synth.py', str(replay), '--frames', '20'], check=True)
MANAGER = 'zxdg_decoration_manager_v1'
CLIENT, SERVER = 1, 2
OVERVIEW = ['--overview', '--pause', '--redact', '--replay', str(replay)]
results = []

def check(name, ok, detail=''):
    results.append({'name': name, 'ok': bool(ok), 'detail': str(detail)})
    if not ok:
        raise AssertionError(name + (': ' + str(detail) if detail else ''))
    print('PASS ' + name + (': ' + str(detail) if detail else ''), flush=True)

def until(fn, label, proc, path):
    deadline = time.monotonic() + 20 * h.load_scale()
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            raise RuntimeError(label + ': exited ' + str(proc.returncode) + ': ' + Path(path).read_text(errors='replace')[-400:])
        value = fn()
        if value:
            return value
        time.sleep(.025)  # condition polling only
    raise TimeoutError(label + ': ' + Path(path).read_text(errors='replace')[-400:])

def requests(path):
    """Modes this client asked for, in order."""
    return [int(m) for m in re.findall(r'-> zxdg_toplevel_decoration_v1[#@]\d+\.set_mode\((\d+)\)', Path(path).read_text(errors='replace'))]

def replies(path):
    """Modes the compositor configured, in order."""
    return [int(m) for m in re.findall(r'^(?!.*->).*zxdg_toplevel_decoration_v1[#@]\d+\.configure\((\d+)\)', Path(path).read_text(errors='replace'), re.M)]

def recorded(path):
    """What the window recorded from each configure: (draws its own frame, granted mode)."""
    return re.findall(r'^decoration own_frame=(true|false) granted=(\w+)$', Path(path).read_text(errors='replace'), re.M)

def views(app_id, pid):
    def walk(node):
        yield node
        for child in node.get('nodes', []) + node.get('floating_nodes', []):
            yield from walk(child)
    done = subprocess.run(['swaymsg', '-r', '-t', 'get_tree'], env=d.env, capture_output=True, text=True, timeout=30)
    return done.returncode == 0 and [v for v in walk(json.loads(done.stdout)) if v.get('app_id') == app_id and v.get('pid') == pid]

def launch(name, args, display=None):
    path = os.path.join(d.dir, name + '.log')
    env = dict(d.env, WAYLAND_DEBUG='1', XODB_INPUT_TRACE='1')
    if display:
        env['WAYLAND_DISPLAY'] = display
    proc = subprocess.Popen([str(root / 'zig-out/bin/xodb'), *args], cwd=root, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=open(path, 'wb'))
    d.procs.append(proc)
    return proc, path

def default_look(name, args, app_id):
    proc, path = launch(name, args)
    until(lambda: replies(path) and recorded(path) and views(app_id, proc.pid), name + ' window and decoration configure', proc, path)
    check(name + ': default look requests the compositor frame', requests(path) == [SERVER], requests(path))
    check(name + ': compositor configured it and the window recorded the grant', replies(path)[-1] == SERVER and recorded(path)[-1] == ('false', 'server'), (replies(path), recorded(path)))
    proc.send_signal(signal.SIGTERM)
    check(name + ': exits cleanly', proc.wait(timeout=20) == 0, proc.returncode)

def serve(listener, *args):
    """A display socket for one application; the Vulkan driver connects to it as well."""
    while True:
        try:
            client, _ = listener.accept()
        except OSError:
            return
        threading.Thread(target=relay, args=(client, *args), daemon=True).start()

def relay(client, upstream, hide, dropped):
    """One connection to the compositor, minus wl_registry.global for `hide`."""
    server = socket.socket(socket.AF_UNIX)
    server.connect(upstream)
    registries, rest, held = set(), {client: b'', server: b''}, {client: [], server: []}
    try:
        while True:
            for src in select.select([client, server], [], [])[0]:
                dst = server if src is client else client
                data, ancillary, _, _ = src.recvmsg(65536, socket.CMSG_SPACE(28 * 4))
                if not data:
                    return
                for level, kind, payload in ancillary:
                    if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                        held[src] += array.array('i', payload[:len(payload) - len(payload) % 4]).tolist()
                buf, out = rest[src] + data, b''
                while len(buf) >= 8:
                    obj, word = struct.unpack_from('=II', buf)
                    size, opcode = word >> 16, word & 0xffff
                    if size < 8 or len(buf) < size:
                        break
                    message, buf = buf[:size], buf[size:]
                    if src is client and obj == 1 and opcode == 1:  # wl_display.get_registry
                        registries.add(struct.unpack_from('=I', message, 8)[0])
                    if src is server and obj == 1 and opcode == 1:  # wl_display.delete_id: the client may reuse it
                        registries.discard(struct.unpack_from('=I', message, 8)[0])
                    if src is server and obj in registries and opcode == 0 and size >= 16:  # wl_registry.global
                        length = struct.unpack_from('=I', message, 12)[0]
                        if message[16:16 + length - 1] == hide.encode():
                            dropped.append(obj)
                            continue
                    out += message
                rest[src] = buf
                if out:
                    fds, held[src] = held[src], []
                    sent = dst.sendmsg([out], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array('i', fds))] if fds else [])
                    dst.sendall(out[sent:])
                    for fd in fds:
                        os.close(fd)
    except OSError:
        pass
    finally:
        client.close()
        server.close()

d = None
listener = None
try:
    # The look with its own title bar and buttons; this one has keyboard focus.
    d = h.Display(str(root), ['--overview', '--look', 'win95', *OVERVIEW[1:]], stdio=False, trace=True, wayland_debug=True, output_size=(1280, 720))
    until(lambda: replies(d.log) and recorded(d.log), 'win95 decoration configure', d.app, d.log)
    check('compositor offers ' + MANAGER, MANAGER in Path(d.log).read_text(errors='replace'))
    check('win95 look requests no compositor frame', requests(d.log) == [CLIENT], requests(d.log))
    own, granted = recorded(d.log)[-1]
    check('win95 look recorded the compositor\'s answer', own == 'true' and granted == {CLIENT: 'client', SERVER: 'server'}[replies(d.log)[-1]], (replies(d.log), recorded(d.log)))
    # The theme key leaves win95 for the next look, which has no frame of its own.
    code = d.keys('tap', 20, wait=False).wait(timeout=10)
    check('private input helper', code == 0, code)
    until(lambda: len(requests(d.log)) > 1, 'request after theme switch', d.app, d.log)
    check('switching to a look without a frame requests the compositor frame', requests(d.log) == [CLIENT, SERVER], requests(d.log))

    default_look('overview', OVERVIEW, 'xodb-overview')
    default_look('debugger', h.TARGET, 'xodb')

    # No xdg-decoration: the window opens and closes as before, without a request.
    name = 'wayland-nodeco'
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(os.path.join(d.runtime, name))
    listener.listen(8)
    dropped = []
    thread = threading.Thread(target=serve, args=(listener, os.path.join(d.runtime, d.env['WAYLAND_DISPLAY']), MANAGER, dropped), daemon=True)
    thread.start()
    proc, path = launch('absent', OVERVIEW, display=name)
    # The compositor sees the relay, this process, as the window's client.
    until(lambda: views('xodb-overview', os.getpid()), 'window without the protocol', proc, path)
    text = Path(path).read_text(errors='replace')
    check('relay hid the global from the client', len(dropped) > 0 and 'wl_registry' in text and 'decoration' not in text.replace('org_kde_kwin_server_decoration', ''), len(dropped))
    check('without the protocol nothing is requested or recorded', not requests(path) and not recorded(path))
    proc.send_signal(signal.SIGTERM)
    check('without the protocol the window opens and exits cleanly', proc.wait(timeout=20) == 0, proc.returncode)
finally:
    if d:
        d.close()
    if listener:
        listener.close()
    report = {'lane': 'fast', 'seconds': time.monotonic() - started, 'checks': results}
    (work / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'work': str(work), 'seconds': report['seconds']}), flush=True)
