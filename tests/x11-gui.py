#!/usr/bin/env python3
"""X11 window backend on a private Xwayland, never the desktop display.

The private compositor has Xwayland turned off. This test starts its own
Xwayland on that compositor, then checks the first frame, the startup split,
keyboard, pointer, resize, Xft.dpi, a clipboard round trip, close, and overview.
"""
import os
from pathlib import Path
import re
import subprocess
import time

root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = root / '.work' / ('x11gui' + str(time.time_ns())[-8:])
runtime = work / 'runtime'
runtime.mkdir(parents=True, mode=0o700)
for name in ('tmp', 'cache/mesa', 'cache/nvidia'):
    (work / name).mkdir(parents=True, exist_ok=True)

helper = work / 'x11-gate'
subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', 'tests/x11-gate.c', '-lxcb', '-lxcb-xtest', '-o', str(helper)], check=True, timeout=30)

config = work / 'sway.conf'
config.write_text('xwayland disable\noutput HEADLESS-1 mode 1280x800\noutput * bg #0b0f16 solid_color\ndefault_border none\nfocus_follows_mouse no\nseat seat0 hide_cursor 100\n')
sway_env = dict(os.environ)
for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'SWAYSOCK', 'DBUS_SESSION_BUS_ADDRESS', 'XODB_VK_DEVICE'):
    sway_env.pop(key, None)
sway_env.update(TMPDIR=str(work / 'tmp'), XDG_CACHE_HOME=str(work / 'cache'), MESA_SHADER_CACHE_DIR=str(work / 'cache/mesa'), __GL_SHADER_DISK_CACHE_PATH=str(work / 'cache/nvidia'), XDG_RUNTIME_DIR=str(runtime), WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='1', WLR_LIBINPUT_NO_DEVICES='1')
sway_log = open(work / 'sway.log', 'wb')
sway = subprocess.Popen(['sway', '--unsupported-gpu', '--config', str(config)], env=sway_env, stdout=sway_log, stderr=subprocess.STDOUT)

xwayland = None
app = None
offer = None
dpi_proc = None
checks = 0
x_env = None


def check(condition, *detail):
    global checks
    assert condition, detail
    checks += 1


def wait_for(probe, seconds, what):
    deadline = time.monotonic() + seconds
    last = None
    while time.monotonic() < deadline:
        last = probe()
        if last:
            return last
        time.sleep(0.05)
    raise AssertionError((what, last))


