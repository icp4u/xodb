"""Independent, read-only per-file accounting oracle; no adapter imports.

Compare a transcript with its normalized document's OWN totals, not tree totals.
Claude child files can be checked individually. Fork ownership/deduplication
across files is deliberately outside this oracle. Output contains aggregates
and mismatch categories only, never source paths, prompts, commands or IDs.
"""
import argparse
import datetime
import json
import math
from pathlib import Path

MAX_LINE = 16 * 1024 * 1024
MAX_ITEMS = 250000


def seconds(value):
    if isinstance(value, (int, float)):
        return float(value) if math.isfinite(value) else None
    try:
        return datetime.datetime.fromisoformat(str(value).replace('Z', '+00:00')).timestamp()
    except (ValueError, TypeError):
        return None


def lines(path, counts):
    with Path(path).open('rb') as stream:
        while line := stream.readline(MAX_LINE + 1):
            if len(line) > MAX_LINE:
                raise ValueError('oracle record limit')
            counts['records'] += 1
            try:
                row = json.loads(line)
            except ValueError:
                counts['malformed'] += 1
                continue
            if isinstance(row, dict):
                yield row
            else:
                counts['malformed'] += 1


def integer(value):
    return max(0, int(value or 0))


def claude_usage(usage):
    write = usage.get('cache_creation_input_tokens')
    if write is None:
        detail = usage.get('cache_creation') or {}
        write = integer(detail.get('ephemeral_1h_input_tokens')) + integer(detail.get('ephemeral_5m_input_tokens'))
    return (integer(usage.get('input_tokens')), integer(usage.get('cache_read_input_tokens')),
            integer(write), integer(usage.get('output_tokens')))


def audit(agent, path):
    counts = {'records': 0, 'malformed': 0}
    tools, waits, pending, messages, previous = [], [], {}, {}, {}
    total, available, active = 0, False, False
    first = last = terminal = candidate = None
    for row in lines(path, counts):
        t = seconds(row.get('ts') if agent == 'grok' else row.get('timestamp'))
        if t is not None:
            first = t if first is None else min(first, t)
            last = t if last is None else max(last, t)
        kind = row.get('type')
        if agent == 'codex':
            payload = row.get('payload') or {}
            sub = payload.get('type')
            if kind == 'event_msg' and sub in ('task_started', 'task_complete', 'turn_aborted'):
                active = sub == 'task_started' and t is not None
                pending.clear()
            if kind == 'response_item' and sub in ('function_call', 'custom_tool_call') and active and t is not None:
                pending[payload.get('call_id')] = (t, str(payload.get('name', 'unknown')))
            if kind == 'response_item' and sub in ('function_call_output', 'custom_tool_call_output'):
                call = pending.pop(payload.get('call_id'), None)
                if call and t is not None:
                    tools.append((str(payload.get('call_id')), call[1], call[0], max(call[0], t)))
            if kind == 'event_msg' and sub == 'token_count':
                info = payload.get('info') or {}
                usage = info.get('total_token_usage')
                if isinstance(usage, dict):
                    current = {k: integer(v) for k, v in usage.items() if isinstance(v, (int, float))}
                    reset = any(current.get(k, 0) < v for k, v in previous.items())
                    for key in ('input_tokens', 'output_tokens'):
                        total += current.get(key, 0) if reset else max(0, current.get(key, 0) - previous.get(key, 0))
                    previous = current
                    available = True
                elif isinstance(info.get('last_token_usage'), dict):
                    usage = info['last_token_usage']
                    total += integer(usage.get('input_tokens')) + integer(usage.get('output_tokens'))
                    available = True
        elif agent == 'claude':
            msg = row.get('message') or {}
            if not isinstance(msg, dict):
                continue
            content = msg.get('content', [])
            blocks = [b for b in content if isinstance(b, dict)] if isinstance(content, list) else []
            results = [b for b in blocks if b.get('type') == 'tool_result']
            if kind == 'user' and not results and t is not None:
                if row.get('isMeta'):
                    if not active:
                        active = True
                        if terminal and t > terminal[0]:
                            candidate = (terminal[0], t, terminal[1], str(row.get('uuid', '')))
                else:
                    # A typed prompt before any assistant work cancels the
                    # candidate resume: that gap was waiting for the user.
                    candidate = terminal = None
                    active = True
                    pending.clear()
            if kind == 'assistant':
                if candidate:
                    waits.append(candidate)
                    candidate = None
                terminal = None
                active |= t is not None
                usage = msg.get('usage')
                if isinstance(usage, dict):
                    ident = str(msg.get('id') or row.get('requestId') or row.get('uuid'))
                    parts = claude_usage(usage)
                    messages[ident] = tuple(max(a, b) for a, b in zip(messages.get(ident, (0, 0, 0, 0)), parts))
                    available = True
                for block in blocks:
                    if block.get('type') == 'tool_use' and active and t is not None:
                        pending[block.get('id')] = (t, str(block.get('name', 'unknown')))
                if msg.get('stop_reason') == 'end_turn' and t is not None:
                    terminal = (t, str(row.get('uuid', '')))
                    active = False
                    pending.clear()
            if kind == 'user' and results:
                handback = False
                for block in results:
                    call = pending.pop(block.get('tool_use_id'), None)
                    if call:
                        handback |= call[1] == 'SubagentHandback'
                        if t is not None:
                            tools.append((str(block.get('tool_use_id')), call[1], call[0], max(call[0], t)))
                if handback and t is not None:
                    terminal = (t, str(row.get('uuid', '')))
                    active = False
                    pending.clear()
            if kind == 'system' and row.get('subtype') in ('turn_duration', 'stop_hook_summary') and active and t is not None:
                if candidate:
                    waits.append(candidate)
                    candidate = None
                terminal = (t, str(row.get('uuid', '')))
                active = False
                pending.clear()
        elif kind == 'tool_completed':
            duration = row.get('duration_ms')
            if t is not None and isinstance(duration, (int, float)) and duration >= 0:
                tools.append((str(row.get('tool_call_id', '')), str(row.get('tool_name', 'unknown')), t-duration/1000, t))
        if max(len(tools), len(messages), len(pending), len(waits)) > MAX_ITEMS:
            raise ValueError('oracle item limit')
    if candidate:
        waits.append(candidate)
    if agent == 'claude':
        total = sum(sum(parts) for parts in messages.values())
    elif agent == 'grok':
        usage_path = Path(path).with_name('usage.json')
        if usage_path.is_file():
            if usage_path.stat().st_size > 64 * 1024 * 1024:
                raise ValueError('oracle usage limit')
            usage = json.loads(usage_path.read_bytes())
            for row in usage.get('turns', []):
                total += integer(row.get('inputTokens')) + integer(row.get('outputTokens'))
            available = True
        else:
            history = Path(path).with_name('chat_history.jsonl')
            if history.is_file():
                for row in lines(history, counts):
                    if isinstance(row.get('usage'), dict):
                        total += sum(claude_usage(row['usage']))
                        available = True
    return dict(counts, tokens=total if available else None, tools=tools, waits=waits,
                wall_seconds=max(0, last-first) if first is not None else 0)


