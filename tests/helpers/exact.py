"""Validate additive MCP hex siblings before comparison with legacy exports."""


def legacy(value):
    if isinstance(value, list):
        return [legacy(item) for item in value]
    if not isinstance(value, dict):
        return value
    result = {}
    for key, item in value.items():
        original = key[:-4] if key.endswith('_hex') else None
        if original in value:
            raw = value[original]
            def encoded(word):
                assert word is None or type(word) is int, (key, word)
                return None if word is None else hex(word)
            expected = [encoded(word) for word in raw] if isinstance(raw, list) else encoded(raw)
            assert item == expected, (key, item, expected)
        else:
            result[key] = legacy(item)
    return result


def assert_wide(value, path='$'):
    """Every observed wide integer must have an exact sibling, regardless of name.

    This is a test-client guard, deliberately independent of the producer's
    address-name classifier. It makes a newly exposed wide field fail CI.
    Floats and already-string values do not claim an exact integer contract.
    """
    def wide(word):
        return type(word) is int and abs(word) >= 1 << 53
    if isinstance(value, dict):
        for key, item in value.items():
            where = path + '.' + key
            if wide(item):
                assert value.get(key + '_hex') == hex(item), (where, item, value.get(key + '_hex'))
            elif isinstance(item, list) and any(wide(word) for word in item):
                sibling = value.get(key + '_hex')
                assert isinstance(sibling, list) and len(sibling) == len(item), (where, 'missing/short parallel hex array')
                for i, word in enumerate(item):
                    if wide(word): assert sibling[i] == hex(word), (where, i, word, sibling[i])
            if isinstance(item, dict): assert_wide(item, where)
            elif isinstance(item, list):
                for i, row in enumerate(item):
                    if isinstance(row, (dict, list)): assert_wide(row, where + '[' + str(i) + ']')
    elif isinstance(value, list):
        for i, item in enumerate(value):
            assert not wide(item), (path, i, 'unkeyed wide integer cannot carry a sibling')
            assert_wide(item, path + '[' + str(i) + ']')


def assert_reply_exact(reply):
    result = reply.get('result', {})
    if result.get('isError') or 'structuredContent' not in result: return reply
    import json
    value = result['structuredContent']
    assert json.loads(result['content'][0]['text']) == value, 'MCP structured/text mismatch'
    assert_wide(value)
    return reply
