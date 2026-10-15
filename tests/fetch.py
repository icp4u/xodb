#!/usr/bin/env python3
"""xodb --fetch: card structure, JSON, redaction and a tiny benchmark.

Reads this machine, so it asserts structure, never values. Private names
(host, user, kernel, machine model, DMI serials) are read here at test time
and only checked for absence; they are never printed or saved. Under
--redact the identity lines are mad-libs (a retro system's OS, kernel and
logo, a fake shell, theme, icons, uptime, packages and network); they are
checked against the tables in src/ui/overview/fetch.zig, parsed here.
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
         'Power', 'NVMe', 'Governor', 'Network', 'Scheduler', 'Open files', 'Benchmark']

# The mad-lib tables, from the source.
src = (root / 'src/ui/overview/fetch.zig').read_text()
RETRO = {}
for os_name, kernel, logo in re.findall(r'\.os = "([^"]+)", \.kernel = "([^"]+)",.*?\.logo = &\.\{\n(.*?)\n\s*\} \}', src, re.S):
    RETRO[os_name] = (kernel, [json.loads(r.strip().rstrip(',')) for r in logo.split('\n')])
def word_list(name):
    return re.findall(r'"([^"]+)"', re.search(r'pub const ' + name + r' = \[_\]\[\]const u8\{([^}]*)\}', src).group(1))
IKEA, POP = word_list('ikea'), word_list('pop')
assert len(RETRO) >= 8 and IKEA and POP

def values(text):
    return dict(l.split(': ', 1) for l in text.rstrip('\n').split('\n')[2:])

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
check('there is no Mitigations line', 'Mitigations' not in plain)
NET = r'in ([\d.]+) ([KMGTP]?i?B), ([\d.]+)((?: [kMGT])?) pkts · out ([\d.]+) ([KMGTP]?i?B), ([\d.]+)((?: [kMGT])?) pkts \(total since boot\)'
def net_values(line):
    """Bytes in, packets in, bytes out, packets out from a Network line."""
    g = re.fullmatch(NET, line).groups()
    b = lambda v, u: float(v) * 1024 ** ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB'].index(u)
    n = lambda v, u: float(v) * 1000 ** ['', ' k', ' M', ' G', ' T'].index(u)
    return b(g[0], g[1]), n(g[2], g[3]), b(g[4], g[5]), n(g[6], g[7])
def proc_net_dev():
    """The same sums, straight from /proc/net/dev (physical: has a device link)."""
    t = [0, 0, 0, 0]
    for l in open('/proc/net/dev').read().split('\n')[2:]:
        if ':' not in l: continue
        name, v = l.split(':', 1)
        if not os.path.exists(f'/sys/class/net/{name.strip()}/device'): continue
        v = [int(x) for x in v.split()]
        t = [t[0] + v[0], t[1] + v[1], t[2] + v[8], t[3] + v[9]]
    return t
net = values(plain).get('Network')
before = proc_net_dev()
fresh = values(run()).get('Network')
after = proc_net_dev()
if any(before):
    check('the Network line is the totals since boot over physical links (/proc/net/dev)', fresh and all(lo * 0.99 - 1 <= v <= hi * 1.01 + 1 for v, lo, hi in zip(net_values(fresh), before, after)))
else:
    check('no physical link, no Network line', net is None)
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
check('--redact hides the machine model and font', not ({'Host', 'Font'} & set(r_keys)))
check('--redact text and JSON have no Mitigations line', 'Mitigations' not in redacted_text and 'Mitigations' not in redacted_json)
rv = values(redacted_text)
check('--redact OS is a retro system from the table, its kernel the matching one', rv['OS'] in RETRO and rv.get('Kernel') == RETRO[rv['OS']][0])
check('--redact shell is 3rdseashell', rv['Shell'] == '3rdseashell')
up = dict((u.rstrip('s'), int(n)) for n, u in re.findall(r'(\d+) (day|hour|min)s?', rv['Uptime']))
check('--redact uptime is under ten years', 0 < up.get('day', 0) < 3650)
check('--redact packages is a made-up count', re.fullmatch(r'\d+ \(floppies\)', rv['Packages']))
pv = values(plain)
check('--redact theme is a made-up name with the toolkit suffix (when there is a theme)', ('Theme' in pv) == ('Theme' in rv) and ('Theme' not in rv or (rv['Theme'].endswith(' [GTK3]') and rv['Theme'][:-7] in IKEA)))
check('--redact icons are a pop icon (when there are icons)', ('Icons' in pv) == ('Icons' in rv) and ('Icons' not in rv or rv['Icons'][:-7] in POP))
check('--redact Network line has made-up totals', re.fullmatch(NET, rv.get('Network', '')) and rv['Network'] != net)
check('--redact JSON lines are the text lines', [l['key'] for l in json.loads(redacted_json)['lines']] == r_keys)

def on_tty(*args, **extra):
    """The card as a terminal sees it, under these environment changes."""
    leader, follower = pty.openpty()
    proc = subprocess.Popen([xodb, '--fetch', *args], env={k: v for k, v in dict(env, **extra).items() if v is not None}, stdin=follower, stdout=follower, stderr=subprocess.PIPE)
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
r_tty = re.sub(r'\x1b\[[0-9;]*m', '', on_tty('--redact', COLORTERM='truecolor', **utf8)).replace('\r', '')
r_os = re.search(r'OS: (.*)', r_tty).group(1).strip()
check('--redact in a terminal draws the matching retro ASCII logo, not the distribution PNG', r_os in RETRO and all(row in r_tty for row in RETRO[r_os][1]) and '\u2580' not in r_tty and not leaks(r_tty))
check('TERM=dumb and NO_COLOR keep a terminal plain', '\x1b[' not in on_tty(TERM='dumb') and '\x1b[' not in on_tty(NO_COLOR='1', COLORTERM='truecolor'))

# The benchmark with the smallest buffers; results persist with their date.
bench = json.loads(run('--json', '--bench', '--bench-mb', '1', timeout=60))
b = bench['bench']
check('--bench measures SHA-256 one/all cores, memcpy and latency', b and b['sha_one_mbs'] > 0 and b['sha_all_mbs'] > 0 and b['memcpy_gbs'] > 0 and b['latency_ns'] > 0 and b['buffer_mb'] == 1)
check('--bench says how it measured', 'SHA-256' in bench['bench_method'] and 'memcpy' in bench['bench_method'])
check('--bench result is saved in the state directory', (work / 'state' / 'xodb' / 'fetch-bench.json').is_file())
again = json.loads(run('--json'))
check('a later card shows the saved result without re-running', again['bench'] and again['bench']['when'] == b['when'] and again['lines'][-1]['key'] == 'Benchmark')
check('the saved result carries its date', isinstance(again['bench'].get('when'), int) and again['bench']['when'] > 0)
bad = subprocess.run([xodb, '--fetch', '--bench-mb', '0'], env=env, capture_output=True, text=True, timeout=10)
check('--bench-mb out of range is refused', bad.returncode != 0)
help_text = run('--help')
check('--fetch --help prints usage', 'xodb --fetch' in help_text and '--bench-mb' in help_text)

(work / 'results.json').write_text(json.dumps(dict(checks=checks, seconds=time.monotonic() - started), indent=2) + '\n')
print(f'fetch: {len(checks)} passed in {time.monotonic() - started:.2f}s; {work}', flush=True)
