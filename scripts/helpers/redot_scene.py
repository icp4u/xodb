"""Start an owned scene demo through xodb's existing MCP controls.

The launch starts stopped: continue it and wait for the engine to report a
scene. Helper processes the engine spawns on the way are released by xodb.
Unexpected breakpoints/signals stay stopped.
"""
import time


def start_scene(tool, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        state = tool('get_session')
        if state['state'] == 'exited':
            raise RuntimeError('Engine exited during startup')
        if state['state'] == 'stopped':
            for thread in state['threads']:
                reason = thread['reason']
                # A helper's exit can stop the step that leaves the launch stop,
                # and opening the GUI can resize the terminal the game shares.
                if reason == 'signal' and thread['signal'] in (17, 28):  # SIGCHLD, SIGWINCH
                    continue
                if reason not in ('none', 'exec', 'interrupt'):
                    raise RuntimeError('Startup stopped for inspection: ' + str((reason, thread['signal'])))
            try:
                tool('continue', generation=state['generation'])
            except Exception as error:
                if not any(name in str(error) for name in ('StaleSnapshot', 'NotStopped')):
                    raise
        scene = tool('get_redot_scene_tree', refresh=True)
        if scene['state'] == 'failed':
            raise RuntimeError(scene['diagnostic'])
        if scene['total'] > 1:
            return scene
        time.sleep(.02)
    raise TimeoutError('Engine scene startup did not finish')
