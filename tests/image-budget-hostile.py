#!/usr/bin/env python3
"""Full-image budgets against a target that chooses its own files.
Run: python3 tests/image-budget-hostile.py --work out/image-budget-hostile [--only lookup,total,...]
Every large file is a hole or a few kilobytes of headers, so nothing large
is written to disk; the debugger still reads what the headers claim.
  lookup   a name lookup reads at most the main executable in full, however
           many images refuse the symbols-only view; the stopped frame's image
           still loads
  total    one process-wide total across a session and a capture; a file both
           hold is one copy
  phantom  a compressed section that declares much and inflates nothing does
           not keep the budget from an honest image
  sections many sections sharing one long name are refused, promptly
  pending  a symbols-only reader that fails for good ends find_symbol
  path     a long path is cut between characters; control characters do not
           reach the reply or the terminal
  container libraries inside a container (an APK) are read by a name lookup
           only within fixed bounds, whatever the image budgets are
  core     a core's images have no symbols-only view either: a name lookup
           reads them within the same bounds, and a stack frame still loads
  definers a language view that finds its runtime's symbol in many large
           libraries reads none of them in full; a small one still loads
  forks    a followed child that execs another large program does not read
           it in full for a breakpoint it only inherited; asking in the
           child does
  mappings a file mapped thousands of times is still placed and named; only
           real work is refused, and the refusal is listed
  refused  a symbols-only view refused after its reader finished stays refused
  defaults 256 MiB an image and 512 MiB in all unless asked; the refusal says
           what to rerun with, and rerun with exactly that the image loads
  optin    with larger budgets asked for, a 1 GiB image loads
  starve   a search for a source line reads every mapped image, but never so
           much that the frame the thread is stopped in cannot load; what it
           left unread is counted and named in the reply
  starvecap the same for the start of a CPU capture
  linefirst a source line is answered in time linear in the mappings, however
           often one file is mapped; too many addresses is a typed refusal
  tabs     a language tab refused for a budget is looked at again once a
           stack loads the image; the refusal says whether a stack can
  views    the Lua, Ruby, Go and Emacs Lisp views read the main executable
           and nothing else
  restore  a saved breakpoint is restored after a restart by reading the one
           image it is in
Cases run with the default budgets unless they say otherwise; OPTIN is the
larger pair a user may ask for.
--wrong-result expects the lookup to read every image and must fail."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import re
import runpy
import struct
import subprocess
import time
from client import Client

MIB = 1 << 20
BIG = 300 * MIB
OPTIN = ('--image-limit', '2G', '--image-total-limit', '8G')
SHF_COMPRESSED = 0x800
HOST = r'''
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
__attribute__((noinline)) int exe_marker(int n) { __asm__ volatile("" ::: "memory"); return n + 1; }
int main(int argc, char **argv) {
    int (*wait)(int) = 0;
    int (*call)(int (*)(int), int) = 0;
    for (int i = 1; i < argc; i++) {
        void *h = dlopen(argv[i], RTLD_NOW | RTLD_LOCAL);
        if (!h) { fprintf(stderr, "dlopen %s: %s\n", argv[i], dlerror()); return 2; }
        if (i == 1) wait = (int (*)(int))dlsym(h, "probe_wait");
        if (i == 2) call = (int (*)(int (*)(int), int))dlsym(h, "probe_call");
    }
    if (!wait) return 3;
    puts("ready");
    fflush(stdout);
    /* CHAIN: argv[2]'s probe_call calls argv[1]'s probe_wait, so both are on the stack */
    if (getenv("CHAIN") && call) return call(wait, 0) < 0;
    return wait(exe_marker(-1)) < 0;
}
'''
LIB = r'''
#include <unistd.h>
__attribute__((noinline)) int probe_wait(int fd) {
    char byte;
    return (int)read(fd, &byte, 1);
}
__attribute__((noinline)) int probe_call(int (*function)(int), int fd) {
    int result = function(fd);
    __asm__ volatile("" ::: "memory");
    return result;
}
'''
SHDR = '<IIQQQQIIQQ'
FIELDS = ('name', 'type', 'flags', 'addr', 'offset', 'size', 'link', 'info', 'align', 'entsize')


class Elf:
    """Minimal in-place ELF64 little-endian section-header editor."""
    def __init__(self, path):
        self.b = bytearray(Path(path).read_bytes())
        self.shoff, = struct.unpack_from('<Q', self.b, 40)
        self.shnum, self.shstrndx = struct.unpack_from('<HH', self.b, 60)
        names = self.sh(self.shstrndx)
        self.names = bytes(self.b[names['offset']:names['offset'] + names['size']])
    def sh(self, i):
        return dict(zip(FIELDS, struct.unpack_from(SHDR, self.b, self.shoff + 64 * i)))
    def index(self, name):
        for i in range(self.shnum):
            at = self.sh(i)['name']
            if self.names[at:self.names.index(b'\0', at)].decode() == name: return i
        raise KeyError(name)
    def set(self, name, **fields):
        i = self.index(name); h = self.sh(i); h.update(fields)
        struct.pack_into(SHDR, self.b, self.shoff + 64 * i, *(h[k] for k in FIELDS))
    def hole(self):
        return (len(self.b) + 4095) & ~4095
    def save(self, path, size=None):
        path = Path(path); path.write_bytes(self.b)
        if size: os.truncate(path, size)
        os.chmod(path, 0o755)
        return path


def oversized_symbols(source, path, size=BIG):
    """A symbol table the symbols-only reader refuses: 240 MiB of hole."""
    e = Elf(source); e.set('.symtab', offset=e.hole(), size=240 * MIB)
    return e.save(path, size)


class Run:
    """One target and one debugger attached to it."""
    def __init__(self, w, program, libs, options=(), env=None):
        self.target = subprocess.Popen([str(program), *map(str, libs)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1, env={**os.environ, **(env or {})})
        self.client = None
        try:
            assert self.target.stdout.readline() == 'ready\n', self.target.stderr.read()
            self.tid = self.target.pid
            self.client = Client('control', None, options=['--attach', str(self.tid), *options], reply_seconds=30)
            self.session = self.client.stopped(seconds=30)
        except BaseException:
            self.kill(); raise
    def stack(self):
        deadline = time.monotonic() + 30
        while True:
            found = self.client.inspect('get_stack', generation=self.session['generation'], tid=self.tid)
            if not any(f['diagnostic'] == 'DebugMetadataPending' for f in found['frames']): return found
            assert time.monotonic() < deadline, found
            time.sleep(.005)
    def symbol(self, name, calls=2000):
        """(reply, calls): the first reply that is not Pending."""
        for n in range(1, calls + 1):
            reply = self.client.tool('find_symbol', name=name)['result']
            if not reply.get('isError') or reply['content'][0]['text'] != 'SymbolDiscoveryPending': return reply, n
            time.sleep(.005)
        raise AssertionError(f'find_symbol {name} still pending after {calls} calls')
    def modules(self):
        return self.client.inspect('list_modules', limit=1)
    def held(self):
        # A tree without the process-wide total has no such field: report
        # what it holds as unknown so the cases fail on what they measure.
        return self.modules().get('image_bytes') or {'held': -1, 'peak': -1, 'total_limit': -1, 'image_limit': -1}
    def peak_rss(self):
        return resident(self.client)
    def holds(self, low, high):
        return holds(self.client, low, high)
    def close(self):
        """Close stdin; the debugger must leave promptly. Returns its stderr."""
        t = time.monotonic()
        self.client.p.stdin.close()
        err = self.client.p.stderr.read()
        assert self.client.p.wait(timeout=10) == 0, err
        self.client = None; self.kill()
        return err, time.monotonic() - t
    def kill(self):
        if self.client and self.client.p.poll() is None: self.client.p.kill(); self.client.p.wait()
        if self.target.poll() is None: self.target.kill(); self.target.wait()


def shut(client):
    """End of input: the debugger leaves and takes the target it launched with it."""
    if client.p.poll() is not None: return
    client.p.stdin.close()
    try: client.p.wait(timeout=10)
    except subprocess.TimeoutExpired: client.p.kill(); client.p.wait()


def resident(client):
    """Peak resident bytes of the debugger: what it read, whatever it reports."""
    for line in Path(f'/proc/{client.p.pid}/status').read_text().splitlines():
        if line.startswith('VmHWM:'): return int(line.split()[1]) * 1024
    raise AssertionError('no VmHWM')


def holds(client, low, high, slack=128 * MIB, **route):
    """The debugger holds between `low` and `high` bytes of images: by what it
    reports, and by its resident memory, which is what it read whatever it
    reports. A tree without the reported figure is judged on memory alone."""
    figures = client.inspect('list_modules', limit=1, **route).get('image_bytes')
    if figures: assert low <= figures['held'] <= high and figures['peak'] <= high, (figures, low, high)
    rss = resident(client)
    assert low <= rss < high + slack, (rss, low, high)
    return figures['held'] if figures else rss


def load_failures(client):
    """Every load failure. They follow the last page of mappings: go straight to them."""
    page = client.inspect('list_modules', limit=1)
    if not page['total_load_failures']: return []
    cursor = next(v for v in page.values() if isinstance(v, str) and v.startswith('1:')).split(':')
    return client.inspect('list_modules', cursor=':'.join([*cursor[:2], str(page['total_regions']), '0']))['load_failures']


def errors(reply):
    assert reply.get('isError'), reply
    texts = [c['text'] for c in reply['content']]
    assert all(isinstance(t, str) for t in texts), reply  # a cut UTF-8 sequence would arrive as numbers
    return texts


def named(found, symbol):
    return next((f for f in found['frames'] if f['symbol'] == symbol), None)


def lookup(w, a, result):
    count = 8
    plain = w/'lk_ok.so'
    libs = [oversized_symbols(plain, w/f'lk{i}.so') for i in range(count)]
    program = oversized_symbols(w/'host', w/'lk_host')  # exe_marker stays in .dynsym
    try:
        r = Run(w, program, libs, options=OPTIN)
        try:
            # Attaching, and the automatic language probes with it, read no image in full.
            r.holds(0, 0)
            # A name the caller asked for may read the main executable in full, and only it.
            reply, _ = r.symbol('exe_marker')
            assert not reply.get('isError') and reply['structuredContent']['name'] == 'exe_marker', reply
            r.holds(BIG, BIG)
            # A name that is nowhere: none of the eight libraries is read to look.
            for name in ('xodb_no_such_symbol', 'xodb_no_such_symbol_2'):
                reply, _ = r.symbol(name)
                texts = errors(reply)
                assert texts[0] == 'ImageBudgetExceeded' and 'symbol tables too large to search by name' in texts[1] and '/lk' in texts[1], reply
            r.holds((count + 1) * BIG, (count + 1) * BIG) if a.wrong_result else r.holds(BIG, BIG)
            # The frame the thread is stopped in still loads, with source.
            found = r.stack()
            frame = named(found, 'probe_wait')
            assert frame and frame['source'] and frame['diagnostic'] is None and found['image_budget'] is None, found
            held = r.holds(2 * BIG, 2 * BIG)  # the executable and the frame's image
            # A loaded image is searched for free.
            reply, _ = r.symbol('probe_call')
            assert not reply.get('isError') and reply['structuredContent']['module_id'] == frame['module_id'], reply
            r.holds(2 * BIG, 2 * BIG)
            result['lookup'] = {'images': count + 1, 'image_bytes': BIG, 'held_bytes': held, 'peak_rss_bytes': r.peak_rss()}
            r.close()
        finally:
            r.kill()
        # --break on a missing name at attach: the stopped frame is not starved.
        r = Run(w, program, libs, options=(*OPTIN, '--break', 'xodb_no_such_symbol'))
        try:
            r.holds(0, BIG)  # at most the executable
            frame = named(r.stack(), 'probe_wait')
            assert frame and frame['source'] and frame['diagnostic'] is None, frame
            result['lookup']['break_peak_bytes'] = r.holds(2 * BIG, 2 * BIG)
            r.close()
        finally:
            r.kill()
    finally:
        for lib in (*libs, program): lib.unlink(missing_ok=True)


def total(w, a, result):
    size = 257 * MIB
    one, two = w/'tt1.so', w/'tt2.so'
    for lib in (one, two): lib.write_bytes((w/'lk_ok.so').read_bytes()); os.truncate(lib, size)
    try:
        # Room for both images once, not for a second copy of either.
        limit = 3 * size - MIB
        r = Run(w, w/'host', [one, two], options=('--image-limit', '1G', '--image-total-limit', str(limit)), env={'CHAIN': '1'})
        try:
            found = r.stack()
            assert named(found, 'probe_wait') and named(found, 'probe_call') and found['image_budget'] is None, found
            session_bytes = r.held()['held']
            assert 2 * size <= session_bytes <= limit, session_bytes
            # A capture of the same process holds the same files: one copy, charged once.
            opened = r.client.inspect('start_profile', generation=r.session['generation'], duration_ms=60000, frequency_hz=99, tids=[r.tid])['capture']
            history = r.client.inspect('get_profile')['capture']['mapping_history']
            assert history['snapshot_bytes'] >= 2 * size, history  # the probe saw the capture hold both
            spent = r.held()
            assert spent['total_limit'] == limit and spent['peak'] <= limit, spent
            assert spent['held'] < session_bytes + history['snapshot_bytes'], (spent, history)
            assert spent['held'] < 2 * size + 64 * MIB, spent  # the capture added only small system images
            rss = r.peak_rss()
            assert rss < limit + 128 * MIB, rss
            r.client.inspect('stop_profile', generation=r.client.session()['generation'], capture_id=opened['id'])
            result['total'] = {'limit_bytes': limit, 'session_bytes': session_bytes, 'capture_bytes': history['snapshot_bytes'], 'held_bytes': spent['held'], 'peak_bytes': spent['peak'], 'peak_rss_bytes': rss}
            r.close()
        finally:
            r.kill()
        # With room for one image, the second is refused whoever asks, and the total holds.
        limit = size + 32 * MIB
        r = Run(w, w/'host', [one, two], options=('--image-limit', '1G', '--image-total-limit', str(limit)), env={'CHAIN': '1'})
        try:
            found = r.stack()
            assert named(found, 'probe_wait') and not named(found, 'probe_call') and found['image_budget'], found
            assert 'left of the' in found['image_budget'] and '/tt2.so is 257 MiB' in found['image_budget'], found
            opened = r.client.inspect('start_profile', generation=r.session['generation'], duration_ms=60000, frequency_hz=99, tids=[r.tid])['capture']
            history = r.client.inspect('get_profile')['capture']['mapping_history']
            assert size <= history['snapshot_bytes'] < 2 * size, history
            spent = r.held()
            assert size <= spent['held'] <= limit and spent['peak'] <= limit, spent
            assert r.peak_rss() < limit + 128 * MIB
            r.client.inspect('stop_profile', generation=r.client.session()['generation'], capture_id=opened['id'])
            result['total']['refused'] = found['image_budget'].replace(str(w), '.')
            r.close()
        finally:
            r.kill()
    finally:
        for lib in (one, two): lib.unlink(missing_ok=True)


def phantom(w, a, result):
    packed = w/'ph_ok.so'
    subprocess.run(['cc', '-g', '-gz=zlib', '-O1', '-fno-optimize-sibling-calls', '-shared', '-fPIC', str(w/'lib.c'), '-o', str(packed)], check=True, timeout=60)
    honest = w/'ph_honest.so'; honest.write_bytes(packed.read_bytes()); os.truncate(honest, MIB)
    # .debug_info declares nearly the whole 2 GiB total; its stream is the real, tiny one.
    e = Elf(packed); h = e.sh(e.index('.debug_info'))
    assert h['flags'] & SHF_COMPRESSED, h
    struct.pack_into('<Q', e.b, h['offset'] + 8, (2 << 30) - 600 * 1024)
    liar = e.save(w/'ph_liar.so')
    # probe_wait is in the liar and is read first; probe_call is in the honest image.
    r = Run(w, w/'host', [liar, honest], options=('--image-limit', '2G', '--image-total-limit', '2G'), env={'CHAIN': '1'})
    try:
        found = r.stack()
        inner, outer = named(found, 'probe_wait'), named(found, 'probe_call')
        assert inner and inner['inline_diagnostic'] and not inner['source'], found  # the probe saw the lie fail to inflate
        assert outer and outer['source'] and outer['diagnostic'] is None, found
        spent = r.held()
        assert spent['held'] < 16 * MIB, spent  # what exists, not what was declared
        assert spent['peak'] > 1 << 30, spent  # the declared size was reserved while it was tried
        result['phantom'] = {'held_bytes': spent['held'], 'peak_bytes': spent['peak'], 'liar_frame': inner['inline_diagnostic']}
        r.close()
    finally:
        r.kill()


def sections(w, a, result):
    size = 257 * MIB
    plain = w/'sc_ok.so'; plain.write_bytes((w/'lk_ok.so').read_bytes()); os.truncate(plain, size)
    r = Run(w, w/'host', [plain], options=OPTIN)
    try:
        t = time.monotonic(); found = r.stack(); honest = time.monotonic() - t
        assert named(found, 'probe_wait'), found
        r.close()
    finally:
        r.kill(); plain.unlink(missing_ok=True)
    # 20,000 sections whose names all start at byte 0 of a 64 MiB table with one NUL, at its end.
    count, table = 20000, 64 * MIB
    e = Elf(w/'lk_ok.so')
    names_at = e.hole(); e.b += bytes(names_at - len(e.b)) + b'A' * 4096  # the rest of the table is written sparsely below
    table_at = (names_at + table + 4095) & ~4095
    struct.pack_into('<Q', e.b, 40, table_at)
    struct.pack_into('<HH', e.b, 60, 0, 1)  # count in section 0; names are section 1
    lib = e.save(w/'sc_bad.so', size)
    with open(lib, 'r+b') as f:
        # One byte per page keeps the table free of NULs without writing it all.
        f.seek(names_at); f.write(b'A' * (table - 1) + b'\0')
        f.seek(table_at); f.write(struct.pack(SHDR, 0, 0, 0, 0, 0, count, 0, 0, 0, 0)); f.write(struct.pack(SHDR, 0, 3, 0, 0, names_at, table, 0, 0, 1, 0))
    try:
        r = Run(w, w/'host', [lib], options=OPTIN)
        try:
            t = time.monotonic(); found = r.stack(); seconds = time.monotonic() - t
            assert any(f['diagnostic'] == 'TableLimit' for f in found['frames']) and not named(found, 'probe_wait'), found
            # Unbounded, this walk is 20,000 scans of 64 MiB: minutes. Reading the file is the honest cost.
            assert seconds < max(1.0, 10 * honest), (seconds, honest)
            _, leave = r.close()
            result['sections'] = {'refused_seconds': round(seconds, 3), 'honest_seconds': round(honest, 3), 'exit_seconds': round(leave, 3)}
        finally:
            r.kill()
    finally:
        lib.unlink(missing_ok=True)


def pending(w, a, result):
    size = 257 * MIB
    e = Elf(w/'lk_ok.so'); struct.pack_into('<Q', e.b, 40, size + 64)  # section table past the end
    lib = e.save(w/'pd.so', size)
    try:
        r = Run(w, w/'host', [lib])
        try:
            answers = {}
            for name in ('xodb_no_such_symbol', 'probe_wait'):
                reply, calls = r.symbol(name, calls=400)
                answers[name] = {'calls': calls, 'error': errors(reply)[0]}
                assert answers[name]['error'] != 'SymbolDiscoveryPending'
            result['pending'] = answers
            r.close()
        finally:
            r.kill()
    finally:
        lib.unlink(missing_ok=True)


def path(w, a, result):
    # 512 bytes is where the path is cut: put a three-byte character across it
    # and an escape sequence in the file name.
    pad = 450 - len(os.fsencode(str(w))) - 3
    assert pad >= 2, 'work directory path too long for this case'
    deep = w/('d' * (pad // 2))/('e' * (pad - pad // 2)); deep.mkdir(parents=True, exist_ok=True)
    stem = str(deep) + '/'
    lib = Path(stem + 'p' * (507 - len(os.fsencode(stem))) + '€' + 'q' * 20 + '\x1b[31m.so')
    raw = os.fsencode(str(lib))
    assert len(raw) > 512 and raw[507:510] == '€'.encode(), len(raw)  # the cut falls inside it
    lib.write_bytes((w/'lk_ok.so').read_bytes()); os.truncate(lib, 2 * MIB)
    try:
        r = Run(w, w/'host', [lib], options=('--image-limit', '1M'))
        try:
            found = r.stack()
            notice = found['image_budget']
            assert isinstance(notice, str) and notice.endswith('... is 2 MiB; image budget 1 MiB; rerun with --image-limit 100M or set symbols.image_bytes'), found
            assert notice.startswith(stem) and len(notice.encode()) < 512 + 288 and not any(ord(ch) < 32 or 127 <= ord(ch) < 160 for ch in notice), notice
            page = r.client.inspect('list_modules', limit=512)
            assert page['image_budget'] == notice, page['image_budget']
            texts = errors(r.symbol('xodb_no_such_symbol')[0])
            assert texts == ['ImageBudgetExceeded', notice], texts
            err, _ = r.close()
            line = next(l for l in err.split(b'\n') if b'module budget:' in l)
            assert line.endswith(notice.encode()) and b'\x1b' not in line, line
            result['path'] = {'path_bytes': len(raw), 'notice_bytes': len(notice.encode())}
        finally:
            r.kill()
        # A short name keeps its characters; only the control bytes change.
        short = w/'café\x1b[2J.so'
        short.write_bytes((w/'lk_ok.so').read_bytes()); os.truncate(short, 2 * MIB)
        try:
            r = Run(w, w/'host', [short], options=('--image-limit', '1M'))
            try:
                notice = r.stack()['image_budget']
                assert notice == f'{w}/café?[2J.so is 2 MiB; image budget 1 MiB; rerun with --image-limit 100M or set symbols.image_bytes', notice
                err, _ = r.close()
                assert b'\x1b' not in next(l for l in err.split(b'\n') if b'module budget:' in l), err
            finally:
                r.kill()
        finally:
            short.unlink(missing_ok=True)
    finally:
        lib.unlink(missing_ok=True)


def sparse_apk(path, files, size):
    """A stored ZIP whose library entries are `size` bytes each: the file's
    bytes, then a hole. Returns each entry's data offset."""
    offsets, central = [], b''
    with open(path, 'xb') as f:
        for name, file in files:
            name = ('lib/x86_64/' + name).encode()
            extra = bytes((-(f.tell() + 30 + len(name))) % 16384)
            at = f.tell()
            fields = (20, 0, 0, 0, 0, 0, size, size, len(name), len(extra))
            f.write(struct.pack('<IHHHHHIIIHH', 0x04034b50, *fields) + name + extra)
            offsets.append(f.tell())
            f.write(file.read_bytes()); f.seek(offsets[-1] + size)
            central += struct.pack('<IHHHHHHIIIHHHHHII', 0x02014b50, 20, *fields, 0, 0, 0, 0, at) + name + extra
        at = f.tell(); f.write(central)
        f.write(struct.pack('<IHHHHIIH', 0x06054b50, 0, 0, len(files), len(files), len(central), at, 0))
    return offsets


