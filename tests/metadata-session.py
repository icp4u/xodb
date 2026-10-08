#!/usr/bin/env python3
"""Metadata worker ownership through real shared clients and process lifetimes."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('shared', root / 'tests/shared-sessions.py')
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', required=True, type=Path, help='Fresh short artifact path')
p.add_argument('--agent', type=Path, help='Optional local C agent through delayed transport')
p.add_argument('--delay', type=float, default=.025)
a = p.parse_args()
os.umask(0o022)
os.chdir(root)
w = a.work.resolve()
w.mkdir(mode=0o755, parents=True)
cache = w / 'cache'
cache.mkdir(mode=0o700)
os.environ['XDG_CACHE_HOME'] = str(cache)
if a.agent:
    os.environ['XODB_RUNTIME_AGENT'] = str(root / 'tests/fixtures/metadata-agent-proxy.py')
    os.environ['XODB_METADATA_AGENT'] = str(a.agent.resolve())
    os.environ['XODB_METADATA_DELAY'] = str(a.delay)
binary = Path(os.environ.get('XODB_BIN', 'zig-out/bin/xodb')).resolve()
names = dict(re.findall(r'XJS_FIELD\((\w+), "([^"]+)"\)', (root / 'src/language/javascript_fields.inc').read_text()))
values = dict(re.findall(r'META\((\w+), (-?\d+)\)', (root / 'tests/fixtures/javascript/metadata.inc').read_text()))
source = '\n'.join(f'int f_{key} __asm__("{names[key]}") = {value};' for key, value in values.items())
for name, value in zip(('major', 'minor', 'build', 'patch'), (14, 6, 202, 34)):
    source += f'\nint version_{name} __asm__("_ZN2v88internal7Version{len(name)+1}{name}_E") = {value};'
source += '''
#include <sys/wait.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
const char version_text[64] = "14.6.202.34-node.28";
const char *version_pointer __asm__("_ZN2v88internal7Version15version_string_E") = version_text;
__attribute__((noinline)) void marker(void) { __asm__ volatile("" ::: "memory"); }
int main(int argc, char **argv) {
    marker();
    if (argc > 1 && !strcmp(argv[1], "exec")) {
        execl(argv[0], argv[0], "exit", (char *)0); return 90;
    }
    if (argc > 1 && (!strcmp(argv[1], "fork") || !strcmp(argv[1], "vfork"))) {
        pid_t child = !strcmp(argv[1], "vfork") ? vfork() : fork();
        if (child < 0) return 91;
        if (!child) { marker(); _exit(0); }
        int status;
        while (waitpid(child, &status, 0) < 0) if (errno != EINTR) return 92;
    }
    return 0;
}
'''
(w / 'fixture.c').write_text(source)
fixture = w / 'fixture'
subprocess.run(['cc', '-g', '-O0', '-no-pie', '-Wl,--build-id=sha1', '-Wall', '-Wextra', '-Werror',
                str(w / 'fixture.c'), '-o', str(fixture)], check=True, timeout=60)
rows = []


def state(client, process=1):
    return client.tool('get_session', process_id=process)


def jobs(client, process=1):
    return client.tool('get_debug_metadata', process_id=process)['jobs']


def action(client, name, process=1, **args):
    return client.tool(name, generation=state(client, process)['generation'], process_id=process, **args)


def start(observer, process=1):
    before = state(observer, process)
    assert before['state'] == 'stopped', before
    tid = before['threads'][0]['tid']
    reply = observer.raw('get_language_stack', tid=tid, language='javascript', process_id=process)
    if reply['result']['isError']:
        assert reply['result']['content'][0]['text'] == 'DebugMetadataPending', reply
    found = jobs(observer, process)
    assert len(found) == 1 and found[0]['kind'] == 'javascript', found
    assert state(observer, process)['generation'] == before['generation']
    return found[0]


def ready(observer, ident):
    result = shared.eventually(lambda: jobs(observer),
        lambda j: j and j[0]['state'] in ('ready', 'failed', 'cancelled'), 'job completes', timeout=60)
    assert result[0]['id'] == ident and result[0]['state'] == 'ready', result
    return result[0]


def case(name):
    part = w / name
    part.mkdir(mode=0o755)
    server = shared.Server(root, part, binary, fixture, 'control',
        options=('--follow-forks',) if name in ('fork', 'vfork') else (), fixture_args=(name,))
    try:
        owner = shared.Client(server, 'controller')
        observer = shared.Client(server, 'observer')
        initial = shared.eventually(owner.session, lambda s: s['state'] == 'stopped', 'launch stop')
        server.remember_target(initial)
        owner.claim(ttl_ms=60000)
        return server, owner, observer
    except BaseException:
        server.close()
        raise


try:
    for name in ('control', 'restart', 'exec', 'fork', 'vfork', 'exit', 'shutdown'):
        server, owner, observer = case(name)
        report = {'name': name, 'status': 'running'}
        owned = {server.target_pid: server.target_identity}
        try:
            original = state(observer)
            tid = original['threads'][0]['tid']
            registers = observer.tool('get_registers', tid=tid)
            job = start(observer)
            report['initial_state'] = job['state']
            ident = job['id']
            if name == 'control':
                ready(observer, ident)
                for tool in ('cancel_debug_metadata', 'retry_debug_metadata'):
                    assert tool not in shared.listed_tools(observer)
                    shared.expect_error(observer.raw(tool, id=ident), 'ControlLeaseRequired')
                assert jobs(observer)[0]['state'] == 'ready'
                cancelled = owner.tool('cancel_debug_metadata', id=ident)['jobs']
                assert cancelled[0]['state'] == 'cancelled' and cancelled[0]['reason'] == 'DebugMetadataCancelled', cancelled
                shared.expect_error(observer.raw('get_language_stack', tid=tid, language='javascript'), 'DebugMetadataCancelled')
                assert not owner.tool('retry_debug_metadata', id=ident)['jobs']
                replacement = start(observer)
                assert replacement['id'] != ident
                ready(observer, replacement['id'])
                shared.expect_error(owner.raw('cancel_debug_metadata', id=ident), 'UnknownMetadataJob')
                assert state(observer)['generation'] == original['generation']
                assert observer.tool('get_registers', tid=tid) == registers
                action(owner, 'step_instruction', tid=tid)
                stopped = shared.eventually(owner.session, lambda s: s['state'] == 'stopped', 'step')
                assert stopped['generation'] != original['generation']
                # The stopped-image verifier must restart for the new generation.
                shared.expect_error(observer.raw('get_language_stack', tid=tid, language='javascript'), 'DebugMetadataPending')
            elif name == 'restart':
                action(owner, 'restart')
                after = state(observer)
                assert after['image_epoch'] > original['image_epoch'] and after['pid'] != original['pid']
                owned[after['pid']] = shared.process_identity(after['pid'])
                server.remember_target(after)
                assert not jobs(observer)
                assert start(observer)['id'] != ident
            elif name == 'exec':
                action(owner, 'continue')
                after = shared.eventually(owner.session,
                    lambda s: s['state'] == 'stopped' and s['image_epoch'] > original['image_epoch'], 'exec')
                assert not jobs(observer)
                assert start(observer)['id'] != ident
            elif name in ('fork', 'vfork'):
                action(owner, 'continue')
                tree = shared.eventually(lambda: observer.tool('get_processes'), lambda t: t['total'] == 2, 'fork')
                for process in tree['processes']:
                    ident_ = process['process_id']
                    snap = state(observer, ident_)
                    assert snap['state'] == 'stopped', snap
                    owned[snap['pid']] = shared.process_identity(snap['pid'])
                    if ident_ != 1:
                        assert not jobs(observer, ident_)
                        start(observer, ident_)
                if name == 'fork':
                    action(owner, 'detach_process_family', process=2)
                action(owner, 'detach_process_family')
                for process in (1, 2):
                    assert state(observer, process)['state'] == 'idle', state(observer, process)
                    assert not jobs(observer, process), jobs(observer, process)
                shared.eventually(lambda: [pid for pid, identity in owned.items()
                    if (now := shared.process_identity(pid)) and now[0] == identity[0] and now[1] != 'Z'],
                    lambda pids: not pids, 'detached fixture completion')
            elif name == 'exit':
                action(owner, 'continue')
                shared.eventually(owner.session, lambda s: s['state'] == 'exited', 'exit')
                assert not jobs(observer)
            else:
                # Closing the session with a remote worker in flight must join
                # it before the borrowed target/connection is destroyed.
                if a.agent:
                    assert job['state'] not in ('ready', 'failed', 'cancelled'), job
            report['status'] = 'pass'
        finally:
            server.close()
            for pid, identity in owned.items():
                now = shared.process_identity(pid)
                if now and identity and now[0] == identity[0] and now[1] != 'Z':
                    os.kill(pid, signal.SIGKILL)
                    report['cleanup_killed'] = report.get('cleanup_killed', []) + [pid]
            assert not report.get('cleanup_killed'), report
            report['server_exit'] = server.proc.returncode
            assert server.proc.returncode == 0, (report, (server.work / 'server.log').read_text())
            rows.append(report)
            (w / 'results.json').write_text(json.dumps({'checks': rows}, indent=2) + '\n')
        print(name, 'pass', flush=True)
finally:
    (w / 'results.json').write_text(json.dumps({'checks': rows}, indent=2) + '\n')
print('Metadata session cases passed:', len(rows))
