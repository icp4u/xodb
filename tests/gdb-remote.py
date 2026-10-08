#!/usr/bin/env python3
"""Owned native/gdbserver/QEMU comparison through the C API and stdio MCP.

Explicit integration test; requires gdbserver, QEMU user emulators, Clang/lld,
cc and nm. Missing dependencies are reported as skips in results.json.
"""
import argparse
import json
import os
from pathlib import Path
import re
import select
import shutil
import signal
import socket
import subprocess
import sys
import time

sys.dont_write_bytecode = True
from client import Client

ROOT = Path(__file__).resolve().parents[1]
C_FIXTURE = r'''
#include <stdint.h>
#include <stdlib.h>
#include <pthread.h>
#include <sys/prctl.h>
#include <unistd.h>
volatile uint64_t marker = UINT64_C(0x1122334455667788);
__attribute__((noinline)) void tick(void) { marker++; __asm__ volatile("" ::: "memory"); }
static void *worker(void *unused) { (void)unused; for (;;) usleep(1000); return 0; }
int main(void) {
    if (getenv("WAIT_GATE")) {
        char c;
        prctl(PR_SET_PTRACER, PR_SET_PTRACER_ANY, 0, 0, 0);
        if (write(1, "ready", 5) != 5 || read(0, &c, 1) != 1) return 1;
    }
    pthread_t thread;
    if (pthread_create(&thread, 0, worker, 0)) return 1;
    for (;;) { tick(); usleep(1000); }
}
'''
X86 = '''.text
.globl _start,tick
_start: call tick
 jmp _start
tick: addq $1,marker(%rip)
 ret
'''
ARM = '''.text
.globl _start,tick
_start: adrp x2,marker
 add x2,x2,:lo12:marker
loop: bl tick
 b loop
tick: ldr x1,[x2]
 add x1,x1,#1
 str x1,[x2]
 ret
.globl exclusive_probe
exclusive_probe: ldxr x1,[x2]
 ret
'''
DATA = '''.data
.balign 8
.globl marker
marker: .quad 0x1122334455667788
.section .note.GNU-stack,"",@progbits
'''


def birth(pid):
    return Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[19]


def listening(process, port):
    assert process.poll() is None, 'Stub exited before listening'
    inodes = set()
    for fd in Path(f'/proc/{process.pid}/fd').iterdir():
        try:
            link = os.readlink(fd)
            if link.startswith('socket:['): inodes.add(link[8:-1])
        except FileNotFoundError: pass
    for family in ('tcp', 'tcp6'):
        for line in Path(f'/proc/{process.pid}/net/{family}').read_text().splitlines()[1:]:
            fields = line.split()
            if fields[3] == '0A' and fields[9] in inodes and int(fields[1].split(':')[1], 16) == port:
                return True
    return False


