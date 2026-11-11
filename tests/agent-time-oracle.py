#!/usr/bin/env python3
"""Fast synthetic raw-record oracle checks, including deliberately wrong output."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    out = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(out)
    return out


oracle = module('raw_oracle', ROOT/'src/profile/agent_time_oracle.py')
adapter = module('adapter', ROOT/'src/profile/agent_time.py')


class Oracle(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='agent-oracle-')
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, name, rows):
        path = self.root/name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(''.join(json.dumps(r)+'\n' for r in rows))
        return path

    def test_claude_boundaries_and_exact_usage(self):
        def user(t, ident, content, **extra):
            return dict(timestamp=t, uuid=ident, type='user', message={'content': content}, **extra)
        def assistant(t, ident, content, usage, **extra):
            return dict(timestamp=t, uuid=ident, type='assistant', message=dict(id=ident, content=content, usage=usage, **extra))
        path = self.write('child.jsonl', [
            user(1, 'u1', 'secret prompt'),
            assistant(2, 'm1', [{'type': 'tool_use', 'id': 'tool', 'name': 'Bash', 'input': {}}], {'input_tokens': 10, 'output_tokens': 2}),
            user(4, 'r1', [{'type': 'tool_result', 'tool_use_id': 'tool'}]),
            assistant(5, 'm2', [{'type': 'tool_use', 'id': 'hb', 'name': 'SubagentHandback', 'input': {}}], {'cache_read_input_tokens': 20, 'output_tokens': 3}),
            user(6, 'r2', [{'type': 'tool_result', 'tool_use_id': 'hb'}]),
            user(12, 'note', 'harness note', isMeta=True), user(12.5, 'u2', 'next task'),
            assistant(14, 'done', [], {'input_tokens': 4, 'output_tokens': 1}, stop_reason='end_turn'),
            user(20, 'resume', 'harness resume', isMeta=True),
            assistant(23, 'm4', [], {'input_tokens': 6, 'output_tokens': 2}, stop_reason='end_turn')])
        raw = oracle.audit('claude', path)
        self.assertEqual(raw['tokens'], 48)
        self.assertEqual(raw['waits'], [(14, 20, 'done', 'resume')])
        self.assertEqual(raw['tools'], [('tool', 'Bash', 2, 4), ('hb', 'SubagentHandback', 5, 6)])
        self.assertEqual(raw['wall_seconds'], 22)
        doc = adapter.claude(path, False).document()
        self.assertEqual(oracle.compare(raw, doc), [])
        # A planted wrong token total must fail through the actual CLI, not
        # merely return a nonempty diagnostic that nobody checks.
        doc['token_totals']['fresh input'] += 1
        normalized = self.root/'wrong.json'
        normalized.write_text(json.dumps(doc))
        result = subprocess.run([sys.executable, '-I', '-B', str(ROOT/'src/profile/agent_time_oracle.py'), '--agent', 'claude', '--file', str(path), '--normalized', str(normalized)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        report = json.loads(result.stdout)
        self.assertEqual(report['mismatches'], ['own token total'])
        self.assertNotIn(str(self.root), result.stdout)
        self.assertNotIn('secret prompt', result.stdout)
        doc = adapter.claude(path, False).document()
        next(s for s in doc['spans'] if s['activity'] == 'waiting for resume')['end_record_id'] = 'planted'
        self.assertEqual(oracle.compare(raw, doc), ['resume boundary IDs or intervals'])

    def test_codex_cumulative_reset_and_parallel_tools(self):
        def row(t, kind, **fields):
            return {'timestamp': t, 'type': 'response_item' if kind.startswith('function_') else 'event_msg', 'payload': dict(type=kind, **fields)}
        path = self.write('codex.jsonl', [row(1, 'task_started'),
            row(2, 'function_call', call_id='a', name='read'), row(3, 'function_call', call_id='b', name='read'),
            row(4, 'function_call_output', call_id='a'), row(6, 'function_call_output', call_id='b'),
            row(7, 'token_count', info={'total_token_usage': {'input_tokens': 100, 'cached_input_tokens': 50, 'output_tokens': 30, 'reasoning_output_tokens': 10}}),
            row(8, 'token_count', info={'total_token_usage': {'input_tokens': 100, 'cached_input_tokens': 50, 'output_tokens': 30, 'reasoning_output_tokens': 10}}),
            row(9, 'token_count', info={'last_token_usage': {'input_tokens': 10, 'output_tokens': 3}}),
            row(11, 'token_count', info={'total_token_usage': {'input_tokens': 20, 'output_tokens': 5}}), row(12, 'task_complete')])
        raw = oracle.audit('codex', path)
        self.assertEqual(raw['tokens'], 168)
        self.assertEqual(raw['tools'], [('a', 'read', 2, 4), ('b', 'read', 3, 6)])
        self.assertEqual(oracle.compare(raw, adapter.codex(path).document()), [])
        with path.open('a') as stream:
            stream.write('not json\n[]\n')
        self.assertEqual(oracle.audit('codex', path)['malformed'], 2)
        with mock.patch.object(oracle, 'MAX_LINE', 12):
            with self.assertRaises(ValueError):
                oracle.audit('codex', path)

    def test_explicit_system_close_keeps_its_boundary_identity(self):
        path = self.write('system-close.jsonl', [
            {'timestamp': 1, 'type': 'user', 'message': {'content': 'task'}},
            {'timestamp': 2, 'type': 'assistant', 'message': {'content': [], 'stop_reason': 'stop_sequence'}},
            {'timestamp': 3, 'type': 'system', 'subtype': 'turn_duration', 'uuid': 'closed'},
            {'timestamp': 4, 'type': 'system', 'subtype': 'stop_hook_summary', 'uuid': 'already-closed'},
            {'timestamp': 10, 'type': 'user', 'isMeta': True, 'uuid': 'resume', 'message': {'content': 'resume'}},
            {'timestamp': 12, 'type': 'assistant', 'message': {'content': [], 'stop_reason': 'end_turn'}}])
        raw = oracle.audit('claude', path)
        self.assertEqual(raw['waits'], [(3, 10, 'closed', 'resume')])
        self.assertEqual(oracle.compare(raw, adapter.claude(path, False).document()), [])

    def test_grok_uses_raw_duration_and_usage_sidecar(self):
        path = self.write('grok/events.jsonl', [{'ts': 1, 'type': 'turn_started'},
            {'ts': 5, 'type': 'tool_completed', 'tool_name': 'bash', 'tool_call_id': 'g', 'duration_ms': 3000},
            {'ts': 8, 'type': 'turn_ended', 'outcome': 'success'}])
        path.with_name('usage.json').write_text(json.dumps({'turns': [{'turnNumber': 1, 'inputTokens': 100, 'cachedReadTokens': 20, 'outputTokens': 30, 'reasoningTokens': 10, 'endedAt': 8}]}))
        raw = oracle.audit('grok', path)
        self.assertEqual(raw['tokens'], 130)
        self.assertEqual(raw['tools'], [('g', 'bash', 2, 5)])
        self.assertEqual(oracle.compare(raw, adapter.grok(path).document()), [])


if __name__ == '__main__':
    unittest.main()
