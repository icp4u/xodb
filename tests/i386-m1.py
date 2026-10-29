#!/usr/bin/env python3
"""Live i386 compat: registers, TLS, CFI, frame pointer, step, and follow."""
import argparse
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from client import Client

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', type=Path, required=True)
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = a.work.resolve()
work.mkdir(parents=True, exist_ok=True)

SOURCE = r'''
#include <pthread.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>
#include <sys/time.h>
#include <sys/wait.h>

unsigned i386_gs_sel, i386_gs_tp, i386_landed, i386_leaf_mark;

__attribute__((noinline, used)) void park(void) {
    __asm__ volatile("nop" ::: "memory");
}

/* File-scope bytes. gcc -m32 -fPIE still prefixes naked functions with
   call __x86.get_pc_thunk.ax, which is not the instruction under test. */
void step_here(void);
void disp32(void);
__asm__(
    ".text\n"
    ".globl step_here\n"
    ".type step_here, @function\n"
    "step_here:\n"
    ".byte 0x90, 0x90, 0xc3\n"
    ".size step_here, . - step_here\n"
    ".globl disp32\n"
    ".type disp32, @function\n"
    "disp32:\n"
    ".byte 0x8b, 0x45, 0x08, 0xc3\n"
    ".size disp32, . - disp32\n"
);

__attribute__((noinline, used)) void thread_ready(void) { park(); }

__attribute__((noinline, used)) void cfi_leaf(void) { park(); }
__attribute__((noinline, used)) void cfi_mid(void) { cfi_leaf(); }

__attribute__((noinline, used)) void fp_leaf(void) {
    i386_leaf_mark = 1; /* LEAF_LINE */
    park();
}
__attribute__((noinline, used)) void fp_mid(void) { fp_leaf(); }

__attribute__((noinline, used)) void source_fn(int n) {
    int local_a = n + 1; /* LINE_A */
    int local_b = local_a + 2; /* LINE_B */
    (void)local_b;
    park();
}

__attribute__((noinline, used)) void child_stop(void) { park(); }
__attribute__((noinline, used)) void exec_stop(void) { park(); }

__attribute__((noinline, used)) void land_here(void) {
    i386_landed = 0x386;
    park();
}
__attribute__((noinline, used)) void write_from(void) {
    __asm__ volatile("nop" ::: "memory");
}

__attribute__((noinline, used)) void xmm_park(void) { park(); }
__attribute__((noinline, used)) void xmm_stop(void) {
    __asm__ volatile(
        "movl $0x11223344, %%eax\n\t"
        ".byte 0x66, 0x0f, 0x6e, 0xc0\n\t"
        ::: "eax");
    xmm_park();
}

static int restart_pipe[2];
static volatile int restart_handled;
static void restart_alarm(int sig) { (void)sig; restart_handled++; }
static void *restart_writer(void *arg) {
    (void)arg;
    usleep(300000);
    return write(restart_pipe[1], "z", 1) == 1 ? 0 : arg;
}

static void *worker(void *arg) {
    unsigned sel = 0, tp = 0;
    (void)arg;
    __asm__ volatile("mov %%gs, %0" : "=r"(sel));
    __asm__ volatile("movl %%gs:0, %0" : "=r"(tp));
    i386_gs_sel = sel;
    i386_gs_tp = tp;
    thread_ready();
    return 0;
}

int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "cfi";
    if (strcmp(mode, "thread") == 0) {
        pthread_t thread;
        if (pthread_create(&thread, 0, worker, 0) != 0) return 2;
        if (pthread_join(thread, 0) != 0) return 2;
        return 0;
    }
    if (strcmp(mode, "restart") == 0) {
        /* SIGALRM interrupts main's read; SA_RESTART must restart it (orig_eax). */
        struct sigaction sa;
        memset(&sa, 0, sizeof sa);
        sa.sa_handler = restart_alarm;
        sa.sa_flags = SA_RESTART;
        sigaction(SIGALRM, &sa, 0);
        if (pipe(restart_pipe) != 0) return 2;
        sigset_t alarm_set, old_set;
        sigemptyset(&alarm_set);
        sigaddset(&alarm_set, SIGALRM);
        pthread_sigmask(SIG_BLOCK, &alarm_set, &old_set);
        pthread_t thread;
        if (pthread_create(&thread, 0, restart_writer, 0) != 0) return 2;
        pthread_sigmask(SIG_SETMASK, &old_set, 0);
        struct itimerval timer;
        memset(&timer, 0, sizeof timer);
        timer.it_value.tv_usec = 100000;
        setitimer(ITIMER_REAL, &timer, 0);
        char byte = 0;
        int got = (int)read(restart_pipe[0], &byte, 1);
        pthread_join(thread, 0);
        return got == 1 && byte == 'z' && restart_handled == 1 ? 0 : 3;
    }
    if (strcmp(mode, "signal") == 0) {
        raise(SIGUSR1);
        return 0;
    }
    if (strcmp(mode, "fork") == 0) {
        if (fork() == 0) {
            child_stop();
            _exit(0);
        }
        wait(0);
        return 0;
    }
    if (strcmp(mode, "exec") == 0) {
        if (fork() == 0) {
            execl(argv[0], argv[0], "exec-stop", (char *)0);
            _exit(1);
        }
        wait(0);
        return 0;
    }
    if (strcmp(mode, "exec-stop") == 0) {
        exec_stop();
        return 0;
    }
    if (strcmp(mode, "source") == 0) {
        source_fn(1);
        return 0;
    }
    if (strcmp(mode, "frame") == 0) {
        fp_mid();
        return 0;
    }
    if (strcmp(mode, "xmm") == 0) {
        xmm_stop();
        return 0;
    }
    if (strcmp(mode, "write") == 0) {
        write_from();
        land_here();
        return 0;
    }
    if (strcmp(mode, "step") == 0) {
        step_here();
        return 0;
    }
    cfi_mid();
    return 0;
}
'''