def compare(raw, doc):
    errors = []
    if any(doc.get('counts', {}).get(k, 0) for k in ('limited_spans', 'limited_tokens', 'limited_turns')):
        return ['normalized limits reached']
    if (raw['tokens'] or 0) != sum(doc.get('token_totals', {}).values()):
        errors.append('own token total')
    actual = [(str(s.get('call_id', '')), s['activity'][5:], s['start'], s['end'])
              for s in doc.get('spans', []) if s['activity'].startswith('tool:')]
    if actual != raw['tools']:
        errors.append('tool IDs or intervals')
    actual = [(s['start'], s['end'], s.get('start_record_id', ''), s.get('end_record_id', ''))
              for s in doc.get('spans', []) if s['activity'] == 'waiting for resume']
    if actual != raw['waits']:
        errors.append('resume boundary IDs or intervals')
    if not math.isclose(doc.get('wall_seconds', 0), raw['wall_seconds'], abs_tol=1e-6):
        errors.append('raw session extent')
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--agent', choices=('codex', 'claude', 'grok'), required=True)
    parser.add_argument('--file', required=True)
    parser.add_argument('--normalized', help='normalized per-file document; compares own, not tree totals')
    args = parser.parse_args()
    try:
        raw = audit(args.agent, args.file)
        errors = []
        if args.normalized:
            path = Path(args.normalized)
            if path.stat().st_size > 64 * 1024 * 1024:
                raise ValueError('oracle normalized limit')
            errors = compare(raw, json.loads(path.read_bytes()))
        print(json.dumps({'agent': args.agent, 'status': 'mismatch' if errors else 'pass' if args.normalized else 'raw',
                          'records': raw['records'], 'malformed': raw['malformed'], 'tokens': raw['tokens'],
                          'tool_calls': len(raw['tools']), 'tool_seconds': sum(t[3]-t[2] for t in raw['tools']),
                          'resume_waits': len(raw['waits']), 'resume_seconds': sum(t[1]-t[0] for t in raw['waits']),
                          'wall_seconds': raw['wall_seconds'], 'mismatches': errors}))
        return bool(errors)
    except (OSError, ValueError, TypeError, KeyError) as error:
        print(json.dumps({'status': 'error', 'reason': type(error).__name__}))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
