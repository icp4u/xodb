#!/usr/bin/env python3
"""Fast live lane: failed return-address rules are distinct from an explicit outermost frame."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time
from client import Client

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', type=Path, required=True)
p.add_argument('--binary', type=Path, default=Path(os.environ.get('XODB_BIN', 'zig-out/bin/xodb')))
p.add_argument('--agent', type=Path)
p.add_argument('--wrong-result', action='store_true', help='expect a false diagnostic; the oracle must reject it')
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
w = a.work.resolve()
w.mkdir(parents=True, exist_ok=True)
started = time.monotonic()

def uleb(value):
    out = []
    while True:
        byte = value & 127
        value >>= 7
        out.append(byte | (128 if value else 0))
        if not value:
            return out

def rule(register, expression):
    return [0x10, register, *uleb(len(expression)), *expression]

# All function bodies execute normally. Only their CFI carries malformed or
# unavailable return-address state; the stop proves we reached the owning row.
cases = [
    ('drop_prefix', rule(16, [0x13]), 'ReturnAddressUnavailable'),
    ('underflow', rule(16, [0x13, 0x13]), 'ReturnAddressUnavailable'),
    ('stack_limit', rule(16, [0x30] * 128), 'ReturnAddressUnavailable'),
    ('invalid_pick', rule(16, [0x15, 255]), 'ReturnAddressUnavailable'),
    ('unsupported_loop', rule(16, [0x2f, 0xfd, 0xff]), 'ReturnAddressUnavailable'),
    ('unreadable_address', rule(16, [0x0e, *[0xff] * 8]), 'ReturnAddressUnavailable'),
    ('partial_scalar', rule(16, [0x30, 0x93, 1]), 'ReturnAddressUnavailable'),
    ('cfa_failure', [0x0f, 3, 0x2f, 0xfd, 0xff], 'UnsupportedLocation'),
    ('explicit_outermost', [0x07, 16], 'outermost'),
    ('non_return_failure', rule(3, [0x13, 0x13]), 'caller'),
    ('valid_return', rule(16, [0x77, 8]), 'caller'),
]
assembly = ['.text']
for name, cfi, _ in cases:
    assembly.append(f'''.globl ra_{name}
.type ra_{name},@function
ra_{name}:
.cfi_startproc
sub $8,%rsp
.cfi_def_cfa_offset 16
.cfi_escape {','.join(map(str, cfi))}
call return_address_stop
nop
add $8,%rsp
.cfi_def_cfa rsp,8
.cfi_restore 16
ret
.cfi_endproc
.size ra_{name},.-ra_{name}
''')
assembly.append('.section .note.GNU-stack,"",@progbits\n')
(w/'rules.S').write_text('\n'.join(assembly))
(w/'main.c').write_text(
    ''.join(f'void ra_{name}(void);\n' for name, _, _ in cases) +
    '__attribute__((noinline)) void return_address_stop(void) { __asm__ volatile("":::"memory"); }\n'
    'int main(void) {\n' + ''.join(f'ra_{name}();\n' for name, _, _ in cases) + 'return 0; }\n')
exe = w/'fixture'
subprocess.run(['cc', '-O1', '-g', '-fomit-frame-pointer', '-o', str(exe), str(w/'main.c'), str(w/'rules.S')], check=True, timeout=30)
subprocess.run([str(exe)], check=True, timeout=10)
frames = subprocess.check_output(['readelf', '--debug-dump=frames', str(exe)], text=True, timeout=30)
assert 'DW_CFA_expression: r16' in frames and 'DW_CFA_undefined: r16' in frames, frames
(w/'frames.txt').write_text(frames)
os.environ['XODB_BIN'] = str(a.binary.resolve())
client = Client('control', str(exe), options=['--runtime-agent', str(a.agent.resolve())] if a.agent else [], reply_seconds=20)
results = []
failures = []
try:
    client.stopped()
    client.action('set_breakpoint', symbol='return_address_stop')
    for name, _, expected in cases:
        client.continue_initial_stop()
        stopped = client.stopped('breakpoint')
        deadline = time.monotonic() + 20
        while True:
            stack = client.inspect('get_stack', tid=stopped['pid'])
            if not any(f.get('diagnostic') == 'DebugMetadataPending' for f in stack['frames']):
                break
            assert time.monotonic() < deadline, 'metadata did not finish'
            time.sleep(.005)
        rows = stack['frames']
        symbols = [f.get('symbol') for f in rows]
        assert symbols[:2] == ['return_address_stop', 'ra_' + name], (name, rows)
        diagnostic = rows[1].get('diagnostic')
        if expected in ('outermost', 'caller'):
            ok = diagnostic is None and (len(rows) == 2 if expected == 'outermost' else 'main' in symbols)
        else:
            if a.wrong_result and name == 'drop_prefix':
                expected = 'IncorrectReturnAddressDiagnostic'
            ok = len(rows) == 2 and diagnostic == expected
        results.append(dict(case=name, expected=expected, diagnostic=diagnostic, frames=len(rows), passed=ok))
        if not ok:
            failures.append(results[-1])
        print(json.dumps(results[-1]), flush=True)
    assert client.session()['state'] == 'stopped'
    client.continue_initial_stop()
finally:
    client.close()
    (w/'transcript.json').write_text(json.dumps(client.transcript, indent=2) + '\n')
    (w/'results.json').write_text(json.dumps(dict(cases=results, failures=failures, seconds=time.monotonic()-started), indent=2) + '\n')
assert not failures, failures
print('return-address diagnostics and explicit outermost control: pass')
