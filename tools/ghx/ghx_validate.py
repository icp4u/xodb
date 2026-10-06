#!/usr/bin/env python3
"""Reference reader/validator for xodb.ghidra.function_graph 0.4.x (C01-R5).

Usage:
  ghx_validate.py [--image ELF] [--map FILE] FILE.json...
                                             validate; nonzero exit on any failure
                                             (--image/--map may appear anywhere)
  ghx_validate.py --follow VN_ID FILE         print use->op->instruction chain
  ghx_validate.py --summary FILE              one-line summary

Stdlib only.  This is the admission step for saved or external exports; it
re-derives what it can instead of trusting copied producer fields:
referential integrity, canonical hex, explicit tagging of unresolved
relationships, artifact_id = sha256(identity.basis), the qualification
maximum, and instruction admission: every instruction with bytes must lie in
the file-backed part of an executable segment of the export's own PT_LOAD
table, inside strict bounds, with the outside/crossing lists and the refusal,
undecoded and function-map qualification reasons recomputed; every admitted
or undecoded instruction must start in file-backed executable bytes.  With
--image the ELF file is hashed, its PT_LOAD table and flags re-parsed, every
admitted/undecoded start re-checked against the image's own PF_X file bytes
and every exported instruction byte compared with the file.  With --map the
function-map file the caller trusts is hashed against function_map.sha256 and
used, entry_size, records and flow_reaches_other_function_start are re-derived
from its records; without it they are producer-asserted.  Exports before
0.4.x are refused (0.3.x counted any accepted map record as function-start
evidence; 0.2.x predates instruction admission).

Limit: this checks byte provenance, not decode correctness.  Instruction
length, mnemonic, operands and raw p-code are producer fields that are not
re-derived (that needs a decoder): a shortened length whose bytes are a true
prefix of the file bytes, or rewritten semantics, pass.  A correct hash is not
trustworthy instruction evidence, and none of this is semantic verification.
"""
import hashlib
import json
import re
import struct
import sys

HEX = re.compile(r'^0x(0|[1-9a-f][0-9a-f]{0,15})$')
SUPPORTED = ('0.4.',)
CONTRACT = 'C01-R5 CONTRACT.v5'
LEVELS = ('complete', 'qualified', 'unreliable')


class Bad(Exception):
    pass


def need(cond, msg):
    if not cond:
        raise Bad(msg)


def hexok(v, what):
    need(isinstance(v, str) and HEX.match(v), f'{what}: non-canonical hex {v!r}')


