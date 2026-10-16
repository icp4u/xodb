#!/usr/bin/env python3
"""Opt-in native build/offscreen lane. No windows, installs or debugger claims.

Run with --ssh HOST from Linux; sources and locally compiled shaders go into
a fresh owned ~/xodb-mac/native-check.* directory. Artifacts stay there for
inspection. Native execution is bounded and only signals children it creates.
"""
import argparse
import io
import json
import os
from pathlib import Path
import re
import resource
import selectors
import shlex
import socket
import subprocess
import sys
import tarfile
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
GUARD = 'test "$(uname -s)" = Darwin || exit 9; '


def check(ok, message):
    if not ok:
        raise RuntimeError(message)


def run(argv, **kwargs):
    return subprocess.run(argv, check=True, timeout=kwargs.pop('timeout', 300), **kwargs)


def native():
    check(sys.platform == 'darwin', 'native lane requires Darwin')
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    env = dict(os.environ, XODB_MAC_OFFSCREEN='1', MVK_CONFIG_LOG_LEVEL='1',
               ZIG_GLOBAL_CACHE_DIR=str(ROOT / '.cache/zig-global'))
    zig = os.environ.get('XODB_MAC_ZIG', 'zig')
    deps = os.environ.get('XODB_MAC_DEPS', 'tools/deps-prefix')
    mvk = os.environ.get('XODB_MAC_MOLTENVK', 'tools/moltenvk')
    run([zig, 'build', 'app', 'bundle', 'test-cocoa', '-Doptimize=ReleaseSafe',
         '-Ddeps=' + deps, '-Dmoltenvk=' + mvk, '-Dshader-dir=.work/mac-shaders', '-j2', '--summary', 'all'], env=env)
    bad = subprocess.run(['zig-out/bin/cocoa-native', 'planted-wrong-width'],
                         env=env, capture_output=True, timeout=15)
    check(bad.returncode != 0 and b'CHECK failed: width ==' in bad.stderr,
          'native oracle did not reject its planted wrong width')
    binary = 'zig-out/xodb.app/Contents/MacOS/xodb'
    samples = []
    for label in ('first-execution-of-bundle', 'warm-1', 'warm-2'):
        done = run(['/usr/bin/time', '-l', binary, '--frames', '3'], env=env, capture_output=True, text=True, timeout=20)
        match = re.search(r'first window frame submitted in ([\d.]+) ms', done.stdout)
        check(match and 'clean shutdown (reason=frame_limit)' in done.stderr, 'frame smoke did not close cleanly')
        check('remote connection ended' not in done.stderr, 'preview unexpectedly opened a transport')
        rss = re.search(r'(\d+)\s+maximum resident set size', done.stderr)
        cpu = re.search(r'([\d.]+) real\s+([\d.]+) user\s+([\d.]+) sys', done.stderr)
        check(rss and cpu, 'native timing utility did not report CPU/RSS')
        samples.append(dict(run=label, main_to_submit_ms=float(match[1]),
                            peak_rss_bytes=int(rss[1]), wall_s=float(cpu[1]),
                            user_s=float(cpu[2]), system_s=float(cpu[3])))
    # A synthetic protocol publication exercises actual native TCP and GUI
    # ownership. This is not a local debugserver or live-target acceptance test.
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen(1)
    listener.settimeout(20)
    failures = []

    def serve():
        try:
            conn, _ = listener.accept()
            with conn, conn.makefile('rb') as stream:
                conn.settimeout(20)
                for line in stream:
                    request = json.loads(line)
                    if 'id' not in request:
                        continue
                    if request['method'] == 'initialize':
                        result = dict(protocolVersion='2025-06-18')
                    elif request['method'] == 'tools/list':
                        result = dict(tools=[dict(name='get_debug_view')])
                    else:
                        check(request['params']['name'] == 'get_debug_view', 'unexpected preview command')
                        result = dict(structuredContent=dict(schema=1, session_id=1, generation=7,
                            pid=123, architecture='aarch64', state='stopped', scope='observe', owned=False,
                            source=dict(path='fixture.c', text='int value = 7;\n'),
                            locals=[dict(name='value', type='int', display='7', availability='available')]))
                    conn.sendall((json.dumps(dict(jsonrpc='2.0', id=request['id'], result=result)) + '\n').encode())
        except Exception as error:
            failures.append(str(error))

    worker = threading.Thread(target=serve, daemon=True)
    worker.start()
    process = subprocess.Popen([binary, '--connect', '127.0.0.1:' + str(listener.getsockname()[1])],
                               env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    output = bytearray()
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            deadline = time.monotonic() + 20
            while b'first window frame submitted' not in output or b'generation=7' not in output:
                remaining = deadline - time.monotonic()
                check(remaining > 0, 'native GUI did not receive and render the synthetic publication')
                if selector.select(remaining):
                    chunk = os.read(process.stdout.fileno(), 8192)
                    check(chunk, 'native GUI exited before publication/presentation')
                    output.extend(chunk)
        process.terminate()
        output.extend(process.communicate(timeout=15)[0])
        check(process.returncode == 0 and b'clean shutdown (reason=signal)' in output, 'SIGTERM bypassed normal close')
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        listener.close()
        worker.join(timeout=2)
    check(not worker.is_alive() and not failures, 'synthetic transport did not close cleanly')
    report = dict(native_build='pass', cocoa_contract='pass', negative_oracle='pass',
                  bundle_signature='pass', offscreen_present='pass', tcp_publication='pass',
                  sigterm='pass', samples=samples, on_screen='not_tested', local_debugserver='not_implemented')
    (ROOT / '.work/macos-native-results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))


def remote(host):
    ssh = ['ssh', '-o', 'BatchMode=yes', '-o', 'LogLevel=ERROR', '-o', 'ConnectTimeout=10', host]
    directory = run(ssh + [GUARD + 'umask 022; mkdir -p "$HOME/xodb-mac" && mktemp -d "$HOME/xodb-mac/native-check.XXXXXX"'],
                    capture_output=True, text=True, timeout=20).stdout.strip()
    check(directory.startswith('/') and '\n' not in directory, 'invalid owned work directory')
    (ROOT / '.work').mkdir(exist_ok=True)
    (ROOT / '.work/macos-native-remote-dir.txt').write_text(directory + '\n')
    prefix = GUARD + 'cd ' + shlex.quote(directory) + ' || exit 8; '
    archive = io.BytesIO()
    with tempfile.TemporaryDirectory(prefix='mac-shaders-') as temporary:
        with tarfile.open(fileobj=archive, mode='w') as tar:
            for path in ('build.zig', 'build_macos.zig', 'build.zig.zon', 'src', 'scripts', 'tests', 'tools', 'config'):
                if (ROOT / path).exists():
                    tar.add(ROOT / path, arcname=path, filter=lambda entry: None if '__pycache__' in entry.name else entry)
            for source in sorted((ROOT / 'src/render').rglob('*')):
                if source.suffix not in ('.vert', '.frag'):
                    continue
                output = Path(temporary) / (source.name + '.spv')
                run(['glslc', str(source), '-o', str(output)], timeout=15)
                tar.add(output, arcname='.work/mac-shaders/' + output.name)
    run(ssh + [prefix + 'tar xf -'], input=archive.getvalue(), timeout=60)
    settings = ['XODB_MAC_OFFSCREEN=1']
    for name in ('XODB_MAC_ZIG', 'XODB_MAC_DEPS', 'XODB_MAC_MOLTENVK'):
        if name in os.environ:
            settings.append(name + '=' + shlex.quote(os.environ[name]))
    run(ssh + [prefix + ' '.join(settings) + ' /usr/bin/python3 -B tests/macos-native.py --native'], timeout=360)
    print('Native artifacts retained in the fresh ~/xodb-mac/native-check.* directory; no on-screen launch.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--ssh')
    mode.add_argument('--native', action='store_true')
    args = parser.parse_args()
    os.chdir(ROOT)
    if args.native:
        native()
    else:
        remote(args.ssh)
