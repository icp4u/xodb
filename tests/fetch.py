#!/usr/bin/env python3
"""xodb --fetch: card structure, JSON, redaction and a tiny benchmark.

Reads this machine, so it asserts structure, never values. Private names
(host, user, kernel, machine model, DMI serials) are read here at test time
and only checked for absence; they are never printed or saved. The
distribution is not private: the card shows it and its logo under --redact.
"""
import json
import os
from pathlib import Path
import pty
import re
import select
import socket
import subprocess
import time

root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = root / '.work' / ('fetch-' + str(time.time_ns())[-8:])
work.mkdir(parents=True)
xodb = str(root / 'zig-out' / 'bin' / 'xodb')
# Benchmark results go to this run's own state directory.
env = dict(os.environ, XDG_STATE_HOME=str(work / 'state'))
env.pop('NO_COLOR', None)
checks = []

def check(name, ok):
    if not ok: raise AssertionError(name)
    checks.append(name)
    print('PASS ' + name, flush=True)

def run(*args, timeout=30):
    done = subprocess.run([xodb, '--fetch', *args], env=env, capture_output=True, text=True, timeout=timeout)
    assert done.returncode == 0, (args, done.returncode, done.stderr[-400:])
    return done.stdout

ORDER = ['OS', 'Host', 'Kernel', 'Uptime', 'Packages', 'Shell', 'Display', 'DE', 'WM', 'Theme', 'Icons', 'Font',
         'Terminal', 'CPU', 'GPU', 'Memory', 'Swap', 'Disk (/)', 'Battery', 'Locale', 'Boost', 'Pressure', 'Temps',
         'Power', 'NVMe', 'Governor', 'Mitigations', 'Scheduler', 'Open files', 'Benchmark']

def keys_of(text):
    lines = text.rstrip('\n').split('\n')
    return lines[0], lines[1], [l.split(': ', 1)[0] for l in lines[2:]]

started = time.monotonic()
plain = run()
title, rule, keys = keys_of(plain)
check('plain output has no escape sequences when not a terminal', '\x1b' not in plain)
check('title is user@host and the rule underlines it', '@' in title and rule == '-' * len(title))
check('every line is "Key: value"', all(': ' in l for l in plain.rstrip('\n').split('\n')[2:]))
check('keys are known and in fastfetch order', all(k in ORDER for k in keys) and [ORDER.index(k) for k in keys] == sorted(ORDER.index(k) for k in keys))
check('the essential lines are present', all(k in keys for k in ('OS', 'Uptime', 'CPU', 'Memory')))
t0 = time.monotonic()
run()
check('the card prints in under two seconds', time.monotonic() - t0 < 2)

doc = json.loads(run('--json'))
check('JSON schema 1 with title, lines and redaction flag', doc['schema'] == 1 and doc['title'] == title and doc['redacted'] is False)
check('JSON lines are the text lines', [l['key'] for l in doc['lines']] == keys)

# Private values of this machine, read now and compared only.
private = set()
for path in ('/proc/sys/kernel/hostname', '/etc/hostname'):
    try: private.add(Path(path).read_text().strip())
    except OSError: pass
private.add(socket.gethostname())
for name in ('USER', 'LOGNAME'):
    if os.environ.get(name): private.add(os.environ[name])
private.add(os.uname().release)
for name in ('product_name', 'board_name', 'product_serial', 'board_serial'):
    try: private.add(Path('/sys/class/dmi/id/' + name).read_text().strip())
    except OSError: pass
private = {p for p in private if p and p not in ('Linux', 'linux', 'user', 'host', 'System Product Name', 'None', 'Default string')}

def leaks(text):
    """Private names in TEXT: as a whole word, or anywhere when long enough."""
    low = text.lower()
    return [p for p in private if re.search(r'(?<![a-z0-9])' + re.escape(p.lower()) + r'(?![a-z0-9])', low) or (len(p) >= 4 and p.lower() in low)]
redacted_text = run('--redact')
redacted_json = run('--redact', '--json')
for label, text in (('text', redacted_text), ('JSON', redacted_json)):
    leaked = leaks(text)
    # Count only: the leaked value itself must not reach a log.
    check(f'--redact {label} shows none of the {len(private)} private names read at test time', not leaked)
    check(f'--redact {label} shows no IPv4 address or MAC', not re.search(r'\b\d{1,3}(\.\d{1,3}){3}\b', text) and not re.search(r'\b[0-9a-f]{2}(:[0-9a-f]{2}){5}\b', text, re.I))