source_path = work / 'i386.c'
source_path.write_text(SOURCE)
lines = SOURCE.splitlines()

def line_of(mark):
    found = [i for i, text in enumerate(lines, 1) if mark in text]
    if len(found) != 1:
        raise SystemExit(f'{mark} not unique')
    return found[0]

LINE_A = line_of('LINE_A')
LINE_B = line_of('LINE_B')
LEAF_LINE = line_of('LEAF_LINE')
failures = []

def check(name, ok, detail=''):
    failures.append(name) if not ok else None
    print(('PASS ' if ok else 'FAIL ') + name + ('' if detail == '' else ': ' + str(detail)), flush=True)
    return bool(ok)

probe = subprocess.run(['gcc', '-m32', '-x', 'c', '-o', str(work / 'probe32'), '-'], input=b'int main(void){return 0;}\n', capture_output=True)
if probe.returncode != 0:
    print('SKIP i386-m1: gcc -m32 is not available: ' + probe.stderr.decode(errors='replace').strip())
    sys.exit(0)

def section_names(path):
    names = set()
    text = subprocess.check_output(['readelf', '-S', '-W', str(path)], text=True, timeout=30)
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0].startswith('[') and parts[1].startswith('.'):
            names.add(parts[1])
    return names

def compile_one(path, extra):
    cmd = ['gcc', '-m32', '-g', '-O0', '-pthread', *extra, '-o', str(path), str(source_path)]
    subprocess.run(cmd, check=True, timeout=60)
    header = subprocess.check_output(['readelf', '-h', str(path)], text=True, timeout=30)
    if 'ELF32' not in header or 'Intel 80386' not in header:
        raise SystemExit('fixture is not ELF32 i386:\n' + header)
    return header

pie = work / 'pie'
nopie = work / 'nopie'
frame_bin = work / 'frame'
compile_one(pie, ['-fomit-frame-pointer', '-fPIE', '-pie'])
compile_one(nopie, ['-fomit-frame-pointer', '-fno-pie', '-no-pie'])
compile_one(frame_bin, ['-fno-omit-frame-pointer', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '-fno-dwarf2-cfi-asm', '-fPIE', '-pie'])
drop = [name for name in ('.eh_frame', '.eh_frame_hdr', '.debug_frame') if name in section_names(frame_bin)]
if drop:
    subprocess.run(['objcopy', *[f'--remove-section={name}' for name in drop], str(frame_bin)], check=True, timeout=30)
frame_sections = section_names(frame_bin)
if '.eh_frame' in frame_sections or '.debug_frame' in frame_sections or '.debug_info' not in frame_sections:
    raise SystemExit('frame fixture still has CFI or lost debug info: ' + ' '.join(sorted(frame_sections)))
