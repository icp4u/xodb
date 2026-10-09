#!/usr/bin/env python3
"""The test-client sweep must reject wide values under previously unknown names."""
import json
import unittest
from helpers.exact import assert_reply_exact, assert_wide


class ExactGuard(unittest.TestCase):
    def test_unknown_field_is_not_exempt(self):
        for n in (1 << 53, (1 << 53) + 1, (1 << 64) - 1, -(1 << 63)):
            value = {'rows': [{'future_name': n}]}
            with self.assertRaises(AssertionError): assert_wide(value)
            value['rows'][0]['future_name_hex'] = hex(n)
            assert_wide(value)
            value['rows'][0]['future_name_hex'] = hex(n + 1)
            with self.assertRaises(AssertionError): assert_wide(value)

    def test_array_is_exact_and_complete(self):
        words = [0, None, (1 << 64) - 1]
        for bad in (None, [], ['0x0', None], ['0x0', None, '0x0']):
            with self.assertRaises(AssertionError): assert_wide({'new_bank': words, 'new_bank_hex': bad})
        assert_wide({'new_bank': words, 'new_bank_hex': ['0x0', None, '0xffffffffffffffff']})
        with self.assertRaises(AssertionError): assert_wide([1 << 53])

    def test_non_integer_values_are_not_reinterpreted(self):
        assert_wide({'small': (1 << 53) - 1, 'flag': True, 'null': None,
                     'decimal': '18446744073709551615', 'float': 1e20})

    def test_both_forms_and_tool_errors(self):
        value = {'realtime_ns': 1800000000000000123, 'realtime_ns_hex': hex(1800000000000000123)}
        reply = {'result': {'structuredContent': value, 'content': [{'type': 'text', 'text': json.dumps(value)}]}}
        assert_reply_exact(reply)
        reply['result']['content'][0]['text'] = '{}'
        with self.assertRaises(AssertionError): assert_reply_exact(reply)
        assert_reply_exact({'result': {'isError': True, 'content': [{'type': 'text', 'text': 'OwnedError'}]}})
        assert_reply_exact({'error': {'code': -32602}})


if __name__ == '__main__': unittest.main()