r_title, _, r_keys = keys_of(redacted_text)
check('--redact title is the user@host placeholder', r_title == 'user@host' and json.loads(redacted_json)['redacted'] is True)
check('--redact hides kernel, machine model and theme names', not ({'Kernel', 'Host', 'Theme', 'Icons'} & set(r_keys)))
check('--redact OS line still names the distribution', redacted_text.split('\n')[2] == plain.split('\n')[2])

def on_tty(**extra):
    """The card as a terminal sees it, under these environment changes."""
    leader, follower = pty.openpty()
    proc = subprocess.Popen([xodb, '--fetch'], env={k: v for k, v in dict(env, **extra).items() if v is not None}, stdin=follower, stdout=follower, stderr=subprocess.PIPE)
    os.close(follower)
    data = b''
    while select.select([leader], [], [], 10)[0]:
        try: chunk = os.read(leader, 65536)
        except OSError: break
        if not chunk: break
        data += chunk
    os.close(leader)
    assert proc.wait(timeout=10) == 0, extra
    return data.decode('utf-8', 'replace')

# A truecolor terminal gets 24-bit colour (and the distribution logo when a PNG exists).
utf8 = dict(LC_ALL='C.UTF-8', TERM='xterm-256color')
tty = on_tty(COLORTERM='truecolor', **utf8)
check('a truecolor terminal gets 24-bit colour and colour blocks', '\x1b[1;38;2;' in tty and '\x1b[40m' in tty and '\x1b[107m' in tty)
plain_tty = re.sub(r'\x1b\[[0-9;]*m', '', tty).replace('\r', '')
check('the terminal card has the same keys', all((k + ': ') in plain_tty for k in keys if k != 'Terminal'))
cube = on_tty(COLORTERM=None, **utf8)
check('a 256-colour terminal gets no 24-bit escapes', '\x1b[1;38;5;' in cube and ';2;' not in re.sub(r'\x1b\[(40|10[0-7]|4[0-7])m', '', cube))
basic = on_tty(COLORTERM=None, TERM='linux', LC_ALL='C.UTF-8')
check('a 16-colour terminal gets only basic colour codes', all(re.fullmatch(r'[0-9;]*', m) and all(int(n) < 108 and n not in ('38', '48') for n in m.split(';') if n) for m in re.findall(r'\x1b\[([^m]*)m', basic)))
ascii_only = on_tty(COLORTERM='truecolor', TERM='xterm-256color', LC_ALL='C', LANG=None, LC_CTYPE=None)
check('a non-UTF-8 locale gets no half-block logo', '\u2580' not in ascii_only and '\u2584' not in ascii_only)
check('TERM=dumb and NO_COLOR keep a terminal plain', '\x1b[' not in on_tty(TERM='dumb') and '\x1b[' not in on_tty(NO_COLOR='1', COLORTERM='truecolor'))

# The benchmark with the smallest buffers; results persist with their date.
bench = json.loads(run('--json', '--bench', '--bench-mb', '1', timeout=60))
b = bench['bench']
check('--bench measures SHA-256 one/all cores, memcpy and latency', b and b['sha_one_mbs'] > 0 and b['sha_all_mbs'] > 0 and b['memcpy_gbs'] > 0 and b['latency_ns'] > 0 and b['buffer_mb'] == 1)
check('--bench says how it measured', 'SHA-256' in bench['bench_method'] and 'memcpy' in bench['bench_method'])
check('--bench result is saved in the state directory', (work / 'state' / 'xodb' / 'fetch-bench.json').is_file())
again = json.loads(run('--json'))
check('a later card shows the saved result without re-running', again['bench'] and again['bench']['when'] == b['when'] and again['lines'][-1]['key'] == 'Benchmark')
check('the saved result carries its date', re.search(r'\d{4}-\d\d-\d\d \d\d:\d\d UTC', again['lines'][-1]['value']))
bad = subprocess.run([xodb, '--fetch', '--bench-mb', '0'], env=env, capture_output=True, text=True, timeout=10)
check('--bench-mb out of range is refused', bad.returncode != 0)
help_text = run('--help')
check('--fetch --help prints usage', 'xodb --fetch' in help_text and '--bench-mb' in help_text)

(work / 'results.json').write_text(json.dumps(dict(checks=checks, seconds=time.monotonic() - started), indent=2) + '\n')
print(f'fetch: {len(checks)} passed in {time.monotonic() - started:.2f}s; {work}', flush=True)
