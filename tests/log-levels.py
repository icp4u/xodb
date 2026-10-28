#!/usr/bin/env python3
"""Log levels without a display: -q/-qq/-v/-vv, --log, XODB_LOG, --log-file and the agent."""
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import sys
import time

from helpers.listen import listen_and_report

root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
xodb, agent = './zig-out/bin/xodb', './zig-out/bin/xodb-agent'
work = root/'.work'/('log-levels-'+str(time.time_ns())[-8:])
work.mkdir(parents=True)
base = {k: v for k, v in os.environ.items() if k not in ('XODB_LOG', 'XODB_LOG_FILE')}
base['XODB_GHIDRA_SIDECAR'] = 'off'
serial = 0
checks = 0


def run(*options, env=None, target='local'):
    """One headless MCP session that ends at end of input. Returns (status,
    stdout, stderr, profile path). With the agent, input stays open until the
    launched program is reported, so the agent always gets to run."""
    global serial
    serial += 1
    out = work/f'profile-{serial}.json'  # never written: no capture is taken
    how = ['--redot-debugger'] if target == 'local' else ['--runtime-agent', agent]
    stdout, stderr = work/f'stdout-{serial}', work/f'stderr-{serial}'
    with stdout.open('wb') as o, stderr.open('wb') as e:
        app = subprocess.Popen([xodb, *options, '--headless', '--mcp', *how, '--profile-out', str(out), '--', '/bin/true'],
                               stdin=subprocess.PIPE, stdout=o, stderr=e, env={**base, **(env or {})})
    try:
        if target == 'agent' and app.poll() is None:
            deadline = time.monotonic() + 20
            for identity in range(1, 400):
                request = dict(jsonrpc='2.0', id=identity, method='tools/call', params=dict(name='get_session', arguments={}))
                if identity == 1:
                    request.update(method='initialize', params=dict(protocolVersion='2025-06-18', capabilities={}, clientInfo=dict(name='log-levels', version='1')))
                app.stdin.write((json.dumps(request)+'\n').encode())
                app.stdin.flush()
                while stdout.read_bytes().count(b'\n') < identity:
                    assert app.poll() is None and time.monotonic() < deadline, (stdout.read_text(), stderr.read_text())
                    time.sleep(0.01)
                reply = json.loads(stdout.read_text().splitlines()[-1])
                assert reply['id'] == identity and 'result' in reply, reply
                if identity == 1:
                    app.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
                if reply['result'].get('structuredContent', {}).get('pid'):
                    break
                time.sleep(0.02)
            else:
                raise AssertionError(stdout.read_text())
        app.stdin.close()
        status = app.wait(30)
    finally:
        if app.poll() is None:
            app.kill()
            app.wait()
    return status, stdout.read_text(), stderr.read_text(), out


def replies(stdout):
    """MCP owns stdout: every line of it is one JSON-RPC reply."""
    parsed = [json.loads(line) for line in stdout.splitlines()]
    return len(parsed) > 0 and all(reply.get('jsonrpc') == '2.0' and 'result' in reply for reply in parsed)


def check(condition, *detail):
    global checks
    assert condition, detail
    checks += 1


def plain(text):
    """Timestamps, pids, ports and the scratch path differ between two runs of one setting."""
    text = re.sub(r'\+\d+\.\d{3}s', '+T', text)
    text = re.sub(r'pid \d+', 'pid N', text)
    text = re.sub(r'port \d+', 'port N', text)
    return sorted(re.sub(r'profile-\d+\.json', 'profile.json', text).splitlines())


INFO = re.compile(r'xodb: Redot/Godot scene debugger listening on private loopback port \d+; waiting for owned pid\n')
DEBUG = re.compile(r'^xodb\[[a-z]+\] \+\d+\.\d{3}s \S', re.M)

# The default is the text of every release so far, byte for byte, and nothing else.
status, stdout, stderr, out = run()
check(status == 0 and stdout == '', status, stdout)
lines = stderr.splitlines(keepends=True)
check(len(lines) == 2 and INFO.fullmatch(lines[0]) and lines[1] == f'xodb: profile export skipped: no capture; {out}\n', stderr)

# -q keeps the warning and drops the information; -qq leaves a clean run silent.
status, stdout, stderr, out = run('-q')
check(status == 0 and stderr == f'xodb: profile export skipped: no capture; {out}\n', stderr)
status, stdout, stderr, out = run('-qq')
check(status == 0 and stderr == '' and stdout == '', stderr, stdout)
for option in ('--log=error', '--log=warn,session=error,profile=error'):
    status, stdout, stderr, out = run(option)
    check(status == 0 and stderr == '', option, stderr)
# A value in the next argument is the same option.
status, stdout, stderr, out = run('--log', 'error')
check(status == 0 and stderr == '', stderr)