def validate(j):
    need(j.get('schema') == 'xodb.ghidra.function_graph', 'schema name')
    need(any(str(j.get('schema_version', '')).startswith(p) for p in SUPPORTED),
         'schema_version %r not admitted (0.4.x only; 0.2.x predates instruction admission, 0.3.x the entry-record function-map rule)' % j.get('schema_version'))
    need(isinstance(j.get('producer'), dict) and j['producer'].get('java') in (True, False), 'producer.java')
    st = j.get('status')
    need(st in ('ok', 'error'), 'status')
    if st == 'error':
        e = j.get('error')
        need(isinstance(e, dict) and isinstance(e.get('code'), str) and isinstance(e.get('message'), str),
             'error envelope')
        return 'error:' + e['code']
    need(j.get('contract') == CONTRACT, 'contract %r' % j.get('contract'))
    need(re.match(r'^fg2-[0-9a-f]{64}$', j.get('artifact_id', '')), 'artifact_id')
    basis = j['identity']['basis']
    need(j['artifact_id'] == 'fg2-' + hashlib.sha256(basis.encode()).hexdigest(), 'artifact_id != sha256(identity.basis)')
    fields = dict(l.split('=', 1) for l in basis.splitlines())
    img = j['image']
    need(re.match(r'^[0-9a-f]{64}$', img['sha256']), 'image.sha256')
    need(fields.get('image_sha256') == img['sha256'], 'identity image_sha256')
    lang = j['language']
    for k in ('id', 'compiler_spec', 'sla_sha256', 'cspec_sha256', 'pspec_sha256', 'ldefs_sha256', 'spec_set_sha256'):
        need(re.match(r'^[0-9a-f]{64}$', lang.get(k, '')) if k.endswith('sha256') else lang.get(k), f'language.{k}')
        if k.endswith('sha256'):
            need(fields.get(k) == lang[k], f'identity {k}')
    fmap = j['function']['function_map']
    need(fields.get('function_map_sha256') == (fmap['sha256'] if fmap['supplied'] else 'none'), 'identity function_map_sha256')
    esize = fmap['entry_size']
    need(esize is None or (fmap['supplied'] and fmap['entries_accepted'] > 0), 'function_map.entry_size without accepted records')
    if esize is not None:
        hexok(esize, 'function_map.entry_size')
    need(fmap['used'] == (esize is not None), 'function_map.used is not "an accepted record starts at the entry"')
    if fmap['supplied']:
        need(fmap['entries_rejected'] == 0 and fmap['entries_accepted'] == fmap['records'] and
             fmap['entries_accepted'] == fmap['entries_added'] + fmap['entries_already_known'], 'function_map record counts')
    q = j['qualification']
    need(q['level'] in LEVELS, 'qualification.level')
    worst = 'complete'
    for r in q['reasons']:
        need(isinstance(r.get('code'), str) and r.get('level') in LEVELS[1:], 'qualification reason')
        if r['level'] == 'unreliable' or worst == 'unreliable':
            worst = 'unreliable'
        else:
            worst = 'qualified'
    need(q['level'] == worst, 'qualification.level is not the maximum of its reasons')
    codes = {(r['code'], r.get('addr')) for r in q['reasons']}
    fs = q['function_starts']
    need(fs['function_map'] == ('none' if not fmap['supplied'] else 'used' if fmap['used'] else 'supplied_unused'),
         'qualification.function_starts.function_map')
    stripped = fs['symbols'] != 'symtab' and not fmap['used']
    need(stripped == any(c == 'stripped_without_function_starts' for c, _ in codes),
         'stripped_without_function_starts must be present exactly when no symbols and no map record at the entry')
    for im in j['imports']:
        hexok(im['stub'], 'import.stub')
        need(im['provenance'] == 'plt_relocation', 'import provenance')
    spaces = {s['name'] for s in j['address_spaces']}
    fn = j['function']
    hexok(fn['entry'], 'function.entry')
    need(fn['bounds_policy'] in ('advisory', 'strict', 'unbounded_flow'), 'bounds_policy')

    segs = [(int(g['vaddr'], 16), int(g['filesz'], 16), 'x' in g['flags']) for g in img['load_segments']]
    entry = int(fn['entry'], 16)
    dsize = int(fn['declared_size'], 16) if fn['declared_size'] else None
    if dsize is not None:
        need(entry + dsize <= 1 << 64, 'declared range overflows')
    outside, crossing, map_out = [], [], []
    msize = int(esize, 16) if esize is not None and dsize is None else None
    refused_addrs = {r['addr'] for r in j['instruction_admission']['refused'] if r['on_flow_path']}
    insns = {}
    raw_ids = set()
    for i in j['instructions']:
        hexok(i['addr'], 'insn.addr')
        need(i['id'] == 'insn:' + i['addr'], 'insn id')
        need(i['id'] not in insns, 'dup insn')
        insns[i['id']] = i
        a, n = int(i['addr'], 16), i['length']
        if dsize is not None and (a < entry or a - entry >= dsize):
            outside.append(i['id'])
        if msize is not None and (a < entry or a - entry >= msize or (n > 0 and n > msize - (a - entry))):
            map_out.append(i['id'])
        adm = i.get('admission')
        need(adm in ('admitted', 'refused', 'undecoded'), f"{i['id']} admission {adm!r}")
        if adm != 'refused':
            need(any(x and v <= a < v + z for v, z, x in segs),
                 f"{i['id']} {adm} instruction start is not file-backed executable bytes of the export's PT_LOAD table")
        if adm == 'refused':
            need('bytes' not in i and 'raw_pcode' not in i, f"{i['id']} refused instruction carries evidence")
            need(i['addr'] in refused_addrs, f"{i['id']} refused but not listed in instruction_admission")
            need((('instruction_refused_' + i.get('refusal_reason', '')), i['addr']) in codes,
                 f"{i['id']} refused without a qualification reason")
            continue
        if adm == 'undecoded':
            need('bytes' not in i, f"{i['id']} undecoded instruction carries bytes")
            need(('instruction_undecoded', i['addr']) in codes, f"{i['id']} undecoded without an instruction_undecoded reason")
            continue
        need(n > 0 and isinstance(i.get('bytes'), str) and len(i['bytes']) == 2 * min(n, 32), f"{i['id']} bytes/length")
        need(any(x and v <= a and a - v < z and n <= z - (a - v) for v, z, x in segs),
             f"{i['id']} span [{a:#x},+{n}) is not file-backed executable bytes of one PT_LOAD")
        if dsize is not None and entry <= a and a - entry < dsize and n > dsize - (a - entry):
            crossing.append(i['id'])
    if fn['bounds_policy'] == 'strict':
        need(not crossing and not [x for x in outside if insns[x].get('admission') == 'admitted'],
             'admitted instruction outside strict bounds: %s' % (outside + crossing))
    for r in refused_addrs:
        need(any(c.startswith('instruction_refused_') and ad == r for c, ad in codes), f'refusal at {r} not qualified')
    undecoded = {i['addr'] for i in j['instructions'] if i.get('admission') == 'undecoded'}
    need(undecoded == {ad for c, ad in codes if c == 'instruction_undecoded'}, 'instruction_undecoded reasons differ from undecoded instructions')
    need(bool(map_out) == any(c == 'flow_outside_function_map_bounds' for c, _ in codes), 'function-map extent reason')
    need((dsize is not None and esize is not None and dsize != int(esize, 16)) ==
         any(c == 'declared_extent_conflict' for c, _ in codes), 'declared_extent_conflict reason')
    ext = dsize if dsize is not None else int(esize, 16) if esize is not None else None
    unreached = set()
    if ext is not None:
        last = entry + ext - 1
        if not any(int(i['addr'], 16) <= last < int(i['addr'], 16) + (i['length'] if isinstance(i['length'], int) and i['length'] > 0 else 1)
                   for i in j['instructions']):
            unreached = {hex(last)}
    need(unreached == {ad for c, ad in codes if c == 'declared_extent_unreached'}, 'declared_extent_unreached reason')
    if dsize is not None:
        need(sorted(fn['instructions_outside_declared_bounds']) == sorted(x for x in outside), 'instructions_outside_declared_bounds')
        need(sorted(fn['instructions_crossing_declared_bounds']) == sorted(crossing), 'instructions_crossing_declared_bounds')
        need(bool(crossing) == any(c == 'instruction_crosses_declared_bounds' for c, _ in codes), 'span-crossing reason')
        for r in i.get('raw_pcode', []):
            need(r['id'] not in raw_ids, 'dup raw id')
            raw_ids.add(r['id'])
            for v in ([r['out']] if r['out'] else []) + r['in']:
                need(v['space'] in spaces, f"raw varnode space {v['space']}")
                hexok(v['offset'], 'raw varnode offset')

    hp = j['high_pcode']
    ops = {o['id']: o for o in hp['ops']}
    vns = {v['id']: v for v in hp['varnodes']}
    need(len(ops) == len(hp['ops']) and len(vns) == len(hp['varnodes']), 'duplicate op/varnode id')
    blocks = {b['id']: b for b in j['blocks']}
    for o in hp['ops']:
        hexok(o['pc'], 'op.pc')
        need(o['insn'] == '' or o['insn'] in insns, f"{o['id']} insn {o['insn']} not exported")
        need(o['raw_link'] in ('instruction_only',), 'raw_link tag')
        need(o['block'] in blocks, f"{o['id']} block {o['block']}")
        if o['out'] is not None:
            need(o['out'] in vns, f"{o['id']} out {o['out']}")
            need(vns[o['out']]['def'] == o['id'], f"def backlink {o['out']} -> {o['id']}")
        for v in o['in']:
            need(v is None or v in vns, f"{o['id']} input {v}")
            if v is not None:
                need(o['id'] in vns[v]['uses'], f"use backlink {v} -> {o['id']}")
    hvs = {h['id']: h for h in j['high_variables']}
    for v in hp['varnodes']:
        need(v['space'] in spaces, f"{v['id']} space")
        hexok(v['offset'], f"{v['id']} offset")
        need(v['def'] is None or v['def'] in ops, f"{v['id']} def")
        for u in v['uses']:
            need(u in ops, f"{v['id']} use {u}")
            need(v['id'] in ops[u]['in'], f"{v['id']} use {u} not an input")
        need(v['high'] is None or v['high'] in hvs, f"{v['id']} high {v['high']}")
        if 'ref_op' in v:
            need(v['ref_op'] == '' or v['ref_op'] in ops, f"{v['id']} ref_op")
    for h in j['high_variables']:
        for x in h['instances']:
            need(x in vns and vns[x]['high'] == h['id'], f"{h['id']} instance {x}")
    seen = {}
    for b in j['blocks']:
        hexok(b['start'], 'block.start')
        for o in b['ops']:
            need(o in ops and ops[o]['block'] == b['id'], f"block {b['id']} op {o}")
            need(o not in seen, f'op {o} in two blocks')
            seen[o] = b['id']
        for s in b['succ']:
            need(s['to'] in blocks and b['id'] in blocks[s['to']]['pred'], f"edge {b['id']}->{s['to']}")
    need(len(seen) == len(ops), 'ops not in any block')
    for c in j['calls']:
        need(c['op'] in ops, f"call op {c['op']}")
        need(c['kind'] in ('direct', 'indirect'), 'call kind')
        need((c['target'] is None) == (c['target_status'] == 'unresolved'), 'call target tagging')
    for t in j['jump_tables']:
        need(t['op'] in ops, 'jumptable op')
        for x in t['targets']:
            hexok(x, 'jumptable target')
    p = j['pseudocode']
    text_lines = p['text'].split('\n')
    for t in p['tokens']:
        if t['line'] >= 1:
            line = text_lines[t['line'] - 1]
            need(line[t['col']:t['col'] + len(t['text'])] == t['text'], f"token {t['i']} position")
        if 'op' in t:
            need(t['op'] in ops and ops[t['op']]['pc'] == t['pc'], f"token {t['i']} op")
        if 'var' in t:
            need(t['var'] in vns, f"token {t['i']} var")
    need(p['tokens_unaligned'] == sum(1 for t in p['tokens'] if t['line'] < 0), 'tokens_unaligned count')
    need(j['source_lines']['status'] in ('unavailable', 'partial', 'complete'), 'source_lines.status')
    need(isinstance(j['unresolved_relationships'], list), 'unresolved_relationships')
    return 'ok'