def stop(proc, log=None):
    if proc is None or proc.poll() is not None:
        if log: log.close()
        return
    proc.terminate()
    try:
        proc.wait(5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    if log: log.close()


try:
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        names = list(runtime.iterdir())
        sockets = [p.name for p in names if p.name.startswith('wayland-') and not p.name.endswith('.lock')]
        if sockets and any(p.name.startswith('sway-ipc') for p in names):
            break
        if sway.poll() is not None:
            raise RuntimeError('private compositor exited')
        time.sleep(0.05)
    else:
        raise TimeoutError('private compositor did not start')
    wayland_name = sockets[0]
    read_fd, write_fd = os.pipe()
    os.set_blocking(read_fd, False)
    x_env = dict(sway_env)
    x_env['WAYLAND_DISPLAY'] = wayland_name
    x_env.pop('DISPLAY', None)
    xwayland_log = open(work / 'xwayland.log', 'wb')
    xwayland = subprocess.Popen(['Xwayland', '-displayfd', str(write_fd), '-rootless', '-nolisten', 'tcp'], env=x_env, pass_fds=(write_fd,), stdout=xwayland_log, stderr=subprocess.STDOUT)
    os.close(write_fd)
    number = b''
    deadline = time.monotonic() + 10
    while b'\n' not in number and time.monotonic() < deadline:
        if xwayland.poll() is not None:
            raise RuntimeError('private X server exited')
        try:
            chunk = os.read(read_fd, 32)
        except BlockingIOError:
            time.sleep(0.05)
            continue
        if not chunk:
            time.sleep(0.05)
            continue
        number += chunk
    os.close(read_fd)
    check(b'\n' in number, number)
    x_env['DISPLAY'] = ':' + number.split(b'\n', 1)[0].decode()
    x_env['XODB_INPUT_TRACE'] = '1'
    x_env.pop('XODB_VK_DEVICE', None)
    x_env.pop('WAYLAND_DISPLAY', None)

    def gate(*args, timeout=8):
        done = subprocess.run([str(helper), *args], env=x_env, capture_output=True, text=True, timeout=timeout)
        return done

    dpi_proc = subprocess.Popen([str(helper), 'dpi'], env=x_env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    ready = dpi_proc.stdout.readline()
    if dpi_proc.poll() is not None:
        check(False, ready, dpi_proc.stderr.read())
    check(ready == 'ready\n', ready)

    xodb = root / 'zig-out/bin/xodb'
    out = open(work / 'xodb.out', 'wb')
    err = open(work / 'xodb.err', 'wb')
    app = subprocess.Popen([str(xodb), '--log=window=debug'], stdin=subprocess.DEVNULL, stdout=out, stderr=err, env=x_env)

    def logs():
        return (work / 'xodb.out').read_text(errors='replace'), (work / 'xodb.err').read_text(errors='replace')

    wait_for(lambda: 'first window frame submitted' in logs()[0], 40, 'first frame')
    time.sleep(0.3)
    stdout, stderr = logs()
    check(re.search(r'^xodb: first window frame submitted in \d+\.\d{3} ms\n', stdout), stdout)
    check(re.search(r'^xodb\[window\] \+\d+\.\d{3}s startup connect=\d+\.\d{3} window=\d+\.\d{3} instance=\d+\.\d{3} device=\d+\.\d{3} swapchain=\d+\.\d{3} draw=\d+\.\d{3} ms$', stderr, re.M), stderr)
    check(re.search(r'ui scale effective=2\.00 reported=2\.00 override=no', stderr), stderr)

    found = wait_for(lambda: (done.stdout.strip() if (done := gate('find', 'xodb')).returncode == 0 else ''), 10, 'window')
    check(found.isdigit(), found)
    focused = gate('focus', found)
    check(focused.returncode == 0, focused.stderr)
    time.sleep(0.3)

    def tap(code):
        down = gate('key', found, str(code), 'down')
        up = gate('key', found, str(code), 'up')
        check(down.returncode == 0 and up.returncode == 0, down.stderr, up.stderr)

    def chord(modifier, code):
        check(gate('key', found, str(modifier), 'down').returncode == 0)
        tap(code)
        check(gate('key', found, str(modifier), 'up').returncode == 0)

    # Focus from another client can land after the first key. Repeat E until
    # the window has it; a later E only changes the open editor's mode.
    deadline = time.monotonic() + 5
    while 'input press code=18' not in logs()[1]:
        if time.monotonic() > deadline:
            check(False, 'editor key', logs()[1])
        gate('focus', found)
        tap(26)
        time.sleep(0.05)
    time.sleep(0.2)
    tap(38)  # a
    tap(38)
    time.sleep(0.2)
    chord(37, 54)  # Ctrl+C
    last_copy = []

    def poll_copy():
        done = gate('take', 'aa')
        last_copy[:] = [done]
        return done if done.returncode == 0 else None

    try:
        copied = wait_for(poll_copy, 8, 'copy')
    except AssertionError:
        done = last_copy[-1] if last_copy else None
        check(False, 'copy', None if done is None else (done.returncode, done.stdout, done.stderr), logs()[1][-2500:])
    check(copied.stdout.strip() == 'bytes 2', copied.stdout, copied.stderr)

    offer_log = open(work / 'offer.err', 'wb')
    offer = subprocess.Popen([str(helper), 'offer', 'x11paste'], env=x_env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=offer_log, text=True)
    ready = offer.stdout.readline()
    check(ready == 'ready\n' and offer.poll() is None, ready)
    chord(37, 55)  # Ctrl+V
    try:
        wait_for(lambda: 'clipboard ready 8 bytes' in logs()[1], 8, 'paste')
    except AssertionError:
        offer_log.flush()
        check(False, 'paste', found, (work / 'offer.err').read_text(errors='replace'), logs()[1][-900:])
    offer.wait(5)
    offer_log.flush()
    check(offer.returncode == 0, (work / 'offer.err').read_text(errors='replace'))

    clicked = gate('click', found)
    check(clicked.returncode == 0, clicked.stderr)
    # 900x700 is below the scale-2 minimum hint (1280x800). Ask for a size the
    # window manager can apply, and require that the pixels are that size.
    resized = gate('resize', found, '2000', '1200')
    check(resized.returncode == 0, resized.returncode, resized.stdout, resized.stderr)
    time.sleep(0.3)
    check(resized.stdout.strip() == '2000 1200' and 'window size 2000x1200' in logs()[1], resized.stdout, logs()[1][-800:])
    check('input press code=18' in logs()[1] and 'input press code=30' in logs()[1] and 'input button_press code=272' in logs()[1], logs()[1][-800:])

    deleted = gate('delete', found)
    check(deleted.returncode == 0, deleted.stderr)
    wait_for(lambda: app.poll() is not None and 'reason=compositor_close' in logs()[1], 15, logs()[1])
    stdout, stderr = logs()
    check(app.returncode == 0, app.returncode, stderr)
    check(re.fullmatch(r'xodb: first window frame submitted in \d+\.\d{3} ms\n', stdout), stdout)
    out.close()
    err.close()
    app = None

    both = dict(x_env)
    both['WAYLAND_DISPLAY'] = wayland_name
    overview = subprocess.run([str(xodb), '--overview', '--frames', '2', '--platform', 'x11', '--log=window=debug'], stdin=subprocess.DEVNULL, capture_output=True, env=both, timeout=40)
    overview_out = overview.stdout.decode(errors='replace')
    overview_err = overview.stderr.decode(errors='replace')
    check(overview.returncode == 0, overview.returncode, overview_err)
    check(re.fullmatch(r'xodb: first window frame submitted in \d+\.\d{3} ms\n', overview_out), overview_out)
    check('reported=' in overview_err and 'reason=frame_limit' in overview_err, overview_err)
    print(f'PASS x11-gui {checks} checks')
finally:
    stop(offer)
    stop(dpi_proc)
    stop(app)
    stop(xwayland)
    stop(sway, sway_log)
