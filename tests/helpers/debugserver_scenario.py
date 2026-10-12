"""One debugserver session, shared by the live Mac test and the recorded replay.

`static` maps the fixture's symbols to their link-time addresses (nm) and
carries the Darwin signal numbers; the image list supplies the load address.
`printed` is asked for after the first continue: the addresses the fixture
itself printed, which must agree with link address + slide. A launched target
starts before its first instruction; an attached one is already looping.
"""
import time

LINK_BASE = 0x100000000  # __TEXT of an arm64 macOS executable
IMAGE_REFUSAL = 'MachOImageUnsupported'


def refusal(client, tool, expected, **args):
    result = client.tool(tool, **args)['result']
    assert result['isError'] and result['content'][0]['text'] == expected, (tool, result)


def modules(client):
    regions, images, cursor = [], [], None
    for _ in range(64):
        page = client.inspect('list_modules', **({'cursor': cursor} if cursor else {}))
        regions += page['regions']; images += page['load_failures']; cursor = page['next']
        if cursor is None:
            assert len(regions) == page['total_regions'] and len(images) == page['total_load_failures']
            return regions, images
    raise AssertionError('module pages do not end')


def word(client, address, size=8):
    return int.from_bytes(bytes.fromhex(client.inspect('read_memory', address=hex(address), length=size)['hex']), 'little')