def container(w, a, result):
    apk = runpy.run_path('tests/apk/check.py')
    run = w/'apk'; run.mkdir()
    apk['build'](run)
    result['container'] = {}
    for label, size in (('plain', 0), ('padded', BIG)):
        archive = run/(label + '.apk')
        files = [(n + '.so', run/(n + '.so')) for n in ('left', 'right')]
        offsets = sparse_apk(archive, files, size) if size else apk['pack'](archive, files)
        c = Client('control', str(run/'loader'), args=[str(archive), *map(str, offsets)], options=('--break', 'fixture_ready'), reply_seconds=30)
        try:
            c.continue_initial_stop(); c.stopped('breakpoint', seconds=30)
            def find(name):
                for _ in range(2000):
                    reply = c.tool('find_symbol', name=name)['result']
                    if not reply.get('isError') or reply['content'][0]['text'] != 'SymbolDiscoveryPending': return reply
                    time.sleep(.005)
                raise AssertionError('find_symbol still pending')
            missing = find('xodb_no_such_symbol')
            if size:
                # Neither library is read, by the pending --break or by the request.
                held = holds(c, 0, 0)
                texts = errors(missing)
                assert texts[0] == 'ImageBudgetExceeded' and '/padded.apk is 300 MiB and has no symbols-only view' in texts[1] and '256 MiB each, 512 MiB per process' in texts[1], texts
                assert errors(find('apk_left_tick'))[0] == 'ImageBudgetExceeded'
            else:
                # Within the bounds both are read and searched, as before.
                assert errors(missing) == ['SymbolNotFound'], missing
                held = holds(c, 0, MIB)
                found = [find('apk_' + n + '_tick') for n in ('left', 'right')]
                assert not any(r.get('isError') for r in found) and found[0]['structuredContent']['module_id'] != found[1]['structuredContent']['module_id'], found
            result['container'][label] = {'entry_bytes': size or files[0][1].stat().st_size, 'held_bytes': held}
        finally:
            archive.unlink(missing_ok=True)
            shut(c)


