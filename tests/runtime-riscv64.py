#!/usr/bin/env python3
"""riscv64 software-step driver for tests/fixtures/runtime-riscv64.c.

Successors come from symbol addresses, not from one linked layout.
Forty instruction steps, continue-from-breakpoint, the lr/sc unit and
400 contended continues, source step, and a signal during a step.
"""
import os
import re
import sys
import time
import argparse
import fcntl
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from client import Client

# Current symbol, successor symbol (None means the ra saved at seq), check name.
WALK = [
    ('s_c2', 's_w4', '2-byte c.addi'),
    ('s_w4', 's_cbeqz_nt', '4-byte addi'),
    ('s_cbeqz_nt', 's_cbnez_t', 'c.beqz not taken'),
    ('s_cbnez_t', 's_beq_nt', 'c.bnez taken'),
    ('s_beq_nt', 's_bne_t', 'beq not taken'),
    ('s_bne_t', 's_li_a1', 'bne taken'),
    ('s_li_a1', 's_cbeqz_t', None),
    ('s_cbeqz_t', 's_cbnez_nt', 'c.beqz taken'),
    ('s_cbnez_nt', 's_cj', 'c.bnez not taken'),
    ('s_cj', 's_caddiw', 'c.j'),
    ('s_caddiw', 's_mv_t6', 'c.addiw (rv32 c.jal encoding) is +2'),
    ('s_mv_t6', 's_jal', None),
    ('s_jal', 'sub1', 'jal ra (call)'),
    ('sub1', 's_cret', None),
    ('s_cret', 's_auipc_t0', 'c.jr ra (ret)'),
    ('s_auipc_t0', 's_addi_t0', None),
    ('s_addi_t0', 's_jalr', None),
    ('s_jalr', 'sub2', 'jalr ra,0(t0)'),
    ('sub2', 's_jret', None),
    ('s_jret', 's_after_jalr', 'jalr x0,0(ra) (ret)'),
    ('s_after_jalr', 's_cjalr', None),
    ('s_cjalr', 'sub2', 'c.jalr t0'),
    ('sub2', 's_jret', None),
    ('s_jret', 's_after_cjalr', 'jalr x0,0(ra) (ret)'),
    ('s_after_cjalr', 's_auipc_t1', None),
    ('s_auipc_t1', 's_addi_t1', None),
    ('s_addi_t1', 's_jalr_reg', None),
    ('s_jalr_reg', 'sub2', 'jalr ra,8(t1), t1 rewritten at the step'),
    ('sub2', 's_jret', None),
    ('s_jret', 's_after_jalr_reg', 'jalr x0,0(ra) (ret)'),
    ('s_after_jalr_reg', 's_auipc_t2', None),
    ('s_auipc_t2', 's_addi_t2', None),
    ('s_addi_t2', 's_cjr', None),
    ('s_cjr', 's_mv_t4', 'c.jr t2'),
    ('s_mv_t4', 's_li_a7', None),
    ('s_li_a7', 's_ecall', None),
    ('s_ecall', 's_after_ecall', 'ecall getpid'),
    ('s_after_ecall', 's_mv_ra', None),
    ('s_mv_ra', 's_ret', None),
    ('s_ret', None, 'c.jr ra return to main'),
]
PLANTED = ['s_c2', 's_w4', 's_caddiw', 's_cbnez_t', 's_bne_t', 's_cj', 's_jal', 's_cret',
           's_jret', 's_cjalr', 's_jalr_reg', 's_cjr', 's_ecall', 's_ret']
HITS = ['s_c2', 's_w4', 's_cbnez_t', 's_bne_t', 's_cj', 's_caddiw', 's_jal', 's_cret',
        's_jret', 's_cjalr', 's_jret', 's_jalr_reg', 's_cjr', 's_ecall', 's_ret']
assert len(WALK) == 40 and sum(1 for row in WALK if row[2]) == 21 and len(HITS) == 15