if '.eh_frame' not in section_names(pie):
    raise SystemExit('omit-frame-pointer fixture has no .eh_frame')
for binary, mode in ((pie, 'cfi'), (nopie, 'cfi'), (frame_bin, 'frame'), (pie, 'restart')):
    subprocess.run([str(binary), mode], check=True, timeout=10)

def nm_addr(path, name):
    text = subprocess.check_output(['nm', '--defined-only', str(path)], text=True, timeout=30)
    for line in text.splitlines():
        parts = line.split()
        if parts and parts[-1] == name:
            return int(parts[0], 16)
    raise AssertionError(name)

def num(value):
    if value is None or value == 'unavailable':
        return None
    return int(value, 16)

def launch(binary, args=(), options=()):
    client = Client('mutate', str(binary), args=tuple(args), options=tuple(options), reply_seconds=30)
    try:
        client.stopped(seconds=20)
        return client
    except Exception as exc:
        client.p.kill()
        client.p.wait(timeout=5)
        err = client.p.stderr.read().decode(errors='replace')
        raise AssertionError(f'{exc}\n{err}') from exc

def snap(client, process=1):
    return client.inspect('get_session', process_id=process)

def act(client, name, process=1, **args):
    return client.inspect(name, process_id=process, generation=snap(client, process)['generation'], **args)

def go(client, reason='breakpoint', seconds=20):
    client.continue_initial_stop()
    return client.stopped(reason, seconds=seconds)

def breakpoint_tid(session):
    for thread in session['threads']:
        if thread.get('reason') == 'breakpoint':
            return thread['tid']
    raise AssertionError(session['threads'])

def registers(client, tid, process=1):
    view = client.inspect('get_registers', process_id=process, tid=tid)
    return {key: num(value) for key, value in view['registers'].items()}

def symbol(client, name, process=1):
    found = client.inspect('find_symbol', process_id=process, name=name)
    return int(found['address'], 16)

def mem32(client, addr, process=1):
    raw = bytes.fromhex(client.inspect('read_memory', process_id=process, address=hex(addr), length=4)['hex'])
    return int.from_bytes(raw, 'little')

def stack(client, tid, process=1):
    return client.inspect('get_stack', process_id=process, tid=tid)['frames']

def module_paths(client):
    paths = []
    cursor = None
    for _ in range(64):
        args = {'cursor': cursor} if cursor else {}
        page = client.inspect('list_modules', **args)
        for region in page['regions']:
            paths.append(region.get('path') or '')
        cursor = page.get('next')
        if not cursor:
            return paths
    raise AssertionError('module list did not end')

def wait_processes(client, total, seconds=15):
    deadline = time.monotonic() + seconds
    last = None
    while time.monotonic() < deadline:
        last = client.inspect('get_processes')
        if last['total'] == total:
            return last
        time.sleep(0.01)
    raise AssertionError(last)

def wait_reason(client, process, reason, seconds=15):
    deadline = time.monotonic() + seconds
    last = None
    while time.monotonic() < deadline:
        last = snap(client, process)
        if last['state'] == 'exited':
            raise AssertionError(last)
        if (last['state'] == 'stopped' and not last.get('symbol_discovery_pending') and not last.get('continue_pending')
                and any(thread.get('reason') == reason for thread in last['threads'])):
            return last
        time.sleep(0.01)
    raise AssertionError(last)

def clear_breakpoints(client, process=1):
    listed = client.inspect('get_breakpoints', process_id=process)['breakpoints']
    for probe_row in listed:
        if not probe_row.get('internal'):
            act(client, 'remove_breakpoint', process, id=probe_row['id'])