def core(w, a, result):
    lib = w/'co.so'; lib.write_bytes((w/'lk_ok.so').read_bytes()); os.truncate(lib, BIG)
    dump = w/'co.core'
    # gdb stops the owned host inside the library and writes the core; nothing is signalled.
    command = ['gdb', '-nx', '-nh', '-batch', '-iex', 'set auto-load safe-path /nonexistent', '-ex', 'set debuginfod enabled off', '-ex', 'set confirm off',
               '-ex', 'set breakpoint pending on', '-ex', 'break probe_wait', '-ex', 'run', '-ex', 'generate-core-file ' + str(dump), '-ex', 'kill', '--args', str(w/'host'), str(lib)]
    with (w/'co.gdb.txt').open('w') as log:
        p = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try: assert p.wait(timeout=45) == 0, (w/'co.gdb.txt').read_text()
        finally:
            if p.poll() is None: os.killpg(p.pid, 9); p.wait()
    assert dump.exists(), (w/'co.gdb.txt').read_text()
    try:
        # Default budgets. A name that is nowhere: the small images are read
        # and searched, the large one is not.
        c = Client('observe', None, options=('--core', str(dump)), reply_seconds=30)
        try:
            errors(c.tool('find_symbol', name='xodb_no_such_symbol')['result'])
            refusals = [f.get('detail') or '' for f in load_failures(c) if f['path'].endswith('/co.so')]
            assert len(refusals) == 1 and '/co.so is 300 MiB and has no symbols-only view' in refusals[0], refusals
            after_lookup = holds(c, 0, 256 * MIB - 1)
            errors(c.tool('find_symbol', name='probe_call')['result'])
            assert holds(c, 0, 256 * MIB - 1) == after_lookup
            # A line searched for in every image reads the large one no more than a name does,
            # and says that it did not.
            reply = c.tool('control_dependencies', file='no_such_file_anywhere.c', line=3)['result']
            assert not reply.get('isError'), reply
            holds(c, 0, 256 * MIB - 1)
            answer = reply['structuredContent']
            assert answer['status'] == 'no_selection' and answer.get('images_not_searched', 0) >= 1 and '/co.so is 300 MiB' in answer['image_budget'], answer
            # The frame the thread stopped in does not fit the default budget, and
            # the reply says so at the top, with what to rerun with.
            session = c.session()
            found = c.inspect('get_stack', generation=session['generation'], tid=session['threads'][0]['tid'])
            assert not named(found, 'probe_wait') and any('BinarySnapshotLimit' in (f['diagnostic'], f['inline_diagnostic']) for f in found['frames']), found
            notice = found.get('image_budget')
            assert notice and '/co.so is 300 MiB; image budget 256 MiB; rerun with --image-limit 400M' in notice, found
        finally:
            shut(c)
        # With the budget asked for, the frame loads its image, and then its names are free.
        c = Client('observe', None, options=('--core', str(dump), *OPTIN), reply_seconds=30)
        try:
            errors(c.tool('find_symbol', name='probe_call')['result'])
            holds(c, 0, 256 * MIB - 1)
            session = c.session()
            found = c.inspect('get_stack', generation=session['generation'], tid=session['threads'][0]['tid'])
            frame = named(found, 'probe_wait')
            assert frame and frame['diagnostic'] is None and found['image_budget'] is None, found
            after_stack = holds(c, BIG, BIG + 256 * MIB)
            reply = c.tool('find_symbol', name='probe_call')['result']
            assert not reply.get('isError') and reply['structuredContent']['module_id'] == frame['module_id'], reply
            result['core'] = {'image_bytes': BIG, 'held_after_lookup_bytes': after_lookup, 'held_after_stack_bytes': after_stack, 'refused': notice.replace(str(w), '.')}
        finally:
            shut(c)
    finally:
        lib.unlink(missing_ok=True); dump.unlink(missing_ok=True)