p = argparse.ArgumentParser()
p.add_argument('--ssh', required=True)
p.add_argument('--ssh-config', dest='ssh_file')
p.add_argument('--agent', required=True)
p.add_argument('--fixture', required=True)
p.add_argument('--mode', choices=['step', 'cont', 'lrsc', 'src', 'sig', 'all'], default='all')
args = p.parse_args()
os.chdir(Path(__file__).resolve().parents[1])
source = Path('tests/fixtures/runtime-riscv64.c')
rows = source.read_text().splitlines()

def line_of(mark):
    found = [i for i, text in enumerate(rows, 1) if mark in text]
    if len(found) != 1:
        raise SystemExit(f'{mark} not unique in the fixture')
    return found[0]

LINE_A, LINE_B, LINE_C, LINE_D = (line_of(mark) for mark in ('/* LINE_A */', '/* LINE_B */', '/* LINE_C */', '/* LINE_D */'))
options = ['--runtime-agent', args.agent, '--runtime-ssh', args.ssh]
if args.ssh_file:
    options += ['--ssh-config', args.ssh_file]
results = []

def check(name, ok, detail=''):
    results.append((name, bool(ok), detail))
    print(('PASS ' if ok else 'FAIL ') + name + ('' if detail == '' else ': ' + str(detail)), flush=True)
    return bool(ok)

def num(value):
    if isinstance(value, int):
        return value
    return int(value, 16)

def open_client():
    client = Client('mutate', executable=args.fixture, options=options, reply_seconds=60)
    fd = client.p.stderr.fileno()
    fcntl.fcntl(fd, fcntl.F_SETFL, fcntl.fcntl(fd, fcntl.F_GETFL) | os.O_NONBLOCK)
    client.stderr_chunks = []
    return client

def drain(client):
    while True:
        try:
            block = os.read(client.p.stderr.fileno(), 1 << 16)
        except BlockingIOError:
            return
        if not block:
            return
        client.stderr_chunks.append(block)

def output(client):
    drain(client)
    return b''.join(client.stderr_chunks).decode(errors='replace')

def wait_session(client, seconds):
    deadline = time.monotonic() + seconds
    last = None
    while time.monotonic() < deadline:
        drain(client)
        last = client.session()
        if last['state'] == 'exited':
            return last
        if (last['state'] == 'stopped' and last.get('threads')
                and not last.get('symbol_discovery_pending') and not last.get('continue_pending')):
            return last
        time.sleep(0.02)
    raise AssertionError(f'stop timeout: {last}')

def sym(client, name):
    found = client.inspect('find_symbol', name=name)
    return num(found['address'])

def regs(client, tid):
    view = client.inspect('get_registers', tid=tid)
    return {key: num(value) for key, value in view['registers'].items()}

def mem(client, addr, size):
    return bytes.fromhex(client.inspect('read_memory', address=hex(addr), length=size)['hex'])

def probes(client):
    listed = client.inspect('get_breakpoints')
    return listed.get('breakpoints') or []

def stopped_tid(session, want=None):
    threads = session['threads']
    if want is not None:
        for thread in threads:
            if thread.get('breakpoint_address') == want:
                return thread['tid']
    for thread in threads:
        if thread.get('reason') == 'breakpoint':
            return thread['tid']
    for thread in threads:
        if thread.get('reason') not in (None, 'none', ''):
            return thread['tid']
    return threads[0]['tid']

def cont(client, skip_signals=True, seconds=30):
    for _ in range(8):
        state = client.session()
        if state['state'] == 'exited':
            return state
        reply = client.tool('continue', generation=state['generation'])
        result = reply.get('result', {})
        if result.get('isError') and result.get('content') == [{'type': 'text', 'text': 'StaleSnapshot'}]:
            continue
        if reply.get('error') or result.get('isError'):
            raise AssertionError(reply)
        session = wait_session(client, seconds)
        signals = [thread for thread in session['threads'] if thread.get('reason') == 'signal']
        hits = [thread for thread in session['threads'] if thread.get('reason') in ('breakpoint', 'interrupt')]
        if skip_signals and session['state'] == 'stopped' and signals and not hits:
            continue
        return session
    raise AssertionError('continue did not settle')

