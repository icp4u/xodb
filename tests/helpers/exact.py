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