def definers(w, a, result):
    (w/'df.c').write_text(LIB + 'char _PyRuntime[64] = "not a runtime";\n')
    subprocess.run(['cc', '-g', '-O1', '-fno-optimize-sibling-calls', '-shared', '-fPIC', str(w/'df.c'), '-o', str(w/'df_ok.so')], check=True, timeout=60)
    def view(r):
        """The Python view's answer, once it is not a Pending one."""
        deadline = time.monotonic() + 30
        while True:
            reply = r.client.tool('get_language_stack', language='python', generation=r.session['generation'], tid=r.tid)['result']
            why = errors(reply)[0]  # this host is not Python: every answer is a refusal
            if why not in ('SymbolDiscoveryPending', 'DebugMetadataPending'): return why
            assert time.monotonic() < deadline, why
            time.sleep(.005)
    # Eight libraries define the symbol the Python view looks for; each is 300 MiB.
    libs = []
    try:
        for i in range(8):
            libs.append(w/f'df{i}.so'); libs[-1].write_bytes((w/'df_ok.so').read_bytes()); os.truncate(libs[-1], BIG)
        r = Run(w, w/'host', [w/'lk_ok.so', *libs])  # the thread waits in a small library without the symbol
        try:
            answers = [view(r) for _ in range(12)]  # asking again must not read one more each time
            held = r.holds(0, 16 * MIB)
            assert set(answers) == {'PythonImageBudgetExceeded'}, answers
            refusals = [f.get('detail') or '' for f in load_failures(r.client)]
            assert any('.so is 300 MiB; a language view may read 256 MiB of the image it finds its runtime in' in d for d in refusals), refusals
            result['definers'] = {'images': len(libs), 'image_bytes': BIG, 'held_bytes': held, 'answer': answers[0]}
            r.close()
        finally:
            r.kill()
    finally:
        for lib in libs: lib.unlink(missing_ok=True)
    # Within the bounds the defining images are read, and no more of them than a scan holds.
    r = Run(w, w/'host', [w/'df_ok.so'])
    try:
        why = view(r)
        assert why != 'PythonImageBudgetExceeded', why
        figures = r.modules().get('image_bytes')
        assert not figures or figures['held'] > 0, figures  # the probe saw the one small definer loaded
        result['definers']['small'] = {'answer': why, 'held_bytes': r.holds(0, MIB)}
        r.close()
    finally:
        r.kill()