# -v adds prefixed debug lines; info and warn lines keep their text. The agent
# that xodb starts logs at the same level.
status, stdout, verbose, out = run('-v', target='agent')
check(status == 0 and replies(stdout), status, stdout)
check(f'xodb: profile export skipped: no capture; {out}\n' in verbose, verbose)
check(re.search(r'^xodb\[runtime\] \+\d+\.\d{3}s starting runtime agent transport \S+ \(1 arguments\)$', verbose, re.M), verbose)
check(re.search(r'^xodb\[agent\] \+\d+\.\d{3}s agent pid \d+ serving wire version \d+$', verbose, re.M), verbose)
check(re.search(r'^xodb\[agent\] \+\d+\.\d{3}s agent stopping: end of input; closing owned targets$', verbose, re.M), verbose)
check('s request 1 op ' not in verbose, verbose)
for line in verbose.splitlines():
    check(DEBUG.match(line) or line.startswith('xodb: '), line)
status, stdout, quiet, out = run(target='agent')
check(status == 0 and not DEBUG.search(quiet), quiet)

# -vv adds per-request trace lines from the agent.
status, stdout, stderr, out = run('-vv', target='agent')
check(status == 0 and re.search(r'^xodb\[agent\] \+\d+\.\d{3}s request 1 op 1 target 0: status 0, \d+ reply bytes$', stderr, re.M), stderr)

# XODB_LOG is the same setting as the option, and the option wins.
status, stdout, stderr, out = run(env={'XODB_LOG': 'debug'}, target='agent')
check(status == 0 and plain(stderr) == plain(verbose), stderr, verbose)
status, stdout, stderr, out = run('--log=debug', target='agent')
check(status == 0 and plain(stderr) == plain(verbose), stderr, verbose)
status, stdout, stderr, out = run('-qq', env={'XODB_LOG': 'trace'}, target='agent')
check(status == 0 and stderr == '', stderr)
status, stdout, stderr, out = run('-v', env={'XODB_LOG': 'error'}, target='agent')
check(status == 0 and plain(stderr) == plain(verbose), stderr, verbose)

# A topic override raises that topic alone, here and in the agent.
status, stdout, stderr, out = run('--log=agent=trace', target='agent')
check(status == 0 and '[agent]' in stderr and 's request 1 op 1 ' in stderr and '[runtime]' not in stderr, stderr)
status, stdout, stderr, out = run('--log=runtime=debug', target='agent')
check(status == 0 and '[runtime]' in stderr and '[agent]' not in stderr, stderr)
status, stdout, stderr, out = run('--log=debug,agent=warn', target='agent')
check(status == 0 and '[runtime]' in stderr and '[agent]' not in stderr, stderr)
status, stdout, stderr, out = run('--log=render=trace', target='agent')
check(status == 0 and not DEBUG.search(stderr) and plain(stderr) == plain(quiet), stderr, quiet)

# An invalid value is one usage line and status 2, before anything is started.
for options, env, named in ((('--log=loud',), {}, '--log loud'), (('--log=paint=debug',), {}, '--log paint=debug'),
                            (('--log=render=',), {}, '--log render='), (('--log=',), {}, '--log '),
                            ((), {'XODB_LOG': 'render=7'}, 'XODB_LOG render=7'), ((), {'XODB_LOG': 'debug,'}, 'XODB_LOG debug,')):
    status, stdout, stderr, out = run(*options, env=env)
    check(status == 2 and stdout == '' and stderr.count('\n') == 1 and stderr.startswith(f'xodb: {named}: expected error, warn, info, debug or trace'), options, env, stderr)
    check('render, window, runtime, agent, session, mcp, sidecar, semq, overview, redot, profile' in stderr, stderr)
for option in ('--log', '--log-file'):
    done = subprocess.run([xodb, '--headless', '--mcp', option], input=b'', capture_output=True, env=base, timeout=30)
    check(done.returncode == 2 and done.stderr.decode().startswith(f'xodb: {option} needs a value: expected '), done)
status, stdout, stderr, out = run('--log-file', str(work/'absent'/'x.log'))
check(status == 2 and stderr.startswith('xodb: --log-file ') and 'cannot open' in stderr, stderr)

# --log-file takes every line, the agent's too, and stderr stays empty. It is
# private and appended to.
log = work/'x.log'
status, stdout, stderr, out = run('-v', '--log-file', str(log), target='agent')
check(status == 0 and stderr == '' and replies(stdout), stderr, stdout)
first = log.read_text()
check(log.stat().st_mode & 0o777 == 0o600, oct(log.stat().st_mode))
check(plain(first) == plain(verbose), first, verbose)
status, stdout, stderr, out = run(f'--log-file={log}')
check(status == 0 and stderr == '', stderr)
second = log.read_text()
check(second.startswith(first) and INFO.search(second[len(first):]) and second.endswith(f'no capture; {out}\n'), second)