def case_cfi(binary, pie):
    label = 'pie' if pie else 'nopie'
    client = None
    try:
        client = launch(binary, ('cfi',))
        session = client.session()
        check(f'{label} architecture', session['architecture'] == 'i386', session.get('architecture'))
        client.action('set_breakpoint', symbol='cfi_leaf')
        stopped = go(client)
        tid = breakpoint_tid(stopped)
        view = registers(client, tid)
        check(f'{label} no fs_base', 'fs_base' not in view and 'eip' in view and 'rip' not in view, sorted(view))
        eip = view.get('eip')
        leaf = symbol(client, 'cfi_leaf')
        link = nm_addr(binary, 'cfi_leaf')
        check(f'{label} eip', eip == leaf and eip is not None and eip < 2**32, eip)
        if pie:
            check('pie eip is relocated', eip != link, (eip, link))
        else:
            check('non-pie eip matches the link address', eip == link, (eip, link))
        orig = view.get('orig_eax')
        check(f'{label} orig_eax', orig is not None and orig < 2**32, orig)
        rows = stack(client, tid)
        symbols = [row.get('symbol') for row in rows]
        methods = [row.get('unwind_method') for row in rows[:3]]
        check(f'{label} cfi frames', len(rows) >= 2 and symbols[0] == 'cfi_leaf' and symbols[1] == 'cfi_mid', symbols[:4])
        check(f'{label} eh_frame', methods[:2] == ['eh_frame', 'eh_frame'], methods)
        if pie:
            shown = client.inspect('disassemble', address=hex(symbol(client, 'disp32')))['instructions']
            operands = shown[0]['operands']
            check('capstone uses ebp', shown[0]['mnemonic'] == 'mov' and 'ebp' in operands and 'rbp' not in operands, operands)
            paths = module_paths(client)
            blob = '\n'.join(paths)
            check('modules include the executable', any(path.endswith('/' + binary.name) or path.endswith(str(binary)) for path in paths), paths[:8])
            check('modules include the 32-bit loader or libc', 'ld-linux.so.2' in blob or 'libc.so' in blob, paths[:8])
    finally:
        save(client, label + '-cfi')
        if client is not None:
            client.close()

def case_thread():
    client = None
    try:
        client = launch(pie, ('thread',))
        client.action('set_breakpoint', symbol='thread_ready')
        stopped = go(client)
        tid = breakpoint_tid(stopped)
        view = registers(client, tid)
        tp = mem32(client, symbol(client, 'i386_gs_tp'))
        sel = mem32(client, symbol(client, 'i386_gs_sel'))
        base = view.get('gs_base')
        check('tls gs_base matches gs:0', base == tp and tp not in (None, 0) and base < 2**32, (base, tp))
        check('tls gs selector', view.get('gs') is not None and (view['gs'] & 0xffff) == (sel & 0xffff) and sel != 0, (view.get('gs'), sel))
        check('tls file has no fs_base', 'fs_base' not in view)
    finally:
        save(client, 'thread')
        if client is not None:
            client.close()

def case_signal():
    client = None
    try:
        client = launch(pie, ('signal',))
        go(client, 'signal')
        state = client.session()
        hit = next(thread for thread in state['threads'] if thread.get('reason') == 'signal')
        check('SIGUSR1', hit.get('signal') == signal.SIGUSR1, hit.get('signal'))
        view = registers(client, hit['tid'])
        check('signal eip is 32-bit', view.get('eip') is not None and view['eip'] < 2**32, view.get('eip'))
        # raise() is i386 tgkill (270); orig_eax is orig_rax, not eax (0 after tgkill).
        check('signal orig_eax is tgkill', view.get('orig_eax') == 270, view.get('orig_eax'))
    finally:
        save(client, 'signal')
        if client is not None:
            client.close()

def case_restart():
    client = None
    try:
        client = launch(pie, ('restart',))
        go(client, 'signal')
        state = client.session()
        hit = next(thread for thread in state['threads'] if thread.get('reason') == 'signal')
        check('restart SIGALRM', hit.get('signal') == signal.SIGALRM, hit.get('signal'))
        view = registers(client, hit['tid'])
        check('restart orig_eax is read', view.get('orig_eax') == 3, view.get('orig_eax'))
        check('restart eax is -ERESTARTSYS', view.get('eax') == 0xfffffe00, view.get('eax'))
        # A 32-bit write zero-extends rax; the kernel must still restart the read.
        client.action('write_register', tid=hit['tid'], name='eax', value=hex(view['eax']))
        client.continue_initial_stop()
        deadline = time.monotonic() + 20
        while client.session()['state'] != 'exited':
            if time.monotonic() > deadline:
                raise AssertionError(client.session())
            time.sleep(0.01)
        status = client.session().get('exit') or {}
        check('restart read completes after the handler', status.get('kind') == 'status' and status.get('status') == 0, status)
    finally:
        save(client, 'restart')
        if client is not None:
            client.close()