def run(client, static, printed=None, log=print, launched=True):
    started = time.monotonic()
    first = client.session()
    info = first['gdb_remote']
    assert first['state'] == 'stopped' and first['architecture'] == 'aarch64', first
    assert info['os'] == 'darwin' and info['architecture'] == 'aarch64' and info['address_bits'] == 47, info
    assert info['threads'] == info['step'] == 'available' and info['libraries'] == 'unsupported', info
    assert info['watchpoints'] == info['memory_regions'] == info['images'] == 'not_tested', info
    tid = first['threads'][0]['tid']
    log(f"session: os={info['os']} architecture={info['architecture']} pid={first['pid']} threads={len(first['threads'])}")

    regions, images = modules(client)
    mine = [image for image in images if image['path'].endswith('/fixture')]
    assert len(mine) == 1 and all(image['diagnostic'] == IMAGE_REFUSAL for image in images), images
    base = mine[0]['start']
    at = {name: value - LINK_BASE + base for name, value in static['symbols'].items()}
    text = [r for r in regions if r['start'] <= at['tick'] < r['end']]
    data = [r for r in regions if r['start'] <= at['marker'] < r['end']]
    assert len(text) == 1 and text[0]['permissions'] == 'r-xp' and text[0]['path'].endswith('/fixture'), text
    assert len(data) == 1 and data[0]['permissions'] == 'rw-p', data
    assert all(a['end'] <= b['start'] for a, b in zip(regions, regions[1:])), 'regions overlap or are unordered'
    info = client.session()['gdb_remote']
    assert info['memory_regions'] == info['images'] == 'available', info
    log(f'images at launch: {len(images)}; regions: {len(regions)}; fixture loaded at {base:#x}')

    registers = client.inspect('get_registers', tid=tid)['registers']
    assert {f'x{n}' for n in range(31)} | {'sp', 'pc', 'pstate'} <= registers.keys(), sorted(registers)
    assert any(r['start'] <= int(registers['pc'], 16) < r['end'] and r['permissions'][2] == 'x' for r in regions)

    if launched: assert word(client, at['marker']) == 0x1122334455667788, 'stopped before the first instruction'
    client.action('write_memory', address=hex(at['marker']), hex='0100000000000000')
    assert word(client, at['marker']) == 1
    wanted = int(registers['x19'], 16) ^ 0x1234
    client.action('write_register', tid=tid, name='x19', value=hex(wanted))
    assert int(client.inspect('get_registers', tid=tid)['registers']['x19'], 16) == wanted
    client.action('write_register', tid=tid, name='x19', value=registers['x19'])
    log('memory and register writes read back')

    probe = client.action('set_breakpoint', address=hex(at['tick']))['id']
    client.action('continue'); stopped = client.stopped('breakpoint', seconds=20)
    if printed:
        told = printed()
        assert all(told[name] == at[name] for name in at), (told, at)
        assert told['sigusr1'] == static['sigusr1'] and told['sigstop'] == static['sigstop']
        log('fixture output agrees with nm + slide')
    assert len(stopped['threads']) == 2, stopped['threads']
    tid = next(t['tid'] for t in stopped['threads'] if t['reason'] == 'breakpoint')
    registers = client.inspect('get_registers', tid=tid)['registers']
    assert int(registers['pc'], 16) == at['tick']
    assert at['inner'] <= int(registers['x30'], 16) < at['middle'], registers['x30']
    assert client.inspect('get_stop_info', tid=tid)['stop']['reason'] == 'breakpoint'
    assert word(client, at['tick'], 4) != 0xd4200000, 'the stub must hide its trap from memory reads'
    frames = client.inspect('get_stack', tid=tid)['frames']
    order = ['tick', 'inner', 'middle', 'outer', 'main']
    bounds = sorted(at[name] for name in order) + [at['main'] + 0x200]
    for frame, name in zip(frames, order):
        low = at[name]; high = bounds[bounds.index(low) + 1]
        assert low <= frame['pc'] < high, (name, hex(frame['pc']))
        # This recording has no executable segment geometry or local metadata.
        assert frame['symbol'] is None and frame['inline_diagnostic'] == 'UnmappedAddress', frame
    # Like native CFI, the method describes unwinding this frame to its caller.
    assert [f['unwind_method'] for f in frames[:5]] == ['link_register', 'frame_pointer', 'frame_pointer', 'frame_pointer', 'frame_pointer'], frames
    assert 5 <= len(frames) <= 8, len(frames)
    log('stack: ' + ' <- '.join(f"{f['pc']:#x}({f['unwind_method']})" for f in frames))

    client.action('step_instruction', tid=tid); client.stopped('single_step')
    assert int(client.inspect('get_registers', tid=tid)['registers']['pc'], 16) == at['tick'] + 4
    client.action('continue'); client.stopped('breakpoint', seconds=20)
    assert word(client, at['marker']) == 2, 'one pass through tick since the write'
    client.action('remove_breakpoint', id=probe)
    log('breakpoint, step over it, second hit: marker counts passes')

    refusal(client, 'set_watchpoint', 'ExecutionWatchpointsUnsupported', address=hex(at['tick']), length=1, kind='execute', generation=client.session()['generation'])
    refusal(client, 'set_watchpoint', 'InvalidWatchRange', address=hex(at['halves'] + 1), length=4, generation=client.session()['generation'])
    client.action('write_memory', address=hex(at['want_watch']), hex='01000000')
    watch = client.action('set_watchpoint', address=hex(at['halves']), length=8)['id']
    assert client.session()['gdb_remote']['watchpoints'] == 'available'
    for expected in (3, 4):
        client.action('continue'); stopped = client.stopped('watchpoint', seconds=20)
        hits = [e for e in client.inspect('query_events')['events'] if e['kind'] == 'watchpoint_hit']
        assert hits[-1]['detail'] == watch and hits[-1]['address'] == at['halves'], hits[-1]
        assert hits[-1]['trap_address'] == at['halves'] + 4, hits[-1]
        assert at['inner'] <= hits[-1]['pc'] < at['middle'], hits[-1]
        # The stop precedes the store: the pair still holds the earlier value.
        assert word(client, at['marker']) == expected and word(client, at['halves'] + 4, 4) != expected
    client.action('remove_watchpoint', id=watch)
    client.action('write_memory', address=hex(at['want_watch']), hex='00000000')
    log(f"watchpoint on {at['halves']:#x}+8 stopped twice with accessed address {at['halves'] + 4:#x}")

    client.action('write_memory', address=hex(at['want_signal']), hex='01000000')
    client.action('continue'); stopped = client.stopped('signal', seconds=20)
    tid = next(t['tid'] for t in stopped['threads'] if t['reason'] == 'signal')
    stop = client.inspect('get_stop_info', tid=tid)['stop']
    assert stop['signal'] == static['sigusr1'] == 30 and stop['signal_name'] == 'SIGUSR1', stop
    assert word(client, at['got_signal'], 4) == 0, 'not delivered while stopped'
    # A breakpoint, not a delay, proves the handler ran before the next look.
    probe = client.action('set_breakpoint', address=hex(at['tick']))['id']
    client.action('continue'); client.stopped('breakpoint', seconds=20)
    assert word(client, at['got_signal'], 4) == static['sigusr1'], 'continue delivers the Darwin signal number'
    client.action('remove_breakpoint', id=probe)
    client.action('continue'); client.action('interrupt'); stopped = client.stopped('interrupt', seconds=20)
    assert all(t['signal'] == 0 for t in stopped['threads']), stopped['threads']
    log(f"signal {stop['signal']} {stop['signal_name']} reported, delivered on continue; interrupt stops a running target")

    regions, images = modules(client)
    assert len(images) > 10 and any('libsystem' in image['path'] for image in images), len(images)
    assert any(r['path'].startswith('[') for r in regions), 'typed regions such as [stack]'
    log(f'images after startup: {len(images)}; regions: {len(regions)}')

    refusal(client, 'find_symbol', 'GdbLibrariesUnavailable', name='tick')
    refusal(client, 'get_extended_registers', 'ExtendedRegistersUnavailable', tid=tid)
    client.action('detach'); assert client.session()['state'] == 'idle'
    log(f'detached; scenario took {time.monotonic() - started:.2f} s')
