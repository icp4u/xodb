"""Owned target; subscription and scalar oracles run before debugger stops."""
import gc
import json
import sys
import xodb_named


EXPRESSIONS = {'root["player"]["score"]': ('player', 'score'),
               'root["player"]["text"]': ('player', 'text'),
               'root["items"][-1]': ('items', -1), 'root["optional"]': ('optional',)}


def describe(value):
    if value is None:
        return dict(kind=0, sample='')
    if type(value) is int:
        magnitude = abs(value)
        raw = bytes([1 if not magnitude else 2 if value < 0 else 0])
        while magnitude:
            raw += (magnitude & ((1 << 30)-1)).to_bytes(4, 'little'); magnitude >>= 30
        return dict(kind=2, sample=raw.hex())
    if type(value) is str:
        return dict(kind=4, sample=value.encode('utf-32-le', errors='surrogatepass').hex())
    raise AssertionError(type(value))


def probe(label, reason=None):
    frame = sys._getframe(1)
    pairs, watched = [], None
    while frame:
        if frame.f_code.co_filename == __file__ and frame.f_code.co_flags & 1:
            pairs.append((frame, dict(frame.f_locals)))
            if frame.f_code.co_name == 'watched':
                watched = frame
        frame = frame.f_back
    ground = dict(label=label, code=id(watched.f_code) if watched else None, root=None, values={})
    if watched:
        root = watched.f_locals['root']; ground['root'] = id(root)
        for expression, keys in EXPRESSIONS.items():
            if reason:
                ground['values'][expression] = dict(reason=reason); continue
            try:
                value = root
                for key in keys:
                    value = value[key]
                ground['values'][expression] = describe(value)
            except KeyError:
                ground['values'][expression] = dict(reason='PythonPathKeyNotFound')
            except IndexError:
                ground['values'][expression] = dict(reason='PythonPathIndexOutOfRange')
    print(json.dumps(ground), flush=True)
    xodb_named.snapshot(pairs)


class Key:
    calls = 0
    def __hash__(self):
        return hash('player')
    def __eq__(self, other):
        type(self).calls += 1
        return False


def inner(root):
    assert root['player']['score'] == 999
    probe('inner-shadow')


def watched(reuse=False):
    x = 7
    root = {'player': {'score': 7, 'text': 'a'*300+'x'}, 'items': [1, 2, 3], 'optional': None}
    if reuse:
        probe('reuse'); return
    probe('initial')
    retained = root
    x = 8
    root = {'player': {'score': 8, 'text': 'a'*300+'y'}, 'items': [0]*129+[4], 'optional': None}
    gc.collect()
    assert root is not retained
    probe('changed')
    probe('equal')
    del root['optional']
    probe('missing')
    key = Key(); root[key] = 123; before = Key.calls
    probe('callback-refused', 'PythonPathKeyUnsupported')
    assert Key.calls == before
    del root[key]; root['optional'] = None
    probe('recovered')
    root['items'].clear()
    probe('bounds')
    root['items'] = (1, 5)
    probe('tuple')
    saved = root; root = {str(i): i for i in range(129)}
    probe('budget', 'PythonPathWorkLimit')
    root = saved
    inner({'player': {'score': 999}})


def main():
    print('ready', flush=True)
    assert sys.stdin.readline().strip() == 'go'
    watched(); probe('retired')
    watched(True); probe('retired-again')


if __name__ == '__main__':
    main()