class Stub:
    def __init__(self, case, directory):
        self.case, self.directory = case, directory
        self.server = self.fixture = None
        self.pid = self.start = None
        self.endpoint = None
        self.log = (directory / 'stub.log').open('wb')
        self.binary = directory / 'fixture'
        if case.startswith('qemu-'):
            architecture = case[5:]
            source = directory / 'fixture.s'
            source.write_text((ARM if architecture == 'aarch64' else X86) + DATA)
            command = ['clang', '--target=' + architecture + '-linux-gnu', '-fuse-ld=lld', '-nostdlib', '-static', '-Wl,--build-id=none', str(source), '-o', str(self.binary)]
        else:
            source = directory / 'fixture.c'; source.write_text(C_FIXTURE)
            command = ['cc', '-g', '-O2', '-fno-pie', '-no-pie', '-pthread', str(source), '-o', str(self.binary)]
        subprocess.run(command, check=True, timeout=30)
        self.symbols = {parts[2]: parts[0] for line in subprocess.check_output(['nm', '-n', str(self.binary)], text=True).splitlines()
                        if len(parts := line.split()) == 3 and parts[2] in ('marker', 'tick', 'exclusive_probe')}
        assert {'marker', 'tick'} <= self.symbols.keys()

    def start_server(self):
        if self.case == 'native': return
        if self.case.startswith('qemu-'):
            with socket.socket() as sock:
                sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
            self.server = subprocess.Popen([self.case, '-g', str(port), str(self.binary)], stdout=self.log, stderr=self.log)
            deadline = time.monotonic() + 10
            while not listening(self.server, port):
                assert time.monotonic() < deadline, 'QEMU readiness deadline'
                time.sleep(.01)
        else:
            if self.case == 'gdbserver-attach':
                self.fixture = subprocess.Popen([str(self.binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                    env={**os.environ, 'WAIT_GATE': '1'}, start_new_session=True)
                assert select.select([self.fixture.stdout], [], [], 10)[0]
                assert self.fixture.stdout.read(5) == b'ready'
                self.pid = self.fixture.pid; self.start = birth(self.pid)
            tail = ['--attach', str(self.pid)] if self.fixture else [str(self.binary)]
            self.server = subprocess.Popen(['gdbserver', '--once', '--no-disable-randomization', '127.0.0.1:0', *tail], stdout=self.log, stderr=self.log)
            port = None; deadline = time.monotonic() + 10
            while port is None:
                text = (self.directory / 'stub.log').read_bytes()
                match = re.search(rb'created; pid = (\d+)', text)
                if match and self.pid is None: self.pid = int(match.group(1)); self.start = birth(self.pid)
                match = re.search(rb'Listening on port (\d+)', text)
                if match: port = int(match.group(1))
                assert self.server.poll() is None and time.monotonic() < deadline, 'gdbserver readiness deadline'
                if port is None: time.sleep(.01)
            if self.fixture: self.fixture.stdin.write(b'!'); self.fixture.stdin.flush()
        self.endpoint = f'127.0.0.1:{port}'

    def close(self):
        if self.server:
            try: self.server.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.server.terminate(); self.server.wait(timeout=5)
        if self.pid:
            try:
                if birth(self.pid) == self.start: os.kill(self.pid, signal.SIGTERM)
            except (FileNotFoundError, ProcessLookupError): pass
        if self.fixture:
            self.fixture.wait(timeout=5); self.fixture.stdin.close(); self.fixture.stdout.close()
        self.log.close()


def mcp(stub):
    native = stub.case == 'native'
    client = Client('mutate', executable=str(stub.binary) if native else None,
                    options=() if native else ('--gdb-remote', stub.endpoint))
    try:
        initial = client.session(); assert initial['state'] == 'stopped'
        tid = initial['threads'][0]['tid']
        if not native:
            info = initial['gdb_remote']
            assert info['threads'] == info['step'] == 'available'
            assert info['libraries'] == info['watchpoints'] == 'unsupported'
            assert not client.inspect('get_breakpoints')['execution_watches']
        client.inspect('list_threads')
        registers = client.inspect('get_registers', tid=tid)['registers']
        name, pc = ('rax', 'rip') if 'rax' in registers else ('x0', 'pc')
        marker, tick = stub.symbols['marker'], stub.symbols['tick']
        assert client.inspect('read_memory', address=marker, length=8)['hex'] == '8877665544332211'
        client.action('write_memory', address=marker, hex='1122334455667788')
        assert client.inspect('read_memory', address=marker, length=8)['hex'] == '1122334455667788'
        wanted = int(registers[name], 16) ^ 0x1234
        client.action('write_register', tid=tid, name=name, value=hex(wanted))
        assert int(client.inspect('get_registers', tid=tid)['registers'][name], 16) == wanted
        client.action('write_register', tid=tid, name=name, value=registers[name])
        stale = client.tool('continue', generation=initial['generation'])
        assert stale['result']['isError'] and stale['result']['content'][0]['text'] == 'StaleSnapshot'
        probe = client.action('set_breakpoint', address=tick)['id']
        for _ in range(2):
            client.action('continue'); stopped = client.stopped('breakpoint')
            assert int(client.inspect('get_registers', tid=tid)['registers'][pc], 16) == int(tick, 16)
            if not stub.case.startswith('qemu-'): assert len(stopped['threads']) == 2
        client.action('step_instruction', tid=tid); client.stopped('single_step')
        client.action('remove_breakpoint', id=probe)
        if not stub.case.startswith('qemu-'):
            client.action('continue'); client.action('interrupt'); client.stopped('interrupt')
        assert any(event['kind'] == 'breakpoint_hit' for event in client.inspect('query_events')['events'])
        if not native:
            client.action('detach'); assert client.session()['state'] == 'idle'
    finally:
        (stub.directory / 'mcp.json').write_text(json.dumps(client.transcript, indent=2) + '\n')
        client.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work', required=True, help='Fresh owned evidence directory')
    parser.add_argument('--xodb', default='zig-out/bin/xodb')
    parser.add_argument('--cases', nargs='+', default=['native', 'gdbserver-launch', 'gdbserver-attach', 'qemu-x86_64', 'qemu-aarch64'],
                        choices=['native', 'gdbserver-launch', 'gdbserver-attach', 'qemu-x86_64', 'qemu-aarch64'])
    args = parser.parse_args(); os.umask(0o022)
    work = Path(args.work).resolve(); work.mkdir(mode=0o755, parents=True, exist_ok=False)
    os.environ['XODB_BIN'] = str(Path(args.xodb).resolve())
    build = work / 'runtime'; probe = build / 'test-gdb-target'
    with (work / 'build.log').open('w') as log:
        subprocess.run(['make', '-C', str(ROOT / 'src/runtime'), f'BUILD={build}', '-j2', str(probe)], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)
    results = []
    for case in args.cases:
        dependencies = ['cc', 'nm'] + ([case, 'clang', 'ld.lld'] if case.startswith('qemu-') else ['gdbserver'] if case != 'native' else [])
        missing = [name for name in dependencies if not shutil.which(name)]
        if missing:
            results.append(dict(case=case, status='skip', reason='Missing: ' + ', '.join(missing))); continue
        for interface in ('c', 'mcp'):
            directory = work / (case + '-' + interface); directory.mkdir(mode=0o755)
            stub = None
            try:
                stub = Stub(case, directory); stub.start_server()
                if interface == 'mcp': mcp(stub)
                else:
                    command = [str(probe), 'native' if case == 'native' else stub.endpoint, stub.symbols['marker'], stub.symbols['tick']]
                    if case == 'native': command.append(str(stub.binary))
                    elif case.startswith('qemu-'):
                        command.append('no-interrupt')
                        if 'exclusive_probe' in stub.symbols: command.append(stub.symbols['exclusive_probe'])
                    with (directory / 'probe.log').open('w') as log:
                        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=60)
                result = dict(case=case, interface=interface, status='pass', interrupt='not_tested' if case.startswith('qemu-') else 'pass')
            except Exception as error:
                result = dict(case=case, interface=interface, status='fail', reason=str(error))
            finally:
                if stub: stub.close()
            results.append(result); print(json.dumps(result), flush=True)
            (work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    (work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    return int(any(result['status'] == 'fail' for result in results))


if __name__ == '__main__': raise SystemExit(main())
