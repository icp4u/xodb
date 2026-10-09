"""Public subscription/scalar oracles; all callbacks belong to this fixture."""
import gc
import struct
import sys
import xodb_paths


def canonical(value):
    if value is None:
        return 0, b''
    if type(value) is bool:
        return 1, bytes([value])
    if type(value) is int:
        sign = 1 if not value else 2 if value < 0 else 0
        magnitude, raw = abs(value), bytearray([sign])
        while magnitude:
            raw += (magnitude & ((1 << 30) - 1)).to_bytes(4, 'little')
            magnitude >>= 30
        return 2, bytes(raw)
    if type(value) is float:
        return 3, struct.pack('<d', value)
    if type(value) is str:
        return 4, b''.join(ord(c).to_bytes(4, 'little') for c in value)
    if type(value) is bytes:
        return 5, value
    return 0, b''


def verify(frame, expression, expected=None, reason=None, patches=(), inject=True):
    kind, raw = canonical(expected)
    return xodb_paths.check(frame, expression, expected, raw, kind, reason, list(patches), inject)


def scalar(root, selector, reason=None):
    frame = sys._getframe()
    expression = 'root[' + repr(selector) + ']'
    expected = root[selector] if reason is None else None
    return verify(frame, expression, expected, reason)


def nested(root):
    frame = sys._getframe()
    original = root
    before = verify(frame, 'root["player"]["scores"][-1]', root['player']['scores'][-1])
    root = {'player': {'scores': [0, int('777777777')]}}
    gc.collect()
    assert root is not original
    after = verify(frame, 'root["player"]["scores"][-1]', root['player']['scores'][-1])
    assert before != after
    root['player']['scores'].extend(range(100))
    verify(frame, 'root["player"]["scores"][-1]', root['player']['scores'][-1])
    root['player']['scores'].clear()
    verify(frame, 'root["player"]["scores"][-1]', reason='PythonPathIndexOutOfRange')


def malformed(root):
    frame = sys._getframe()
    for expression in ('root.a', 'root()', 'root[1+1]', 'root[01]', 'root[+1]', 'root[ 1]',
                       'root[2147483648]', 'root[-2147483649]', 'root["x\\n"]', 'root["é"]',
                       'root["unterminated]', 'root[0][0][0][0][0]', 'root[' + '1'*130 + ']'):
        verify(frame, expression, reason='UnsupportedLanguageExpression')
    verify(frame, 'root[0][0][0][0]', reason='PythonWatchValueUnsupported')


class CustomKey:
    calls = 0
    def __hash__(self):
        return hash('sentinel')
    def __eq__(self, other):
        type(self).calls += 1
        return other == 'sentinel'


class DictSubclass(dict):
    calls = 0
    def __getitem__(self, key):
        type(self).calls += 1
        return 999


class ListSubclass(list):
    calls = 0
    def __getitem__(self, key):
        type(self).calls += 1
        return 999


class StringSubclass(str):
    pass


def special(root):
    frame = sys._getframe()
    verify(frame, 'root["ok"]', reason='PythonPathKeyUnsupported')
    verify(frame, 'root["sentinel"]', reason='PythonPathKeyUnsupported')


def corrupt(root):
    frame = sys._getframe()
    info = xodb_paths.dict_info(root)
    assert info['kind'] == 1 and info['count'] == info['used'] == 2
    verify(frame, 'root["a"]', root['a'])
    key_address = id(next(iter(root)))
    verify(frame, 'root["a"]', reason='PythonPathKeyAmbiguous',
           patches=[(info['entries']+16, key_address.to_bytes(8, 'little'))])
    verify(frame, 'root["a"]', reason='InconsistentDict',
           patches=[(info['used_address'], (1).to_bytes(8, 'little'))])
    verify(frame, 'root["a"]', reason='InconsistentDict',
           patches=[(info['kind_address'], bytes([3]))])
    verify(frame, 'root["a"]', reason='InconsistentDict',
           patches=[(info['count_address'], (-1).to_bytes(8, 'little', signed=True))])
    verify(frame, 'root["a"]', reason='InconsistentDict',
           patches=[(info['entries']+16, bytes(8))])
    verify(frame, 'root["a"]', reason='InconsistentDict',
           patches=[(info['entries']+24, bytes(8))])


def split(root):
    frame = sys._getframe()
    info = xodb_paths.dict_info(root)
    assert info['kind'] == 2 and info['values']
    verify(frame, 'root["a"]', root['a'])
    verify(frame, 'root["b"]', reason='PythonPathKeyNotFound')


def closure(root):
    def inner():
        frame = sys._getframe()
        verify(frame, 'root["a"]', root['a'])
    inner()


def suspended(root):
    yield root['a']
    yield root['a']