def forks(w, a, result):
    (w/'fk_child.c').write_text('#include <unistd.h>\n__attribute__((noinline)) int exe_marker(int n) { __asm__ volatile("" ::: "memory"); return n + 1; }\nint main(void) { for (;;) { exe_marker(1); usleep(20000); } }\n')
    (w/'fk_parent.c').write_text('#include <unistd.h>\n#include <sys/wait.h>\nint main(int c, char **v) { pid_t p = fork(); if (!p) { execv(v[1], v + 1); _exit(127); } int s; waitpid(p, &s, 0); return c < 0; }\n')
    subprocess.run(['cc', '-g', '-O1', '-rdynamic', str(w/'fk_child.c'), '-o', str(w/'fk_child')], check=True, timeout=60)
    subprocess.run(['cc', '-g', '-O1', str(w/'fk_parent.c'), '-o', str(w/'fk_parent')], check=True, timeout=60)
    program = oversized_symbols(w/'fk_child', w/'fk_big')
    # The followed child outlives its parent by an instant when the debugger
    # leaves. Adopt it, so that it is seen to be gone before the case ends.
    libc = ctypes.CDLL(None, use_errno=True)
    assert libc.prctl(36, 1, 0, 0, 0) == 0, ctypes.get_errno()  # PR_SET_CHILD_SUBREAPER
    c = Client('control', str(w/'fk_parent'), args=[str(program)], options=(*OPTIN, '--follow-forks', '--break', 'exe_marker'), reply_seconds=30)
    try:
        def state(process): return c.inspect('get_session', process_id=process)
        def settled(s): return s['state'] == 'stopped' and not s['symbol_discovery_pending'] and not s['continue_pending']
        def wait(condition, what):
            deadline = time.monotonic() + 20
            while not condition():
                assert time.monotonic() < deadline, what
                time.sleep(.005)
        def pending(): return next(b for b in c.inspect('get_breakpoints', process_id=2)['breakpoints'] if not b['internal'])['pending']
        c.inspect('continue', process_id=1, generation=state(1)['generation'])
        wait(lambda: c.inspect('get_processes')['total'] == 2, 'child not followed')
        # Run the child through its exec and on into the large program.
        def in_program():
            s = state(2)
            if not settled(s): return False
            if any(t['reason'] == 'exec' for t in s['threads']): return True
            c.inspect('continue', process_id=2, generation=s['generation']); return False
        wait(in_program, 'child did not exec')
        c.inspect('continue', process_id=2, generation=state(2)['generation'])
        # The loader's own stops have come and gone: the probe sees the hook was hit.
        wait(lambda: any(b['internal'] and b['hit_count'] for b in c.inspect('get_breakpoints', process_id=2)['breakpoints']), 'loader hook not hit')
        s = state(2)
        if s['state'] == 'running': c.inspect('interrupt', process_id=2, generation=s['generation'])
        wait(lambda: settled(state(2)), 'child did not stop')
        # The inherited breakpoint is still pending and the program was not read to resolve it.
        assert pending()
        holds(c, 0, 0)
        # Asking for it in the child is a request for that process.
        c.inspect('set_breakpoint', process_id=2, generation=state(2)['generation'], symbol='exe_marker')
        wait(lambda: not pending(), 'breakpoint still pending after it was asked for in the child')
        result['forks'] = {'image_bytes': BIG, 'held_bytes': holds(c, BIG, BIG)}
    finally:
        program.unlink(missing_ok=True)
        shut(c)
        deadline = time.monotonic() + 10
        try:
            while True:
                if os.waitpid(-1, os.WNOHANG) == (0, 0):
                    assert time.monotonic() < deadline, 'a followed process outlived the debugger'
                    time.sleep(.002)
        except ChildProcessError: pass
        libc.prctl(36, 0, 0, 0, 0)


MAPS = r'''
#include <fcntl.h>
#include <stdlib.h>
#include <sys/mman.h>
__attribute__((noinline)) int marker(int n) { __asm__ volatile("" ::: "memory"); return n + 1; }
int main(int argc, char **argv) {
    int n = argc > 1 ? atoi(argv[1]) : 0, fd = open(argc > 2 ? argv[2] : "/proc/self/exe", O_RDONLY);
    for (int i = 0; i < n; i++) if (mmap(0, 4096, argc > 3 ? PROT_READ | PROT_EXEC : PROT_READ, MAP_PRIVATE, fd, 0) == MAP_FAILED) return 2;
    return marker(n) < 0;
}
'''