def case_source():
    client = None
    try:
        client = launch(pie, ('source',))
        ids = client.action('set_breakpoint', file=str(source_path), line=LINE_A)['ids']
        stopped = go(client)
        tid = breakpoint_tid(stopped)
        for ident in ids:
            client.action('remove_breakpoint', id=ident)
        site = client.inspect('get_source_location', address=hex(registers(client, tid)['eip']))['source']
        check('source stop line', site.get('line') == LINE_A, site)
        client.action('step_over', tid=tid)
        client.stopped(seconds=20)
        site = client.inspect('get_source_location', address=hex(registers(client, tid)['eip']))['source']
        check('step_over reaches the next line', site.get('line') == LINE_B, site)
    finally:
        save(client, 'source')
        if client is not None:
            client.close()

def case_write():
    client = None
    try:
        client = launch(pie, ('write',))
        client.action('set_breakpoint', symbol='write_from')
        stopped = go(client)
        tid = breakpoint_tid(stopped)
        clear_breakpoints(client)
        land = symbol(client, 'land_here')
        client.action('write_register', tid=tid, name='orig_eax', value=hex(0x10e))
        client.action('write_register', tid=tid, name='eip', value=hex(land))
        view = registers(client, tid)
        check('written eip keeps the low half', view.get('eip') == land and land < 2**32, view.get('eip'))
        check('written orig_eax', view.get('orig_eax') == 0x10e, view.get('orig_eax'))
        client.action('set_breakpoint', symbol='park')
        stopped = go(client)
        tid = breakpoint_tid(stopped)
        symbols = [row.get('symbol') for row in stack(client, tid)]
        check('continue lands in land_here', symbols[:2] == ['park', 'land_here'], symbols[:4])
        check('landed flag', mem32(client, symbol(client, 'i386_landed')) == 0x386)
        check('continued eip is 32-bit', registers(client, tid)['eip'] < 2**32)
    finally:
        save(client, 'write')
        if client is not None:
            client.close()

def case_xmm():
    client = None
    try:
        client = launch(pie, ('xmm',))
        client.action('set_breakpoint', symbol='xmm_park')
        stopped = go(client)
        tid = breakpoint_tid(stopped)
        extended = client.inspect('get_extended_registers', tid=tid, width=128)
        row = next(item for item in extended['vectors'] if item['name'] == 'xmm0')
        check('xmm0 from xstate', extended.get('source') == 'xstate' and row['hex'].startswith('44332211'), (extended.get('source'), row['hex'][:16]))
        check('st0 is listed', any(item['name'] == 'st0' for item in extended['x87']))
        names = [item['name'] for item in extended['vectors']]
        check('xmm0-7 only', names == [f'xmm{i}' for i in range(8)], names)
    finally:
        save(client, 'xmm')
        if client is not None:
            client.close()

def case_step():
    client = None
    try:
        client = launch(pie, ('step',))
        client.action('set_breakpoint', symbol='step_here')
        stopped = go(client)
        tid = breakpoint_tid(stopped)
        addr = symbol(client, 'step_here')
        check('breakpoint eip', registers(client, tid).get('eip') == addr, registers(client, tid).get('eip'))
        clear_breakpoints(client)
        raw = client.inspect('read_memory', address=hex(addr), length=1)['hex']
        check('step byte is nop', raw == '90', raw)
        client.action('step_instruction', tid=tid)
        client.stopped(seconds=15)
        check('single step advances one byte', registers(client, tid).get('eip') == addr + 1, registers(client, tid).get('eip'))
    finally:
        save(client, 'step')
        if client is not None:
            client.close()

def case_frame():
    client = None
    try:
        client = launch(frame_bin, ('frame',))
        client.action('set_breakpoint', file=str(source_path), line=LEAF_LINE)
        stopped = go(client)
        tid = breakpoint_tid(stopped)
        rows = stack(client, tid)
        methods = {row.get('symbol'): row.get('unwind_method') for row in rows[:4]}
        check('frame-pointer frames', methods.get('fp_leaf') == 'frame_pointer' and methods.get('fp_mid') == 'frame_pointer', methods)
        check('frame eip is 32-bit', registers(client, tid).get('eip', 2**32) < 2**32)
    finally:
        save(client, 'frame')
        if client is not None:
            client.close()