def step(client, tid):
    reply = client.tool('step_instruction', generation=client.session()['generation'], tid=tid)
    if reply.get('error') or reply.get('result', {}).get('isError'):
        return None, reply
    return wait_session(client, 30), reply

def word(client, addr):
    return int.from_bytes(mem(client, addr, 4), 'little')

def load(client):
    session = wait_session(client, 60)
    client.tool('claim_session_control')
    if session.get('architecture') != 'riscv64':
        raise AssertionError(session.get('architecture'))
    names = ['seq', 's_c2', 'sub1', 'sub2', 'sub3', 's_lr', 's_sc', 's_after_sc', 's_sleep_ecall',
             's_after_sleep', 'counter', 'alarms', 'code_begin', 'code_end', 'phase']
    names += [row[0] for row in WALK] + [row[1] for row in WALK if row[1]]
    table = {}
    for name in dict.fromkeys(names):
        table[name] = sym(client, name)
    if table['seq'] != table['s_c2']:
        raise AssertionError('seq and s_c2 differ')
    table['code_len'] = table['code_end'] - table['code_begin']
    if not 0 < table['code_len'] <= 4096:
        raise AssertionError(table['code_len'])
    return table

def intact(text):
    # 'code-intact: N bytes, 0 differ' exactly; '10 differ' must not pass.
    return re.search(r'^code-intact: \d+ bytes, 0 differ$', text, re.M) is not None

def ran(client, session):
    text = output(client)
    exit_info = session.get('exit') or {}
    intact_ok = intact(text)
    counted = 'counter=40000 expect=40000' in text
    status = session.get('state') == 'exited' and exit_info.get('kind') == 'status' and exit_info.get('status') == 0
    return status and intact_ok and counted, {'exit': exit_info, 'intact': intact_ok, 'counted': counted}

def mode_step(client):
    table = load(client)
    ident = client.action('set_breakpoint', symbol='seq')['id']
    session = cont(client)
    tid = stopped_tid(session, table['seq'])
    pc = regs(client, tid)['pc']
    check('stop at seq', pc == table['seq'], hex(pc))
    ret = regs(client, tid)['ra']
    client.action('remove_breakpoint', id=ident)
    ok_all = pc == table['seq']
    for current, nxt, name in WALK:
        if regs(client, tid)['pc'] != table[current]:
            check(f'at {current}', False, hex(regs(client, tid)['pc']))
            ok_all = False
            break
        if current == 's_jalr_reg':
            client.action('write_register', tid=tid, name='t1', value=hex(table['sub2'] - 8))
            written = regs(client, tid)['t1'] == table['sub2'] - 8
            check('write t1 = sub2-8 before jalr 8(t1)', written, hex(regs(client, tid)['t1']))
            ok_all = ok_all and written
        before = mem(client, table['code_begin'], table['code_len'])
        parcel = before[table[current] - table['code_begin']]
        session, reply = step(client, tid)
        if session is None:
            check(f'step at {current}', False, reply)
            ok_all = False
            break
        landed = regs(client, tid)['pc']
        want = ret if nxt is None else table[nxt]
        if name:
            length_ok = True
            if name.startswith('2-byte') or 'is +2' in name:
                length_ok = (parcel & 3) != 3 and want == table[current] + 2
            elif name.startswith('4-byte'):
                length_ok = (parcel & 3) == 3 and want == table[current] + 4
            passed = landed == want and length_ok
            check(f'step {name} {hex(table[current])} -> {hex(landed)}', passed, f'want {hex(want)}')
            ok_all = ok_all and passed
        elif landed != want:
            check(f'step {current}', False, f'got {hex(landed)} want {hex(want)}')
            ok_all = False
        after = mem(client, table['code_begin'], table['code_len'])
        if before != after or probes(client):
            check(f'code bytes and probes unchanged at {current}', False, len(probes(client)))
            ok_all = False
        if landed != want:
            break
    check('all 40 instruction steps through seq landed exactly, no leftover probes', ok_all, len(WALK))
    session = finish(client)
    return session