def mappings(w, a, result):
    (w/'maps.c').write_text(MAPS)
    subprocess.run(['cc', '-g', '-O1', str(w/'maps.c'), '-o', str(w/'maps')], check=True, timeout=60)
    def run(count, lib=None):
        c = Client('control', str(w/'maps'), args=[str(count), *([str(lib)] if lib else [])], options=('--break', 'marker'), reply_seconds=120)
        try:
            t = time.monotonic()
            c.continue_initial_stop(); session = c.stopped('breakpoint', seconds=120)
            frame = c.inspect('get_stack', tid=session['threads'][0]['tid'])['frames'][0]
            found = None
            if lib:
                for _ in range(2000):
                    found = c.tool('find_symbol', name='probe_wait')['result']
                    if not found.get('isError') or found['content'][0]['text'] != 'SymbolDiscoveryPending': break
                    time.sleep(.005)
            seconds = time.monotonic() - t
            return frame, seconds, load_failures(c), found
        finally:
            shut(c)
    # The executable mapped thousands of times: one page each, so no two merge.
    _, base, _, _ = run(1000)
    rows = {}
    for count in (5000, 8000):
        frame, seconds, failures, _ = run(count)
        assert frame['symbol'] == 'marker' and frame['source'] and frame['diagnostic'] is None, frame
        assert failures == [], failures
        # Linear in the mappings: a quadratic walk is 25 to 64 times the base here.
        assert seconds < max(1.0, 20 * base), (count, seconds, base)
        rows[str(count)] = round(seconds, 3)
    # A library with 4,000 program headers: 5,000 mappings of it are placed,
    # and the probe sees its name resolve.
    e = Elf(w/'lk_ok.so')
    phoff, = struct.unpack_from('<Q', e.b, 32); phnum, = struct.unpack_from('<H', e.b, 56)
    table = bytes(e.b[phoff:phoff + 56 * phnum]) + bytes(56 * (4000 - phnum))
    at = e.hole(); e.b += bytes(at - len(e.b)) + table
    struct.pack_into('<Q', e.b, 32, at); struct.pack_into('<H', e.b, 56, 4000)
    lib = e.save(w/'mp_segments.so')
    frame, _, failures, found = run(5000, lib)
    assert frame['symbol'] == 'marker' and not found.get('isError') and found['structuredContent']['name'] == 'probe_wait' and failures == [], (frame, found, failures)
    # Mapped 40,000 times it is 160 million placement steps: real work, so it
    # is refused, promptly, and the refusal is in the module list.
    frame, seconds, failures, found = run(40000, lib)
    assert frame['symbol'] == 'marker' and frame['diagnostic'] is None, frame  # the executable is unaffected
    assert errors(found)[0] == 'MappingLimit', found
    assert [f['diagnostic'] for f in failures if f['path'].endswith('/mp_segments.so')] == ['MappingLimit'], failures
    assert seconds < max(2.0, 100 * base), (seconds, base)
    result['mappings'] = {'base_seconds': round(base, 3), 'seconds': rows, 'refused_seconds': round(seconds, 3)}


def refused(w, a, result):
    # 4,000,000 section headers: the symbols-only reader finishes, and the view
    # it made is then refused. The answer must be final, not Pending for ever.
    size = 257 * MIB
    e = Elf(w/'lk_ok.so')
    struct.pack_into('<H', e.b, 60, 0); struct.pack_into('<Q', e.b, e.shoff + 32, 4000000)  # the count lives in section 0
    struct.pack_into('<Q', e.b, 40, e.hole())  # and the table is the hole
    lib = e.save(w/'rf.so', size)
    try:
        r = Run(w, w/'host', [lib])
        try:
            answers = {}
            for name in ('xodb_no_such_symbol', 'probe_wait'):
                reply, calls = r.symbol(name, calls=400)
                answers[name] = {'calls': calls, 'error': errors(reply)[0]}
            # Once final, the same answer at once: no reader is started again.
            reply, calls = r.symbol('xodb_no_such_symbol', calls=1)
            assert errors(reply)[0] == answers['xodb_no_such_symbol']['error'], (reply, answers)
            result['refused'] = answers
            r.close()
        finally:
            r.kill()
    finally:
        lib.unlink(missing_ok=True)


def defaults(w, a, result):
    one, two = w/'dflt1.so', w/'dflt2.so'
    for lib in (one, two): lib.write_bytes((w/'lk_ok.so').read_bytes()); os.truncate(lib, BIG)
    advice = re.compile(r'; rerun with ((?:--image-(?:total-)?limit \d+[MG] ?)+) or set symbols\.image_(?:total_)?bytes')
    try:
        # Nothing asked for: 256 MiB an image, 512 MiB in all, and a 300 MiB image is refused unread.
        options, said = {}, []
        for attempt in range(4):
            r = Run(w, w/'host', [one, two], options=[x for pair in options.items() for x in pair], env={'CHAIN': '1'})
            try:
                figures = r.modules().get('image_bytes')
                if attempt == 0 and figures: assert figures['image_limit'] == 256 * MIB and figures['total_limit'] == 512 * MIB, figures
                found = r.stack()
                loaded = [name for name in ('probe_wait', 'probe_call') if named(found, name) and named(found, name)['source']]
                r.holds(len(loaded) * BIG, len(loaded) * BIG + MIB)  # a refused image is not read; the small executable is
                if len(loaded) == 2:
                    assert found.get('image_budget') is None, found
                    r.close(); break
                # The sentence names the image and says what to rerun with; do exactly that.
                notice = found.get('image_budget')
                assert notice and '.so is 300 MiB; ' in notice, found
                match = advice.search(notice)
                assert match, notice
                words = match.group(1).split()
                options.update(zip(words[::2], words[1::2])); said.append(notice.replace(str(w), '.'))
                r.close()
            finally:
                r.kill()
        else:
            raise AssertionError(f'following the refusals did not load both images: {said}')
        # The first refusal is the per-image budget; the total came second.
        assert said and 'image budget 256 MiB; rerun with --image-limit 400M' in said[0] and len(said) == 2 and 'left of the' in said[1] and '--image-total-limit 1G' in said[1], said
        result['defaults'] = {'refusals': said, 'options': options}
    finally:
        for lib in (one, two): lib.unlink(missing_ok=True)


def optin(w, a, result):
    size = 1 << 30
    lib = w/'opt.so'; lib.write_bytes((w/'lk_ok.so').read_bytes()); os.truncate(lib, size)
    try:
        r = Run(w, w/'host', [lib], options=OPTIN)
        try:
            t = time.monotonic(); found = r.stack(); seconds = time.monotonic() - t
            frame = named(found, 'probe_wait')
            assert frame and frame['source'] and frame['diagnostic'] is None and found['image_budget'] is None, found
            figures = r.modules().get('image_bytes')
            assert not figures or (figures['image_limit'], figures['total_limit']) == (2 << 30, 8 << 30), figures
            result['optin'] = {'image_bytes': size, 'held_bytes': r.holds(size, size + MIB), 'stack_seconds': round(seconds, 3)}
            r.close()
        finally:
            r.kill()
    finally:
        lib.unlink(missing_ok=True)


