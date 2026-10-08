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
