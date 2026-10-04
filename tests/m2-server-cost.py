#!/usr/bin/env python3
"""Server comparison after a shared startup gate; includes a ptrace-only control.

Two repetitions of queue/socket transports, rotating mode order. Artifacts are
fresh .work directories. Only this runner's child processes are inspected.
"""
from datetime import datetime
from pathlib import Path
import json
import os
import subprocess
import time
from client import Client

root = Path(__file__).resolve().parents[1]
os.chdir(root)
run = root / '.work' / ('m2-server-cost-' + datetime.now().strftime('%Y%m%dT%H%M%S%f'))
run.mkdir()
(run / 'tmp').mkdir()
env = dict(os.environ, TMPDIR=str(run / 'tmp'))
subprocess.run(['cc', '-O2', '-g', '-gdwarf-4', '-fno-omit-frame-pointer',
    '-mno-omit-leaf-frame-pointer', '-fno-optimize-sibling-calls', '-Wall', '-Wextra',
    '-Werror', '-pthread', 'tests/workloads/reqserver.c',
    'tests/fixtures/profile-start-gate.c', '-Wl,--wrap=pthread_create,--wrap=pthread_join',
    '-lm', '-o', str(run / 'reqserver')], env=env, check=True)
(run / 'versions.txt').write_text(subprocess.check_output(['cc', '--version'], text=True)
    + subprocess.check_output(['uname', '-a'], text=True))

def cpu(pid):
    fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
    return (int(fields[11]) + int(fields[12])) * 1000 / os.sysconf('SC_CLK_TCK')

def parse(output, prefix):
    return json.JSONDecoder().raw_decode(output[output.index(prefix):])[0]

rows = []
for transport in ('queue', 'socket'):
    for repeat in range(2):
        modes = ('native', 'debugger', 'cpu', 'scheduling')
        # Vary position without making the small comparison nondeterministic.
        modes = modes[repeat:] + modes[:repeat]
        for mode in modes:
            name = f'{transport}-{repeat}-{mode}'
            args = ['--seconds', '2', '--workers', '4', '--clients', '4', '--rate', '4000',
                '--hold', '50000', '--shards', '1', '--transport', transport, '--max-seconds', '15']
            capture, control_cpu, capture_setup_ms = None, None, None
            paused_ns = 0
            if mode == 'native':
                result = subprocess.run([str(run / 'reqserver'), *args], capture_output=True,
                    text=True, timeout=20, env=env)
                assert result.returncode == 0, result
                output = result.stdout + result.stderr
            else:
                client = Client('control', str(run / 'reqserver'), args=args)
                try:
                    bp = client.action('set_breakpoint', symbol='profile_gate_ready')['id']
                    client.action('continue')
                    stopped = client.stopped('breakpoint')
                    assert len([t for t in stopped['threads'] if t['state'] != 'exited']) == 9, stopped
                    client.action('remove_breakpoint', id=bp)
                    address = client.inspect('find_symbol', name='profile_gate_started')['address']
                    started = client.inspect('read_memory', address=address, length=4)
                    assert started['hex'] == '00000000', started
                    # One deliberate long pause proves that startup work cannot
                    # consume the clients' fixed request-time window.
                    if mode == 'debugger' and repeat == 0:
                        time.sleep(.25)
                        paused_ns = 250_000_000
                        assert client.inspect('read_memory', address=address, length=4)['hex'] == '00000000'
                    before = cpu(client.p.pid)
                    if mode in ('cpu', 'scheduling'):
                        setup_start = time.monotonic_ns()
                        capture = client.action('start_profile', frequency_hz=99, duration_ms=5000,
                            context_switch=mode == 'scheduling')['capture']
                        capture_setup_ms = (time.monotonic_ns() - setup_start) / 1_000_000
                    client.action('continue')
                    deadline = time.monotonic() + 10
                    while client.session()['state'] != 'exited':
                        assert time.monotonic() < deadline
                        time.sleep(.025)
                    control_cpu = cpu(client.p.pid) - before
                    final = client.inspect('get_profile')['capture']
                    if capture:
                        capture = final
                        assert capture['status'] == 'target_ended', capture
                        assert capture['lost_records'] == capture['lost_samples'] == 0, capture
                        assert capture['scheduling']['discarded_events'] == capture['scheduling']['invalid_events'] == 0
                        assert capture['stored_samples'] > 0
                        if mode == 'scheduling': assert capture['scheduling']['recorded_events'] > 100
                    else: assert final is None
                finally:
                    (run / f'{name}.rpc.json').write_text(json.dumps(client.transcript, indent=2) + '\n')
                    client.close()
                    output = client.p.stderr.read().decode()
            (run / f'{name}.log').write_text(output)
            workload = parse(output, '{"workload"')
            gate = parse(output, '{"profile_gate"')
            assert gate['created'] == gate['started'] == gate['joined'] == 8, gate
            assert gate['ended_ns'] > gate['released_ns'] > gate['ready_ns'], gate
            assert gate['released_ns'] - gate['ready_ns'] >= paused_ns, gate
            assert not workload['interrupted'] and workload['completed'] > 0, workload
            # Throughput's original elapsed_s includes preparation. Supply a
            # separate interval from gate release to the last worker join.
            active_ns = gate['ended_ns'] - gate['released_ns']
            row = dict(transport=transport, repeat=repeat, mode=mode, workload=workload,
                gate=gate, active_ns=active_ns,
                active_throughput=workload['completed'] * 1e9 / active_ns,
                debugger_cpu_ms=control_cpu, capture_setup_ms=capture_setup_ms, capture=capture)
            rows.append(row)
            (run / f'{name}.json').write_text(json.dumps(row, indent=2) + '\n')
            print(name, 'p99_us', workload['latency_us']['p99'], 'xodb_cpu_ms', control_cpu,
                'samples', capture['stored_samples'] if capture else None,
                'completed', workload['completed'], 'drops', workload['dropped'], flush=True)
        group = [r for r in rows if r['transport'] == transport and r['repeat'] == repeat]
        # Seeded open-loop arrival schedules must offer exactly the same work
        # even after the intentionally prolonged debugger preparation pause.
        assert len({r['workload']['sent'] for r in group}) == 1, group
        assert all(r['workload']['completed'] + r['workload']['dropped'] == r['workload']['sent'] for r in group)
(run / 'results.json').write_text(json.dumps(rows, indent=2) + '\n')
print(f'Gated server artifacts: {run}', flush=True)