def junk(w, prefix, each, total):
    """Images that, read greedily in the order a search meets them, leave less
    of `total` than the smallest honest library needs: as many of `each` as
    fit, then one of every halving size down to 512 KiB. Later arguments are
    opened later, sit lower in memory and are met first, so the list is
    smallest first."""
    sizes = [each] * (total // each); size = each
    while size >= MIB: size //= 2; sizes.append(size)
    libs = []
    for i, size in enumerate(reversed(sizes)):
        libs.append(w/f'{prefix}{i}.so'); libs[-1].write_bytes((w/'lk_ok.so').read_bytes()); os.truncate(libs[-1], size)
    return libs


def starved(w, a, result, key, capture):
    result[key] = {}
    line = HOST.split('\n').index(next(l for l in HOST.split('\n') if 'int exe_marker(int n)' in l)) + 1
    for label, options, image, total in (('defaults', (), 256 * MIB, 512 * MIB), ('optin', OPTIN, 2 << 30, 8 << 30)):
        honest = w/f'{key}_honest.so'; honest.write_bytes((w/'lk_ok.so').read_bytes()); os.truncate(honest, MIB)
        libs = junk(w, key + '_junk', min(1023 * MIB, image), total)
        assert sum(lib.stat().st_size for lib in libs) > total  # the probe mapped more than the whole total
        share = min(total // 2, total - image)
        try:
            r = Run(w, w/'host', [honest, *libs], options=options)  # the thread waits in the honest library
            try:
                r.holds(0, 0)
                if capture:
                    opened = r.client.inspect('start_profile', generation=r.session['generation'], duration_ms=60000, frequency_hz=99, tids=[r.tid])['capture']
                    history = opened['mapping_history']
                    skipped, first = history.get('images_not_searched'), history.get('image_budget')
                else:
                    # A file that is in no image: every image is searched for it.
                    texts = errors(r.client.tool('run_to', generation=r.client.session()['generation'], tid=r.tid, file='no_such_file_anywhere.c', line=3)['result'])
                    assert texts[0] == 'NoCodeForSourceLine', texts
                    # A line that exists is found, and its reply says the search was partial too.
                    reply = r.client.tool('set_breakpoint', generation=r.client.session()['generation'], file='host.c', line=line)['result']
                    assert not reply.get('isError') and reply['structuredContent']['ids'], reply
                    skipped, first = reply['structuredContent'].get('images_not_searched'), reply['structuredContent'].get('image_budget')
                # The search took its share of the total and no more.
                held = r.holds(0, share + 16 * MIB)
                # So the frame the thread is stopped in still loads, with source.
                r.session = r.client.session()
                found = r.stack()
                frame = named(found, 'probe_wait')
                assert frame and frame['source'] and frame['diagnostic'] is None and found['image_budget'] is None, (found, held)
                # And the reply did not pass a partial search off as a whole one.
                assert skipped and skipped >= 1 and first and re.search(r' is \d+ MiB; ', first), (skipped, first)
                if not capture: assert len(texts) == 2 and texts[1].startswith(f'{skipped} images not searched; ') and ' MiB' in texts[1], (texts, skipped)
                if capture: r.client.inspect('stop_profile', generation=r.client.session()['generation'], capture_id=opened['id'])
                result[key][label] = {'mapped_bytes': sum(lib.stat().st_size for lib in libs), 'total_bytes': total, 'sweep_share_bytes': share, 'held_after_search_bytes': held, 'images_not_searched': skipped, 'first': first.replace(str(w), '.')}
                r.close()
            finally:
                r.kill()
        finally:
            for lib in (honest, *libs): lib.unlink(missing_ok=True)


def starve(w, a, result): starved(w, a, result, 'starve', False)
def starvecap(w, a, result): starved(w, a, result, 'starvecap', True)


def linefirst(w, a, result):
    (w/'maps.c').write_text(MAPS)
    subprocess.run(['cc', '-g', '-O1', str(w/'maps.c'), '-o', str(w/'lf_maps')], check=True, timeout=60)
    def number(text, mark): return text.split('\n').index(next(l for l in text.split('\n') if mark in l)) + 1
    def run(count, executable):
        """Seconds for a line of the executable and for a line of the file mapped `count` times, and the replies."""
        c = Client('control', str(w/'lf_maps'), args=[str(count), str(w/'lk_ok.so'), *(['x'] if executable else [])], options=('--break', 'marker'), reply_seconds=180)
        try:
            c.continue_initial_stop(); c.stopped('breakpoint', seconds=120)
            out = []
            for file, line in (('maps.c', number(MAPS, 'int marker(int n)')), ('lib.c', number(LIB, 'return (int)read(fd'))):
                t = time.monotonic()
                reply = c.tool('set_breakpoint', generation=c.session()['generation'], file=file, line=line)['result']
                out.append((time.monotonic() - t, reply))
            return out
        finally:
            shut(c)
    rows = {}
    for executable in (False, True):
        base = max(seconds for seconds, _ in run(1000, executable))
        (own, mine), (theirs, mapped) = run(8000, executable)
        # Linear in the mappings: the quadratic search is 64 times the base here, and a minute.
        assert max(own, theirs) < max(1.0, 20 * base), (executable, own, theirs, base)
        # The executable's own line is found whatever else is mapped.
        assert not mine.get('isError') and mine['structuredContent']['ids'] and mine['structuredContent']['images_not_searched'] == 0, mine
        # A line of the file mapped 8,000 times. A readable header mapping places the image, so the
        # line has 8,000 addresses: a typed refusal. An executable mapping of the header fits no
        # segment: the file is not loaded there, and it is tried once, not 8,000 times.
        assert errors(mapped)[0] == ('NoCodeForSourceLine' if executable else 'SourceLineAddressLimit'), mapped
        rows['r-x' if executable else 'r--'] = {'base_seconds': round(base, 3), 'own_line_seconds': round(own, 3), 'mapped_line_seconds': round(theirs, 3), 'mapped_line': errors(mapped)[0]}
    result['linefirst'] = rows


def tabs(w, a, result):
    def tab(r, language):
        deadline = time.monotonic() + 30
        while True:
            view = r.client.inspect('get_language_tabs')['view']
            if view['complete']: return next(t for t in view['tabs'] if t['tab'] == language)
            assert time.monotonic() < deadline, view
            time.sleep(.005)
    def refusal(r, lib):
        found = [f.get('detail') or '' for f in load_failures(r.client) if f['path'] == str(lib)]
        assert len(found) == 1 and ' is 300 MiB; a language view may read 256 MiB of the image it finds its runtime in' in found[0], found
        return found[0]
    libs = []
    try:
        # An interpreter library with debug info, over the fixed bound for a view's own read.
        (w/'tb_perl.c').write_text(LIB + 'int Perl_runops_standard(void) { return 0; }\n')
        libs.append(w/'tb_perl.so')
        subprocess.run(['cc', '-g', '-O1', '-fno-optimize-sibling-calls', '-shared', '-fPIC', str(w/'tb_perl.c'), '-o', str(libs[-1])], check=True, timeout=60)
        os.truncate(libs[-1], BIG)
        r = Run(w, w/'host', [libs[-1]], options=('--image-limit', '1G', '--image-total-limit', '2G'))  # the thread waits inside it
        try:
            before = tab(r, 'perl')
            assert before['status'] == 'unavailable' and before['reason'] == 'PerlImageBudgetExceeded', before
            said = refusal(r, libs[-1])
            r.holds(0, 0)
            frame = named(r.stack(), 'probe_wait')
            assert frame and frame['source'], frame  # the probe saw the stack load the image
            r.holds(BIG, BIG + MIB)
            # The view can read the image now, so the tab is looked at again: it no longer blames the budget.
            after = tab(r, 'perl')
            assert after['reason'] != 'PerlImageBudgetExceeded', after
            # And the refusal had said that a stack would.
            assert said.endswith('; a stack frame in it loads it'), said
            result['tabs'] = {'before': before['reason'], 'after': after['reason']}
            r.close()
        finally:
            r.kill()
        # The same without debug info: a stack unwinds it from its frame tables and never loads it.
        (w/'tb_python.c').write_text(LIB + 'char _PyRuntime[64] = "not a runtime";\n')
        libs.append(w/'tb_python.so')
        subprocess.run(['cc', '-O1', '-fno-optimize-sibling-calls', '-shared', '-fPIC', '-Wl,--strip-debug', str(w/'tb_python.c'), '-o', str(libs[-1])], check=True, timeout=60)
        os.truncate(libs[-1], BIG)
        r = Run(w, w/'host', [libs[-1]], options=('--image-limit', '1G', '--image-total-limit', '2G'))
        try:
            before = tab(r, 'python')
            assert before['status'] == 'unavailable' and before['reason'] == 'PythonImageBudgetExceeded', before
            said = refusal(r, libs[-1])
            assert said.endswith('; it has no debug info, so a stack does not load it either'), said
            assert named(r.stack(), 'probe_wait')  # named from the symbols-only view
            r.holds(0, MIB)  # and indeed not loaded
            after = tab(r, 'python')
            assert after['status'] == 'unavailable' and after['reason'] == 'PythonImageBudgetExceeded', after  # the tab says what the view says
            result['tabs']['stripped'] = said.replace(str(w), '.')
            r.close()
        finally:
            r.kill()
    finally:
        for lib in libs: lib.unlink(missing_ok=True)


def views(w, a, result):
    # The Lua, Ruby, Go and Emacs Lisp views read the main executable to look
    # for their runtime, and nothing else: here it is 300 MiB, among four
    # libraries as large, and the thread waits in a small one.
    program = w/'vw_host'; program.write_bytes((w/'host').read_bytes()); os.chmod(program, 0o755); os.truncate(program, BIG)
    libs = []
    for i in range(4): libs.append(w/f'vw{i}.so'); libs[-1].write_bytes((w/'lk_ok.so').read_bytes()); os.truncate(libs[-1], BIG)
    result['views'] = {}
    try:
        for label, options, expected in (('defaults', (), 0), ('optin', OPTIN, BIG)):
            r = Run(w, program, [w/'lk_ok.so', *libs], options=options)
            try:
                answers = {}
                for language in ('lua', 'ruby', 'go', 'elisp'):
                    deadline = time.monotonic() + 30
                    while True:
                        why = errors(r.client.tool('get_language_stack', language=language, generation=r.session['generation'], tid=r.tid)['result'])[0]  # the host is none of these
                        if why not in ('SymbolDiscoveryPending', 'DebugMetadataPending'): break
                        assert time.monotonic() < deadline, why
                        time.sleep(.005)
                    answers[language] = why
                # Within the image budget the executable is read, once; over it, it is not.
                # (A view may also look at the frames' own small library.)
                result['views'][label] = {'answers': answers, 'held_bytes': r.holds(expected, expected + MIB)}
                r.close()
            finally:
                r.kill()
    finally:
        for lib in (program, *libs): lib.unlink(missing_ok=True)


def restore(w, a, result):
    # A breakpoint by address is saved with the image it is in and restored
    # after a restart by loading that one image: one of four 300 MiB
    # libraries here, and only within the image budget.
    libs = []
    for i in range(4): libs.append(w/f'rs{i}.so'); libs[-1].write_bytes((w/'lk_ok.so').read_bytes()); os.truncate(libs[-1], BIG)
    result['restore'] = {}
    try:
        for label, options in (('defaults', ()), ('optin', OPTIN)):
            c = Client('control', str(w/'host'), args=[str(lib) for lib in libs], options=(*options, '--break', 'exe_marker'), reply_seconds=30)
            try:
                c.continue_initial_stop(); c.stopped('breakpoint', seconds=30)
                for _ in range(2000):
                    found = c.tool('find_symbol', name='probe_wait')['result']
                    if not found.get('isError') or found['content'][0]['text'] != 'SymbolDiscoveryPending': break
                    time.sleep(.005)
                assert not found.get('isError'), found
                saved = c.inspect('set_breakpoint', generation=c.session()['generation'], address=found['structuredContent']['address'])['id']
                holds(c, 0, 0)  # the symbols-only view named it
                c.inspect('restart', generation=c.session()['generation'])
                c.stopped(seconds=30)
                c.inspect('continue', generation=c.session()['generation'])
                c.stopped('breakpoint', seconds=30)  # at exe_marker again: the libraries are open
                probe = next(b for b in c.inspect('get_breakpoints')['breakpoints'] if b['id'] == saved)
                if options:
                    # Restored in the new process, by reading the one library it is in.
                    assert not probe['pending'] and probe['address'], probe
                    held = holds(c, BIG, BIG + MIB)
                else:
                    # Over the default budget the image is not read, and the breakpoint waits.
                    assert probe['pending'], probe
                    held = holds(c, 0, MIB)
                result['restore'][label] = {'pending': probe['pending'], 'held_bytes': held}
            finally:
                shut(c)
    finally:
        for lib in libs: lib.unlink(missing_ok=True)


CASES = {'lookup': lookup, 'total': total, 'phantom': phantom, 'sections': sections, 'pending': pending, 'path': path, 'container': container, 'core': core, 'definers': definers, 'forks': forks, 'mappings': mappings, 'refused': refused,
         'defaults': defaults, 'optin': optin, 'starve': starve, 'starvecap': starvecap, 'linefirst': linefirst, 'tabs': tabs, 'views': views, 'restore': restore}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--work', required=True, type=Path)
    p.add_argument('--only', default=','.join(CASES))
    p.add_argument('--wrong-result', action='store_true')
    a = p.parse_args()
    root = Path(__file__).resolve().parents[1]; os.chdir(root); os.umask(0o022)
    w = a.work.resolve(); w.mkdir(parents=True, mode=0o755)
    (w/'host.c').write_text(HOST); (w/'lib.c').write_text(LIB)
    subprocess.run(['cc', '-g', '-O1', '-rdynamic', '-fno-optimize-sibling-calls', str(w/'host.c'), '-o', str(w/'host'), '-ldl'], check=True, timeout=60)
    subprocess.run(['cc', '-g', '-O1', '-fno-optimize-sibling-calls', '-shared', '-fPIC', str(w/'lib.c'), '-o', str(w/'lk_ok.so')], check=True, timeout=60)
    result = {'status': 'running', 'seconds': {}}; started = time.monotonic()
    try:
        for key in a.only.split(','):
            t = time.monotonic(); CASES[key](w, a, result); result['seconds'][key] = round(time.monotonic() - t, 3)
        result['status'] = 'pass'
    finally:
        result['elapsed_seconds'] = round(time.monotonic() - started, 3)
        (w/'results.json').write_text(json.dumps(result, indent=2).replace(str(w), '.') + '\n')
    print('image budget, hostile target: ' + '; '.join(f'{key} {seconds} s' for key, seconds in result['seconds'].items()))


if __name__ == '__main__':
    main()