def boundaries(root):
    frame = sys._getframe()
    verify(frame, 'root[0]["a"][0][-1]', root[0]['a'][0][-1])
    verify(frame, 'root[0]["a"][0]["bad"]', reason='PythonPathIndexRequired')
    verify(frame, 'root[0]["absent"][0]', reason='PythonPathKeyNotFound')
    verify(frame, 'root[0]["none"][0]', reason='PythonPathContainerUnsupported')
    verify(frame, 'root[0]["a"][0][0][0]', reason='UnsupportedLanguageExpression')


def numeric_duplicate(root):
    frame = sys._getframe()
    info = xodb_paths.dict_info(root)
    assert info['kind'] == 0 and info['count'] == 2
    verify(frame, 'root[1]', root[1])
    verify(frame, 'root[1]', reason='PythonPathKeyAmbiguous',
           patches=[(info['entries']+24+8, id(True).to_bytes(8, 'little'))])


def unicode_root(é):
    frame = sys._getframe()
    verify(frame, 'é["a"]', é['a'])


def empty_corruption(root):
    frame = sys._getframe()
    info = xodb_paths.dict_info(root)
    assert not info['used']
    verify(frame, 'root["missing"]', reason='InconsistentDict',
           patches=[(info['kind_address'], bytes([255]))])
    verify(frame, 'root["missing"]', reason='InconsistentDict',
           patches=[(info['log2_address']+1, bytes([255]))])


def main():
    for value in (None, True, False, 0, -1, -(1 << 63), 1 << 200, 0.0, -0.0, float('nan'),
                  'a\x00é𝄞\ud800', 'x'*1024, b'a\x00\xff', b'x'*4096):
        scalar({'key': value}, 'key')
    scalar({'key': 'x'*1025}, 'key', 'PythonWatchSampleLimit')
    scalar({'key': b'x'*4097}, 'key', 'PythonWatchSampleLimit')
    scalar({'x'*100: 9}, 'x'*100)
    scalar({'': 8}, '')
    for key in (0, -1, -(1 << 31), (1 << 31)-1):
        scalar({key: 7}, key)
    scalar({True: 17}, 1)
    scalar({False: 18}, 0)
    scalar({-1.0: 19}, -1)
    scalar({float('nan'): 99, float('inf'): 91, None: 3, b'a': 8, 1 << 300: 4, 'a': 7}, 'a')
    scalar({float('nan'): 99, float('inf'): 91, None: 3, b'a': 8, 1 << 300: 4, 3: 7}, 3)
    scalar({1.1: 99}, 1, 'PythonPathKeyNotFound')
    scalar({}, 'missing', 'PythonPathKeyNotFound')
    scalar({'a': None}, 'missing', 'PythonPathKeyNotFound')
    for sequence in ([1, 2, 3], (1, 2, 3)):
        for index in (0, -1, -3, 2):
            scalar(sequence, index)
        scalar(sequence, -4, 'PythonPathIndexOutOfRange')
        scalar(sequence, 3, 'PythonPathIndexOutOfRange')
        scalar(sequence, '0', 'PythonPathIndexRequired')
    scalar([], 0, 'PythonPathIndexOutOfRange')
    scalar({'a': 1}, 'a')
    deleted = dict(a=1, b=2, c=3)
    del deleted['b']
    scalar(deleted, 'c')
    scalar({i: i for i in range(129)}, 0, 'PythonPathWorkLimit')
    scalar({i: i for i in range(128)}, 127)
    scalar({i: i for i in range(128)}, -1, 'PythonPathKeyNotFound')
    scalar({'é': 99, 'a': 7}, 'a')
    scalar({'long irrelevant key': 99, 'a': 7}, 'a')
    boundaries([{'a': ([7],), 'none': None}])
    numeric_duplicate({1: 7, 2: 8})
    unicode_root({'a': 7})
    empty_corruption({})
    nested({'player': {'scores': [0, int('666666666')]}})
    cycle = []; cycle.append(cycle)
    malformed(cycle)
    root = {'ok': 1, CustomKey(): 17}
    before = CustomKey.calls
    special(root)
    assert CustomKey.calls == before
    assert root['sentinel'] == 17 and CustomKey.calls > before
    scalar(DictSubclass(a=1), 'a', 'PythonPathContainerUnsupported')
    scalar(ListSubclass([1]), 0, 'PythonPathContainerUnsupported')
    assert DictSubclass.calls == ListSubclass.calls == 0
    scalar({StringSubclass('a'): 3}, 'a', 'PythonPathKeyUnsupported')
    corrupt({'a': 1, 'b': 2})
    class Shared:
        pass
    first, second = Shared(), Shared()
    first.a = 4; second.b = 5
    split(first.__dict__)
    closure({'a': 7})
    generator = suspended({'a': 8})
    next(generator)
    verify(generator.gi_frame, 'root["a"]', 8)
    generator.close()
    xodb_paths.finished()


if __name__ == '__main__':
    main()