def finish(client):
    session = client.session()
    seen = []
    for _ in range(20):
        if session['state'] == 'exited':
            break
        session = cont(client, skip_signals=False, seconds=60)
        if session['state'] != 'exited':
            seen.append([(thread['tid'], thread.get('reason'), thread.get('signal')) for thread in session['threads'] if thread.get('reason') not in (None, 'none')])
    ok, detail = ran(client, session)
    detail['stops'] = seen
    check('ran to exit', ok, detail)
    return session

def mode_cont(client):
    table = load(client)
    ident = [client.action('set_breakpoint', symbol=name)['id'] for name in PLANTED]
    hits = []
    for expect in HITS:
        session = cont(client)
        if session['state'] != 'stopped':
            break
        tid = stopped_tid(session, table[expect])
        hits.append(regs(client, tid)['pc'])
    want = [table[name] for name in HITS]
    check('continue from each planted 2/4-byte breakpoint, in order', hits == want,
          [hex(item) for item in hits])
    for ident_one in ident:
        client.action('remove_breakpoint', id=ident_one)
    listed = probes(client)
    check('breakpoints removed', not listed, listed)
    session = finish(client)
    text = output(client)
    check('code bytes equal the on-disk image', intact(text), '')
    return session

def mode_lrsc(client):
    table = load(client)
    ident = client.action('set_breakpoint', symbol='s_lr')['id']
    session = cont(client)
    tid = stopped_tid(session, table['s_lr'])
    pc = regs(client, tid)['pc']
    check('stop at lr.w', pc == table['s_lr'], hex(pc))
    before = word(client, table['counter'])
    session, reply = step(client, tid)
    after_pc = regs(client, tid)['pc'] if session is not None else None
    after = word(client, table['counter']) if session is not None else None
    check('step at lr.w runs lr..sc..bnez as one unit',
          session is not None and after_pc == table['s_after_sc'],
          f'pc {None if after_pc is None else hex(after_pc)} want {hex(table["s_after_sc"])} counter {before}->{after} reply {reply if session is None else ""}')
    check('counter incremented exactly once by the unit', after == before + 1, f'{before}->{after}')
    hits = 1
    tids = {tid}
    reasons = {}
    deadline = time.monotonic() + 180
    while hits < 400 and time.monotonic() < deadline:
        session = cont(client, seconds=20)
        if session['state'] != 'stopped':
            break
        at = [thread for thread in session['threads']
              if thread.get('reason') in ('breakpoint', 'interrupt') and thread.get('breakpoint_address') == table['s_lr']]
        if not at:
            for thread in session['threads']:
                if thread.get('reason') in ('breakpoint', 'interrupt') and regs(client, thread['tid'])['pc'] == table['s_lr']:
                    at = [thread]
                    break
        key = tuple(sorted(thread.get('reason') for thread in at))
        reasons[str(key)] = reasons.get(str(key), 0) + 1
        if not at:
            check('unexpected stop', False, [(thread.get('reason'), thread.get('breakpoint_address')) for thread in session['threads']])
            break
        tid = at[0]['tid']
        tids.add(tid)
        if regs(client, tid)['pc'] != table['s_lr']:
            check('unexpected stop', False, hex(regs(client, tid)['pc']))
            break
        hits += 1
    check('400 continues from a planted breakpoint on lr.w, two contending threads',
          hits == 400 and len(tids) >= 2, f'hits {hits} threads {len(tids)} reasons {reasons}')
    client.action('remove_breakpoint', id=ident)
    return finish(client)

