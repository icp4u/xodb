"""Explicit, bounded demo stop sampling; the xodb runtime never auto-resumes.

Warm metadata before profiling. Unexpected stop reasons are left for the user.
Samples deliberately perturb wall time: no claim of per-node CPU accounting.
"""
import time


def sample_time(tool, samples=12):
    deadline = time.monotonic() + 30

    def stopped():
        while True:
            state = tool('get_session')
            if state['state'] == 'stopped':
                for thread in state['threads']:
                    if thread['reason'] not in ('none', 'interrupt'):
                        raise RuntimeError('Left unexpected stop for inspection: ' + str(thread))
                return state
            if state['state'] == 'exited' or time.monotonic() >= deadline:
                raise TimeoutError('Waiting for owned sample stop')
            time.sleep(.005)

    def capture():
        while True:
            state = stopped()
            try:
                return tool('capture_redot_sample', generation=state['generation'])
            except Exception as error:
                if not any(reason in str(error) for reason in ('MetadataPending', 'SymbolDiscoveryPending')) or time.monotonic() >= deadline:
                    raise
                time.sleep(.01)

    tool('interrupt', generation=tool('get_session')['generation'])
    capture()  # Load DWARF outside the recorded timing window.
    tool('set_redot_profiling', enabled=True, generation=tool('get_session')['generation'])
    tool('continue', generation=tool('get_session')['generation'])
    collected = []
    last_frame = None
    while len(collected) < samples and time.monotonic() < deadline:
        # Wait for observable frame progress, not an assumed target frame rate.
        profile = tool('get_redot_profile')
        current = profile['selected']
        if current is None or current['number'] == last_frame:
            time.sleep(.005)
            continue
        last_frame = current['number']
        # Spread samples through the measured frame instead of always stopping
        # at the protocol-delivery boundary. This is a sampling schedule, not
        # a test assertion about target speed.
        delay = min(current['frame_ms'] / 1000, .05) * ((len(collected) % 4) + 1) / 5
        time.sleep(delay)
        tool('interrupt', generation=tool('get_session')['generation'])
        sample = capture()
        collected.append(sample)
        tool('continue', generation=tool('get_session')['generation'])
    if not collected:
        raise RuntimeError('No native samples collected')
    while time.monotonic() < deadline:
        profile = tool('get_redot_profile', frame_number=collected[-1]['frame_number'])
        if profile['selected'] is not None:
            break
        time.sleep(.005)
    tool('set_redot_profiling', enabled=False, generation=tool('get_session')['generation'])
    return collected