def check_image(j, path):
    """Independent byte check against the ELF file named by the caller."""
    if j.get('status') != 'ok':
        return
    data = open(path, 'rb').read()
    need(hashlib.sha256(data).hexdigest() == j['image']['sha256'], 'image sha256 differs from --image file')
    need(data[:4] == b'\x7fELF' and data[4] == 2 and data[5] == 1, '--image is not ELF64 little-endian')
    phoff, = struct.unpack_from('<Q', data, 32)
    phentsize, phnum = struct.unpack_from('<HH', data, 54)
    loads = []
    for k in range(phnum):
        t, fl, off, va, _, fsz, msz, _ = struct.unpack_from('<IIQQQQQQ', data, phoff + phentsize * k)
        if t == 1:
            loads.append((va, msz, off, fsz, fl))
    exp = [(int(g['vaddr'], 16), int(g['memsz'], 16), int(g['offset'], 16), int(g['filesz'], 16)) for g in j['image']['load_segments']]
    need(exp == [x[:4] for x in loads], 'export load_segments differ from the image PT_LOAD table')
    for i in j['instructions']:
        if i.get('admission') != 'refused':
            a = int(i['addr'], 16)
            need(any(fl & 1 and va <= a < va + fsz for va, msz, off, fsz, fl in loads),
                 f"{i['id']} {i.get('admission')} instruction start is not the image's file-backed executable bytes")
        if 'bytes' not in i:
            continue
        a, n = int(i['addr'], 16), min(i['length'], 32)
        src = [off + a - va for va, msz, off, fsz, fl in loads if fl & 1 and va <= a and a + i['length'] <= va + fsz]
        need(src and data[src[0]:src[0] + n].hex() == i['bytes'], f"{i['id']} bytes are not the image's executable file bytes")


