#!/usr/bin/env python3
"""Initial-stop retry is bounded and cannot swallow other control refusals."""
from client import Client

success = {'result': {'isError': False, 'structuredContent': {'resumed': True}}}
def rejected(reason):
    return {'result': {'isError': True, 'content': [{'type':'text', 'text':reason}]}}

class Scripted(Client):
    def __init__(self, replies, states=None):
        self.replies = list(replies)
        self.states = states or ['stopped'] * len(replies)
        self.actions = []
    def session(self):
        return {'state': self.states[len(self.actions)], 'generation': 100 + len(self.actions)}
    def tool(self, name, **arguments):
        self.actions.append((name, arguments))
        return self.replies.pop(0)

for replies, calls in [([success], 1), ([rejected('StaleSnapshot'), success], 2)]:
    client = Scripted(replies)
    assert client.continue_initial_stop() == {'resumed': True}
    assert client.actions == [('continue', {'generation': 100 + i}) for i in range(calls)]

for replies, states, calls in [
    ([rejected('StaleSnapshot'), rejected('StaleSnapshot'), success], None, 2),
    ([rejected('ControllerLeaseRequired'), success], None, 1),
    ([{'error': {'code': -32602, 'message': 'InvalidArguments'}}, success], None, 1),
    ([success], ['running'], 0),
    ([rejected('StaleSnapshot'), success], ['stopped', 'running'], 1),
]:
    client = Scripted(replies, states)
    try:
        client.continue_initial_stop()
    except AssertionError:
        pass
    else:
        raise AssertionError('unexpectedly accepted a control refusal')
    assert len(client.actions) == calls, client.actions

print('Initial continue: bounded stale retry, unchanged refusal and state checks passed')

class StopSequence(Client):
    def __init__(self, observations):
        self.observations = iter(observations)
        self.reads = 0
    def session(self):
        self.reads += 1
        return next(self.observations)

def stop(generation, state='stopped', reason='breakpoint', discovery=False, continuing=False):
    return dict(generation=generation, state=state, threads=[dict(reason=reason)],
                symbol_discovery_pending=discovery, continue_pending=continuing)

# The first breakpoint is an internal loader rendezvous. Completion permits
# automatic execution, so its generation must never be handed to a caller as
# the requested user breakpoint's generation.
sequence = [stop(11, discovery=True), stop(12, continuing=True),
            stop(13, state='running'), stop(14, reason='interrupt'), stop(15)]
client = StopSequence(sequence)
assert client.stopped('breakpoint') == sequence[-1]
assert client.reads == len(sequence)

# An explicit interrupt can stop discovery. Preserve that stopped outcome;
# this helper does not send continue or retry any control operation.
interrupted = stop(21, reason='interrupt')
assert StopSequence([stop(20, discovery=True), interrupted]).stopped() == interrupted
for pending in ('discovery', 'continuing'):
    client = StopSequence([stop(30, **{pending: True}), stop(31, state='exited')])
    try:
        client.stopped()
    except AssertionError:
        pass
    else:
        raise AssertionError('pending work hid a target exit')
    assert client.reads == 2
print('Stop wait: discovery and deferred continue settle; real breakpoint, interrupt and exit remain distinct')