# A required port-zero announcement follows --log-file even under -qq. The
# reported endpoint is live, stderr/stdout stay empty, and no other line is
# added to the file.
listen_log = work/'listen.log'
listener = subprocess.Popen([
    xodb, '-qq', '--headless', '--mcp', '--log-file', str(listen_log),
    '--listen', '127.0.0.1:0', '--', './zig-out/bin/xodb-m1-fixture', 'w',
], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=base)
peer = None
try:
    port, startup = listen_and_report(listener, listen_log, timeout=10)
    expected = f'xodb: listening on 127.0.0.1:{port}; one client, plaintext TCP without authentication\n'.encode()
    check(startup == expected, startup, expected)
    peer = socket.create_connection(('127.0.0.1', port), timeout=10)
    peer.settimeout(10)
    with peer.makefile('rwb') as wire:
        wire.write((json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {
            'protocolVersion': '2025-06-18', 'capabilities': {},
            'clientInfo': {'name': 'log-file-listen-test', 'version': '1'},
        }}, separators=(',', ':')) + '\n').encode())
        wire.flush()
        reply = json.loads(wire.readline())
        check(reply.get('id') == 1 and reply.get('result', {}).get('protocolVersion') == '2025-06-18', reply)
        wire.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        wire.flush()
    peer.close()
    peer = None
    stdout, stderr = listener.communicate(timeout=10)
    check(listener.returncode == 0 and stdout == b'' and stderr == b'', listener.returncode, stdout, stderr)
    final_log = listen_log.read_bytes()
    check(final_log == expected, final_log, expected)
finally:
    if peer is not None:
        peer.close()
    if listener.poll() is None:
        os.kill(listener.pid, signal.SIGINT)
        try:
            listener.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.kill(listener.pid, signal.SIGKILL)
            listener.wait()
    for stream in (listener.stdout, listener.stderr):
        if stream is not None and not stream.closed:
            stream.close()

# Options after "--" belong to the program.
done = subprocess.run([xodb, '--headless', '--mcp', '--', '/bin/echo', '-qq', '--log=loud'], input=b'', capture_output=True, env=base, timeout=30)
check(done.returncode == 0, done)

# The value of another option is that option's, whatever it looks like: here
# breakpoints and a source file named like log options. Nothing is logged at
# another level, no usage error is raised, and no file named by them appears.
status, stdout, usual, out = run()
for value in ('-v', '-vv', '-q', '-qq', '--log=loud', '--log', '--log-file'):
    status, stdout, stderr, out = run('--break', value)
    check(status == 0 and plain(stderr) == plain(usual) and not DEBUG.search(stderr), value, stderr)
    status, stdout, stderr, out = run('--source', value)
    check(status == 0 and plain(stderr) == plain(usual), value, stderr)
status, stdout, stderr, out = run('--break', '--log-file', '--break', str(work/'never.log'))
check(status == 0 and plain(stderr) == plain(usual) and not (work/'never.log').exists(), stderr)
# In option position right after such a value it is a log option again.
status, stdout, stderr, out = run('--break', '-v', '-qq')
check(status == 0 and stderr == '', stderr)
status, stdout, stderr, out = run('--break', '-qq', target='agent')
check(status == 0 and plain(stderr) == plain(quiet), stderr)
# The overview's parser has its own value options.
done = subprocess.run([xodb, '--overview', '--panel', '--log=loud'], input=b'', capture_output=True, env=base, timeout=30)
check(done.returncode == 1 and done.stderr == b'error: UnknownOverviewPanel\n', done)

# -vv on MCP: one line per request and reply with the name and size, never the content.
status, stdout, stderr, out = run('--log=mcp=trace', target='agent')
check(status == 0 and replies(stdout), stdout)
check(re.search(r'^xodb\[mcp\] \+\d+\.\d{3}s mcp in initialize: \d+ bytes$', stderr, re.M), stderr)
check(re.search(r'^xodb\[mcp\] \+\d+\.\d{3}s mcp in tools/call get_session: \d+ bytes$', stderr, re.M), stderr)
check(re.search(r'^xodb\[mcp\] \+\d+\.\d{3}s mcp out: \d+ bytes$', stderr, re.M) and 'jsonrpc' not in stderr and 'clientInfo' not in stderr, stderr)
check(all('[mcp]' in line for line in stderr.splitlines() if DEBUG.match(line)), stderr)
# Every ptrace stop of the launched program, from the agent that owns it.
status, stdout, stderr, out = run('--log=runtime=trace', target='agent')
check(status == 0 and re.search(r'^xodb\[runtime\] \+\d+\.\d{3}s ptrace stop tid \d+: signal \d+, event \d+$', stderr, re.M), stderr)

# MCP on stdio: at trace level stdout still carries nothing but JSON replies.
status, stdout, stderr, out = run('-vv', target='agent')
check(status == 0 and replies(stdout) and 'xodb[' not in stdout and DEBUG.search(stderr), stdout)

print(f'log levels: {checks} checks, {serial} sessions; {work}')