def cold_fragment(name, owner):
    """gcc hot/cold split: "<owner>.cold" or "<owner>.cold.<n>", exact suffix."""
    return name.startswith(owner) and re.fullmatch(r'\.cold(\.[0-9]+)?', name[len(owner):]) is not None


def check_map(j, path):
    """Re-derive the export's function-map claims from the map the caller trusts."""
    if j.get('status') != 'ok':
        return
    data = open(path, 'rb').read()
    fm = j['function']['function_map']
    need(fm['supplied'] and hashlib.sha256(data).hexdigest() == fm['sha256'], '--map file is not the export\'s function_map (sha256)')
    recs = {}
    for line in data.split(b'\n'):
        t = line.split()
        if t and not t[0].startswith(b'#'):
            t = [x.decode('ascii') for x in t]
            need(len(t) == 3 and HEX.match(t[1]) and HEX.match(t[2]) and int(t[1], 16) not in recs, '--map record %r' % line[:80])
            recs[int(t[1], 16)] = (t[0], int(t[2], 16))
    entry = int(j['function']['entry'], 16)
    rec = recs.get(entry)
    need(fm['records'] == len(recs), 'function_map.records differs from --map')
    need(fm['used'] == (rec is not None) and fm['entry_size'] == (hex(rec[1]) if rec else None),
         'function_map.used/entry_size differ from --map')
    owner = rec[0] if rec else j['function']['name']
    other = {i['addr'] for i in j['instructions'] if int(i['addr'], 16) != entry and int(i['addr'], 16) in recs and
             not cold_fragment(recs[int(i['addr'], 16)][0], owner)}
    need(other == {r.get('addr') for r in j['qualification']['reasons'] if r['code'] == 'flow_reaches_other_function_start'},
         'flow_reaches_other_function_start differs from --map')