def mode_src(client):
    table = load(client)
    placed = client.action('set_breakpoint', file='runtime-riscv64.c', line=LINE_A)
    session = cont(client)
    tid = stopped_tid(session)
    loc = client.inspect('get_source_location', address=hex(regs(client, tid)['pc']))
    check('stopped at LINE_A', loc['source'].get('line') == LINE_A, loc['source'])
    for ident in placed['ids']:
        client.action('remove_breakpoint', id=ident)
    client.action('step_source', tid=tid)
    wait_session(client, 30)
    loc = client.inspect('get_source_location', address=hex(regs(client, tid)['pc']))
    check('F11 step_source LINE_A to next line', loc['source'].get('line') == LINE_B, loc['source'])
    client.action('step_over', tid=tid)
    wait_session(client, 30)
    loc = client.inspect('get_source_location', address=hex(regs(client, tid)['pc']))
    check('F10 step_over to printf', loc['source'].get('line') == LINE_C, loc['source'])
    client.action('step_over', tid=tid)
    wait_session(client, 30)
    loc = client.inspect('get_source_location', address=hex(regs(client, tid)['pc']))
    check('F10 step_over printf to next line', loc['source'].get('line') == LINE_D, loc['source'])
    listed = probes(client)
    check('no leftover probes after source steps', not listed, listed)
    return finish(client)

def mode_sig(client):
    table = load(client)
    ident = client.action('set_breakpoint', symbol='s_sleep_ecall')['id']
    session = cont(client)
    tid = stopped_tid(session, table['s_sleep_ecall'])
    pc = regs(client, tid)['pc']
    check('stop at nanosleep ecall', pc == table['s_sleep_ecall'], hex(pc))
    client.action('remove_breakpoint', id=ident)
    stops = []
    landed = None
    view = None
    for _ in range(5):
        session, reply = step(client, tid)
        if session is None:
            check('step accepted', False, reply)
            break
        view = regs(client, tid)
        thread = [item for item in session['threads'] if item['tid'] == tid][0]
        stops.append((hex(view['pc']), thread.get('reason'), thread.get('signal'), len(probes(client))))
        landed = view['pc']
        if landed == table['s_after_sleep']:
            break
    alarms = word(client, table['alarms']) if view is not None else None
    signal_at_ecall = any(item[1] == 'signal' and item[2] == 14 and num(item[0]) == table['s_sleep_ecall'] for item in stops)
    check('step over ecall ends at pc+4 after SIGALRM',
          landed == table['s_after_sleep'] and signal_at_ecall and table['s_after_sleep'] == table['s_sleep_ecall'] + 4,
          stops)
    check('handler ran exactly once', alarms == 1, alarms)
    a0 = view['a0'] if view is not None else None
    check('nanosleep returned -EINTR in a0', a0 is not None and (a0 & ((1 << 64) - 1)) == (2 ** 64 - 4), None if a0 is None else hex(a0))
    listed = probes(client)
    check('no leftover probes after signal step', not listed, listed)
    return finish(client)

MODES = {'step': mode_step, 'cont': mode_cont, 'lrsc': mode_lrsc, 'src': mode_src, 'sig': mode_sig}
order = ['step', 'cont', 'lrsc', 'src', 'sig'] if args.mode == 'all' else [args.mode]
aborted = False
for name in order:
    client = open_client()
    before = len(results)
    try:
        MODES[name](client)
    except Exception as error:
        aborted = True
        print(f'FAIL {name} exception: {error}', flush=True)
    finally:
        try:
            drain(client)
            client.close()
        except Exception as error:
            aborted = True
            print(f'FAIL {name} close: {error}', flush=True)
    print(f'SUMMARY {name} pass={sum(1 for item in results[before:] if item[1])} fail={sum(1 for item in results[before:] if not item[1])}', flush=True)
passed = sum(1 for item in results if item[1])
failed = len(results) - passed
print(f'SUMMARY all pass={passed} fail={failed}', flush=True)
expect = {'step': 25, 'cont': 4, 'lrsc': 5, 'src': 6, 'sig': 6}
if args.mode == 'all' and not aborted:
    # Counts are the whole run, in order. A short mode shifts the slices, so check totals.
    want = sum(expect.values())
    if passed != want or failed != 0:
        raise SystemExit(f'expected {want} passes, got {passed} pass {failed} fail')
elif failed or aborted:
    raise SystemExit(1)