def case_fork():
    client = None
    try:
        client = launch(pie, ('fork',), ('--follow-forks',))
        client.action('set_breakpoint', symbol='child_stop')
        client.continue_initial_stop()
        tree = wait_processes(client, 2)
        child = next(item for item in tree['processes'] if item['process_id'] != 1)
        act(client, 'continue', child['process_id'])
        stopped = wait_reason(client, child['process_id'], 'breakpoint')
        tid = breakpoint_tid(stopped)
        view = registers(client, tid, child['process_id'])
        check('fork child architecture', stopped['architecture'] == 'i386', stopped.get('architecture'))
        check('fork child eip', view.get('eip') == symbol(client, 'child_stop', child['process_id']) and view['eip'] < 2**32, view.get('eip'))
    finally:
        save(client, 'fork')
        if client is not None:
            client.close()

def case_exec():
    client = None
    try:
        client = launch(pie, ('exec',))
        client.action('set_process_following', enabled=True)
        client.continue_initial_stop()
        tree = wait_processes(client, 2)
        child = next(item for item in tree['processes'] if item['process_id'] != 1)
        act(client, 'continue', child['process_id'])
        stopped = wait_reason(client, child['process_id'], 'exec')
        check('exec architecture', stopped['architecture'] == 'i386', stopped.get('architecture'))
        act(client, 'set_breakpoint', child['process_id'], symbol='exec_stop')
        act(client, 'continue', child['process_id'])
        stopped = wait_reason(client, child['process_id'], 'breakpoint')
        tid = breakpoint_tid(stopped)
        view = registers(client, tid, child['process_id'])
        check('exec child eip', view.get('eip') == symbol(client, 'exec_stop', child['process_id']) and view['eip'] < 2**32, view.get('eip'))
    finally:
        save(client, 'exec')
        if client is not None:
            client.close()

def case_agent():
    agent = os.environ.get('XODB_TEST_RUNTIME_AGENT') or os.environ.get('XODB_RUNTIME_AGENT')
    if not agent:
        agent = str(root / 'zig-out/bin/xodb-agent')
    if not os.path.exists(agent):
        check('agent-refuses-i386', False, 'missing agent')
        return
    binary = os.environ.get('XODB_BIN', str(root / 'zig-out/bin/xodb'))
    # Leave stdin open. Closing it during startup is a client disconnect, and
    # that path exits before the launch refusal is the process result.
    proc = subprocess.Popen(
        [binary, '--headless', '--mcp', '--agent-scope', 'mutate', '--runtime-agent', agent, '--', str(pie)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        # communicate() closes stdin. Keep it open so a launch refusal is the
        # process result rather than a client disconnect during startup.
        proc.wait(timeout=30)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
        check('agent-refuses-i386', False, 'timed out')
        return
    finally:
        if proc.stdin:
            proc.stdin.close()
    err = proc.stderr.read().decode(errors='replace')
    out = proc.stdout.read().decode(errors='replace')
    refused = ('error: UnsupportedArchitecture\n' in err and
               'UnsupportedTargetArchitecture' not in err and
               'RemoteOutcomeUnknown' not in err and 'RemoteOutcomeUnknown' not in out)
    check('agent-refuses-i386', proc.returncode != 0 and refused, (err or out).strip().splitlines()[0] if (err or out).strip() else 'no output')

def save(client, name):
    if client is None:
        return
    (work / (name + '.json')).write_text(json.dumps(client.transcript, indent=2) + '\n')

lane = bool(os.environ.get('XODB_TEST_RUNTIME_AGENT') or os.environ.get('XODB_RUNTIME_AGENT'))
live = [lambda: case_cfi(pie, True), lambda: case_cfi(nopie, False), case_thread, case_signal, case_restart, case_source, case_write, case_xmm, case_step, case_frame, case_fork, case_exec]
# The agent lane cannot debug i386 yet. A live session would stop at launch.
cases = [case_agent] if lane else [*live, case_agent]
for case in cases:
    try:
        case()
    except Exception as exc:
        check(case.__name__ if hasattr(case, '__name__') else 'cfi', False, exc)
if failures:
    raise SystemExit('i386-m1 failed: ' + ', '.join(failures))
print('i386-m1: pass')