def follow(j, vid):
    hp = j['high_pcode']
    ops = {o['id']: o for o in hp['ops']}
    vns = {v['id']: v for v in hp['varnodes']}
    insns = {i['id']: i for i in j['instructions']}
    v = vns[vid]
    print(f"{vid} {v['space']}:{v['offset']}:{v['size']} {v.get('register', '')} high={v['high']}")
    if v['def']:
        o = ops[v['def']]
        i = insns.get(o['insn'], {})
        print(f"  def  {o['id']} {o['opcode']} @ {o['pc']} -> {o['insn']} {i.get('mnemonic', '?')} {i.get('operands', '')}"
              f" raw={[r['id'] for r in i.get('raw_pcode', [])]}")
    for u in v['uses']:
        o = ops[u]
        i = insns.get(o['insn'], {})
        print(f"  use  {o['id']} {o['opcode']} @ {o['pc']} -> {o['insn']} {i.get('mnemonic', '?')} {i.get('operands', '')}")


def main(argv):
    if len(argv) >= 3 and argv[1] == '--follow':
        follow(json.load(open(argv[3])), argv[2])
        return 0
    if len(argv) >= 3 and argv[1] == '--summary':
        j = json.load(open(argv[2]))
        if j['status'] != 'ok':
            print(j['status'], j['error']['code'])
            return 0
        print(j['artifact_id'], j['function']['name'], j['function']['entry'],
              'insns', len(j['instructions']), 'ops', len(j['high_pcode']['ops']),
              'vns', len(j['high_pcode']['varnodes']), 'blocks', len(j['blocks']),
              'calls', len(j['calls']), 'tokens', len(j['pseudocode']['tokens']))
        return 0
    rc = 0
    opt = {}
    files = argv[1:]
    for o in ('--image', '--map'):
        if o in files:
            k = files.index(o)
            if k + 1 >= len(files):
                print('usage: ghx_validate.py [--image ELF] [--map FILE] FILE.json...')
                return 2
            opt[o], files = files[k + 1], files[:k] + files[k + 2:]
    for f in files:
        try:
            doc = json.load(open(f))
            r = validate(doc)
            if '--image' in opt:
                check_image(doc, opt['--image'])
            if '--map' in opt:
                check_map(doc, opt['--map'])
            print(f'PASS {f} {r}')
        except (Bad, KeyError, TypeError, ValueError) as e:
            print(f'FAIL {f} {type(e).__name__}: {e}')
            rc = 1
    return rc


if __name__ == '__main__':
    sys.exit(main(sys.argv))
