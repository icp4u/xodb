"""Read-only agent transcript adapters. No command from a transcript is executed.

The native agent-time window embeds this standard-library helper. Its stdout is
one bounded JSON document; diagnostics are data for the native log/UI boundary.
"""
import argparse
import collections
import copy
import datetime
import difflib
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sys
import tempfile
from urllib.parse import unquote

MAX_LINE = 16 * 1024 * 1024
MAX_SPANS = 150000
MAX_TURNS = 20000
MAX_SESSIONS = 10000
MAX_FLEET_SESSIONS = 32
MAX_LABEL = 60
CACHE_VERSION = 3  # Bump when adapter accounting or summary semantics change.
REDACT = False  # --redact: search patterns are free text and may carry identifiers
TOKEN_KEYS = ('fresh input', 'cached input', 'cache write', 'output', 'reasoning')


def compact(text, limit=MAX_LABEL):
    text = ' '.join(str(text).split())
    return text if len(text) <= limit else text[:limit - 1] + '…'


def safe_text(text):
    """Credential removal is unconditional, including the expanded label."""
    text = str(text)
    text = re.sub(r'(?i)(authorization\s*:\s*)(?:bearer\s+|basic\s+)?[^\s\"\';&|]+', r'\1[secret]', text)
    text = re.sub(r'(?i)((?:--?(?:token|password|passwd|secret|api[-_]key)|\b\w*(?:_KEY|_TOKEN|_SECRET|_PASSWORD))\s*(?:=|\s)\s*)("[^"\n]*"|\'[^\'\n]*\'|[^\s;&|]+)', r'\1[secret]', text)
    text = re.sub(r'(?i)(https?://)[^\s/@:]+:[^\s/@]+@', r'\1[secret]@', text)
    text = re.sub(r'/(?:home|Users)/[^/\s\"\']+', '~', text)
    # Opaque credential-shaped values need no flag to be private.
    return re.sub(r'\b(?:sk-[\w-]{12,}|gh[pousr]_[\w]{20,})\b', '[secret]', text)


def short_path(word):
    # Temp/work directory names vary per run; the basename keeps labels stable.
    if word.startswith(('/', '~/')) or (word.startswith('$') and '/' in word):
        return Path(word).name or '/'
    return word


def inline_purpose(body):
    if 'Client(' in body or 'tools/call' in body or 'jsonrpc' in body:
        return 'MCP client'
    if re.search(r'write_text|write_bytes|apply_patch|\.write\(', body):
        return 'edit files'
    if 'json' in body:
        match = re.search(r'[\"\']([^\"\'\n]+\.json)[\"\']', body)
        return 'json parse' + (' of ' + short_path(match[1]) if match else '')
    imports = re.findall(r'(?:^|\n)\s*(?:import|from)\s+([\w.]+)', body)
    return 'uses ' + ', '.join(dict.fromkeys(imports[:3])) if imports else 'inline script'


class ShellWord(str):
    """A word stays a word even when its quoted content is an operator."""


def shell_tokens(source):
    out, word = [], []
    quote, active, i = None, False, 0
    while i < len(source):
        ch = source[i]
        if ch == '\\' and quote != "'":
            if i+1 == len(source): raise ValueError('unfinished escape')
            if source[i+1] != '\n': word.append(source[i+1]); active=True
            i += 2; continue
        if quote:
            if ch == quote: quote=None
            else: word.append(ch)
            i += 1; continue
        if ch in "'\"": quote=ch; active=True; i+=1; continue
        if ch == '#' and not active:
            i=source.find('\n',i)
            if i<0:break
            continue
        if ch.isspace() or ch in ';&|()<>':
            if active: out.append(ShellWord(''.join(word))); word=[]; active=False
            if ch == '\n': out.append(';')
            elif not ch.isspace():
                token=ch
                if i+1<len(source) and source[i:i+2] in ('&&','||','>>','<<','>&','<&',';;','|&'):
                    token=source[i:i+2]; i+=1
                out.append(token)
        else: word.append(ch); active=True
        i+=1
    if quote: raise ValueError('unfinished quote')
    if active:out.append(ShellWord(''.join(word)))
    return out


HEREDOC = re.compile(r'(?<!<)<<(-?)[ \t]*([\"\']?)([A-Za-z_]\w*)\2')
FILTERS = {'head', 'tail', 'grep', 'rg', 'wc', 'sort', 'uniq', 'cut', 'sed', 'awk', 'tr', 'fold', 'tee', 'less', 'cat', 'column', 'jq', 'xargs', 'nl', 'fmt'}
FILE_OPS = {'cp', 'mv', 'mkdir', 'touch', 'rm', 'chmod', 'chown', 'ln', 'install', 'rsync'}


def split_heredocs(text):
    """Bodies leave the shell text; '<< \x01N' marks where body N was."""
    lines, out, bodies, i = text.split('\n'), [], [], 0
    while i < len(lines):
        line, pending = lines[i], []
        def mark(m):
            pending.append((m[3], m[1] == '-', len(bodies) + len(pending)))
            return '<< \x01%d' % (len(bodies) + len(pending) - 1)
        marked = HEREDOC.sub(mark, line)
        j, found = i + 1, []
        for word, tabs, _ in pending:
            k = j
            while k < len(lines) and (lines[k].lstrip('\t') if tabs else lines[k]).strip() != word: k += 1
            if k == len(lines): break
            found.append(lines[j:k]); j = k + 1
        if pending and len(found) == len(pending):
            out.append(marked); bodies += ['\n'.join(b) for b in found]; i = j
        else:
            out.append(line); i += 1
    return '\n'.join(out), bodies


def summarizeCommand(text, bodies=None):
    """Shell tokenization, never evaluation. Labels have a deterministic cap.

    Unknown grammar remains visible as 'shell compound', not a guessed command.
    full is also safe: script bodies and unrecognized arguments are not exposed.
    """
    text = str(text)[:MAX_LINE]
    if bodies is None:
        # Credentials go before parsing, so no argument position can keep one.
        text, bodies = split_heredocs(safe_text(text))
    try:
        tokens = shell_tokens(text)
    except ValueError:
        return {'class': 'other', 'label': 'shell compound (unparsed)', 'full': 'shell compound (unparsed)'}
    segments, segment, piped = [], [], False
    for token in tokens:
        if type(token) is str and token in (';', '&&', '||', '|', '|&', '&', '(', ')'):
            if segment: segments.append((segment, piped))
            segment, piped = [], token in ('|', '|&')
        else: segment.append(token)
    if segment: segments.append((segment, piped))

    def inline(name, script):
        purpose = inline_purpose(script)
        return ('edit' if purpose == 'edit files' else 'script'), f'{name} inline ({len(script.splitlines())} lines): {purpose}'

    def describe(words, piped=False, depth=0):
        if depth > 8: return 'other', 'nested shell'
        # Redirections are not arguments: keep the output target and heredoc.
        kept, target, body = [], None, None
        it = iter(range(len(words)))
        for i in it:
            w = words[i]
            if type(w) is str and w in ('>', '>>', '<', '<<', '>&', '<&', '&>'):
                if kept and kept[-1].isdigit() and len(kept) > 1: kept.pop()
                nxt = words[i+1] if i + 1 < len(words) else ''
                if w == '<<' and nxt.startswith('\x01') and nxt[1:].isdigit() and int(nxt[1:]) < len(bodies): body = bodies[int(nxt[1:])]
                elif w in ('>', '>>'): target = nxt
                next(it, None)
            else: kept.append(w)
        words = kept
        while words:
            name = Path(words[0]).name
            if re.match(r'^[A-Za-z_]\w*=', words[0]): words.pop(0); continue
            if name in ('env', 'sudo', 'nice', 'timeout', 'time', 'command', 'nohup', 'exec', 'stdbuf', 'ionice'):
                words.pop(0)
                values = {'-u', '-g', '-n', '--user', '--group', '--adjustment', '-k', '--kill-after', '--signal', '-s', '-o', '-f', '-c'}
                while words and words[0].startswith('-'):
                    option = words.pop(0)
                    if option in values and words and not (name == 'sudo' and option == '-n'): words.pop(0)
                if name == 'timeout' and words: words.pop(0)
                continue
            if name == 'gate-slot.sh':
                cls, label = describe(words[2:], piped, depth+1)
                return 'gate', label
            if name in ('bash', 'sh', 'zsh') and len(words) > 2 and words[1] in ('-c', '-lc', '-ec'):
                result = summarizeCommand(words[2], bodies)
                return result['class'], result['full']
            break
        if not words: return 'setup', 'shell setup'
        name = Path(words[0]).name
        args = words[1:]
        if name in ('cd', 'export', 'umask', 'set', 'echo', 'printf', 'pwd', 'sleep', 'true', 'unset', 'local', 'shopt', 'trap', 'wait'):
            return 'setup', name
        if piped and name in FILTERS: return 'setup', name
        if name in ('cat', 'tee') and body is not None and target:
            return 'edit', f'write {short_path(target)} ({len(body.splitlines())} lines)'
        if name in ('python', 'python3', 'node', 'ruby', 'perl') and (body is not None or '-c' in args):
            script = body if body is not None else args[args.index('-c')+1] if args.index('-c')+1 < len(args) else ''
            return inline(name, script)
        if name in ('bash', 'sh', 'zsh') and body is not None:
            inner = summarizeCommand(body, [])
            return inner['class'], f'{name} script ({len(body.splitlines())} lines): {inner["label"]}'
        if name == 'ssh':
            # Do not retain host/user/identity names even in non-redacted labels.
            i = 0
            while i < len(args) and args[i].startswith('-'):
                i += 2 if args[i] in ('-i', '-p', '-o', '-F', '-l', '-J', '-L', '-R', '-D', '-E', '-S', '-W', '-b', '-c', '-m', '-O', '-Q', '-w') else 1
            remote = ' '.join(args[i+1:]).split()
            if body is not None and (not remote or Path(remote[0]).name in ('bash', 'sh', 'zsh', 'python', 'python3', 'perl')):
                shell = Path(remote[0]).name if remote else 'sh'
                if shell.startswith('python') or shell == 'perl': inner = inline(shell, body)[1]
                else: inner = summarizeCommand(body, [])['label'] + f' ({len(body.splitlines())} lines)'
            else: inner = summarizeCommand(' '.join(args[i+1:]), bodies)['label'] if remote else 'session'
            return 'ssh/remote', 'ssh remote: ' + inner
        if name == 'git':
            while args and args[0].startswith('-'):
                args = args[2:] if args[0] in ('-C', '-c', '--git-dir', '--work-tree') else args[1:]
            flags = [a for a in args[1:] if a in ('--stat', '--short', '--cached', '--staged', '--check', '--name-only', '--oneline', '--index')]
            return 'git', ' '.join(['git'] + args[:1] + flags)
        if name in ('release-check', 'build') and ('scripts/' in words[0] or name == 'release-check'):
            chosen = args[:1]
            if '--only' in args:
                at = args.index('--only')
                chosen += args[at:at+2]
            return ('gate' if name == 'release-check' else 'build'), ' '.join(['scripts/' + name] + chosen)
        if name in ('zig', 'cargo', 'go', 'cmake', 'make', 'ninja', 'npm'):
            selected = [a for a in args if a in ('build', 'test', 'check', 'run', '--build', '--install') or a.startswith('-Doptimize=')]
            return ('test' if 'test' in selected else 'build'), ' '.join([name] + selected[:4])
        if name in ('python', 'python3', 'bash', 'sh', 'node', 'ruby', 'perl'):
            rest = list(args)
            while rest and rest[0].startswith('-'):
                if rest.pop(0) == '-m' and rest: rest[0] = '-m ' + rest[0]; break
            script = rest[0] if rest else ''
            cls = 'test' if script.startswith('tests/') or 'test' in Path(script).name else 'other'
            return cls, name + ' ' + short_path(script)
        if name == 'find':
            roots = []
            for a in args:
                if a.startswith('-') or a in ('(', '!'): break
                roots.append(short_path(a))
            return 'search', ' '.join(['find'] + roots[:2])
        if name in ('rg', 'grep', 'fd'):
            vals = [a for a in args if not a.startswith('-')]
            if REDACT and vals: vals[0] = '…'
            return 'search', ' '.join([name] + [short_path(a) for a in vals[:2]])
        if name in ('cat', 'head', 'tail', 'ls', 'stat', 'wc', 'less', 'sed'):
            files = [short_path(a) for a in args if not a.startswith('-')]
            return 'read', ' '.join([name] + files[-2:])
        if name in ('apply_patch', 'patch'):
            return 'edit', name
        if name in FILE_OPS:
            return 'fs', ' '.join([name] + [short_path(a) for a in args if not a.startswith('-')][-1:])
        if name.startswith('kl-') or name.startswith('qemu'):
            return 'lab/qemu', ' '.join([name] + args[:1])
        if name in ('apt', 'apt-get', 'pacman', 'pip', 'pip3', 'brew'):
            return 'install', ' '.join([name] + args[:1])
        return 'other', short_path(words[0])

    choices = [describe(s, p) for s, p in segments]
    choices = [c for c in choices if c[0] != 'setup'] or [('other', 'shell setup')]
    rank = {'gate': 9, 'test': 8, 'build': 7, 'lab/qemu': 6, 'ssh/remote': 6, 'edit': 5, 'script': 4.5, 'git': 4, 'search': 3, 'fs': 2.5, 'read': 2, 'other': 1}
    cls, label = max(choices, key=lambda c: rank.get(c[0], 1))
    cls = {'fs': 'edit', 'script': 'other'}.get(cls, cls)
    full = compact(safe_text(label), 240)
    return {'class': cls, 'label': compact(full), 'full': full}


def tool_detail(name, value):
    if isinstance(value, str):
        try: value = json.loads(value)
        except ValueError: pass
    if isinstance(value, dict):
        for key in ('cmd', 'command'):
            if key in value: return summarizeCommand(value[key])
        for key in ('file_path', 'path', 'filename', 'target_file'):
            if key in value:
                label = compact(safe_text(short_path(str(value[key]))))
                return {'class': 'file', 'label': label, 'full': label}
    if isinstance(value, str):
        matches = re.findall(r"""\b(?:cmd|command)\s*:\s*("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\x60(?:\\.|[^\x60\\])*\x60)""", value)
        if matches:
            def literal(s):
                if s.startswith('"'):
                    try: return json.loads(s)
                    except ValueError: pass # JavaScript permits escapes JSON does not.
                escapes = {'n':'\n','r':'\r','t':'\t'}
                return re.sub(r'\\(.)',lambda m:escapes.get(m[1],m[1]),s[1:-1])
            summaries = [summarizeCommand(literal(m)) for m in matches]
            # A JS orchestration is one recorded call; do not invent sub-timings.
            result = summaries[0].copy()
            if len(summaries) > 1:
                result['label'] = compact(result['label'] + f' (+{len(summaries)-1} commands)')
                result['full'] = compact('; '.join(s['label'] for s in summaries), 240)
            return result
        if name.lower() in ('bash', 'exec_command', 'shell', 'execute_command'):
            return summarizeCommand(value)
        calls = re.findall(r'\btools\.([A-Za-z_]\w*)\s*\(',value)
        if calls:
            label=compact(' + '.join(dict.fromkeys(calls)))
            return {'class':'edit' if 'apply_patch' in calls else 'other','label':label,'full':label}
    return {'class': 'other', 'label': compact(safe_text(name)), 'full': compact(safe_text(name))}


def timestamp(value):
    if isinstance(value, (float, int)) and math.isfinite(value): return value / 1000 if value > 1e11 else value
    if isinstance(value, str):
        try: return datetime.datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
        except ValueError: pass
    return None


def records(path, counts):
    with Path(path).open('rb') as stream:
        while True:
            line = stream.readline(MAX_LINE + 1)
            if not line: break
            if len(line) > MAX_LINE:
                counts['oversize'] += 1
                while line and not line.endswith(b'\n'): line = stream.readline(MAX_LINE + 1)
                continue
            counts['records'] += 1
            try:
                value = json.loads(line)
                if not isinstance(value, dict): raise ValueError()
            except (ValueError, UnicodeError):
                counts['malformed'] += 1
                continue
            yield value


def union(intervals):
    end, total = None, 0.0
    for a, b in sorted(intervals):
        if end is None or a > end: total += max(0, b-a)
        elif b > end: total += b-end
        end = max(end if end is not None else b, b)
    return total


def token_parts(usage, agent):
    def n(key): return max(0, int(usage.get(key, 0) or 0))
    cached = n('cached_input_tokens') if agent == 'codex' else n('cache_read_input_tokens')
    write = n('cache_write_input_tokens') if agent == 'codex' else n('cache_creation_input_tokens')
    if agent != 'codex' and 'cache_creation_input_tokens' not in usage and isinstance(usage.get('cache_creation'),dict):
        write = sum(max(0,int(v or 0)) for k,v in usage['cache_creation'].items() if k in ('ephemeral_1h_input_tokens','ephemeral_5m_input_tokens'))
    reasoning = n('reasoning_output_tokens') if agent == 'codex' else n('thinking_tokens')
    fresh = max(0, n('input_tokens') - cached - write) if agent == 'codex' else n('input_tokens')
    return dict(zip(TOKEN_KEYS, (fresh, cached, write, max(0, n('output_tokens')-reasoning), reasoning)))


INJECTED = re.compile(r'\s*(<[A-Za-z][\w-]*>|# AGENTS\.md instructions)')


def prompt_text(content, limit=100):
    """The typed prompt: harness-injected blocks (<environment_context>,
    <system-reminder>, AGENTS.md, caveats) are not titles."""
    if isinstance(content, str): content = [{'type': 'text', 'text': content}]
    if isinstance(content, list):
        texts = [str(x.get('text', '')) for x in content if isinstance(x,dict) and x.get('type') in ('text', 'input_text', 'output_text')]
        return compact(safe_text(' '.join(t for t in texts if not INJECTED.match(t))), limit)
    return ''


PACKET = re.compile(r'\b(?:[A-Z]{1,8}\d+(?:-[A-Z0-9]+)*|[A-Z][A-Z0-9]{1,}(?:-[A-Z0-9]+)+)\b')
# Technical tokens and plain all-caps phrases that look like packet names.
NOT_PACKETS = re.compile(r'(?:UTF|SHA|MD|CRC|ISO|RFC|CVE|IPV|MP|H|X|X86|ARM|AMD|AARCH|PCIE|USB|DDR|F)-?\d+(?:-\d+)*|'
                         r'(?:READ|WRITE|OPT|NON|RE|PRE|POST|FOLLOW|END|ALL|AT|NO|SELF|MULTI|CROSS|ACCEPT|HIGH|LOW|TOP|LONG|SHORT)-[A-Z-]+')


def packet_tag(prompt):
    """A visible heuristic, not a guessed inbox/task database association.

    The first name with a digit wins (A33-M1, KG2); names without digits
    (KG-HANG) are a fallback. A turn naming two packets keeps the first.
    """
    fallback = None
    for match in PACKET.finditer(prompt[:4096]):
        name = match[0]
        if NOT_PACKETS.fullmatch(name): continue
        if any(ch.isdigit() for ch in name): return name
        fallback = fallback or name
    return fallback or 'unlabelled'


def forks_copy(tokens, spans, children):
    """Forked children replay the spawner's history with the same message and
    tool ids; charge each id once, to the earliest owner (parents first)."""
    seen_msg = {r['id'] for r in tokens if r.get('id')}
    seen_call = {x['call_id'] for x in spans if x['call_id']}
    queue = list(children)
    while queue:
        doc = queue.pop(0); queue += doc['children']
        # Streamed records repeat an id within one transcript; only ids
        # already charged to an earlier transcript are copies.
        keep, mine = [], set()
        for row in doc['tokens']:
            if row.get('id') in seen_msg:
                for k, v in row['weights'].items(): doc['token_totals'][k] = doc['token_totals'].get(k, 0) - v
                doc['counts']['copied_usage'] = doc['counts'].get('copied_usage', 0) + 1
            else:
                if row.get('id'): mine.add(row['id'])
                keep.append(row)
        doc['tokens'] = keep
        seen_msg |= mine
        kept = []
        for x in doc['spans']:
            if x['call_id'] and x['call_id'] in seen_call:
                doc['agent_seconds'] -= x['end'] - x['start']
                doc['counts']['copied_calls'] = doc['counts'].get('copied_calls', 0) + 1
            else: kept.append(x)
        seen_call |= {x['call_id'] for x in kept if x['call_id']}
        doc['spans'] = kept
        if doc.get('forked') and doc.get('spawn_time') is not None:
            # The parent call is explicit evidence of when this fork began.
            # Copied model/wait prefixes are not work by the new child. Unique
            # tool/usage IDs remain governed by ID deduplication, not by time.
            cutoff=doc['spawn_time'];kept=[];removed=0
            for span in doc['spans']:
                if span['activity']=='model (inferred)' or span['activity'].startswith('waiting for '):
                    old=span['end']-span['start'];span['start']=max(span['start'],cutoff)
                    removed+=old-max(0,span['end']-span['start'])
                    if span['end']<=span['start']:continue
                kept.append(span)
            doc['spans']=kept
            for turn in doc['turns']:
                turn['start']=max(turn['start'],cutoff);turn['end']=max(turn['end'],cutoff)
            doc['counts']['copied_prefix_microseconds']=round(removed*1e6)
            doc['agent_seconds']=sum(s['end']-s['start'] for s in kept if not s['activity'].startswith('waiting for '))+sum(b-a for a,b in doc.get('omitted_intervals',[]))


def rollup(doc):
    usage=collections.Counter(doc['token_totals'])
    counts=collections.Counter(doc['counts'])
    seconds=doc['agent_seconds']
    for child in doc['children']:
        rollup(child)
        usage.update(child['tree_token_totals']);counts.update(child['tree_counts'])
        seconds+=child['tree_agent_seconds']
    doc.update(tree_token_totals=dict(usage),tree_counts=dict(counts),tree_agent_seconds=seconds,
               token_available=doc['token_available'] or any(c['token_available'] for c in doc['children']))


class Budget:
    """Shared across the root and its children, not multiplied per subagent."""
    def __init__(self): self.spans = 0; self.tokens = 0; self.turns = 0; self.keys = 0


class Session:
    def __init__(self, agent, path, budget=None):
        self.agent, self.path = agent, Path(path)
        self.title, self.project = '', ''
        self.turns, self.spans, self.tokens = [], [], []
        self.counts = collections.Counter()
        self.pending = {}
        self.current = None
        self.first, self.last = None, None
        self.usage = collections.Counter()
        self.token_available = False
        self.children = []
        self.omitted, self.omitted_usage, self.omitted_work = [], [], []
        self.budget = budget or Budget()

    def touch(self, t, extend=True):
        if t is not None:
            self.first = min(self.first if self.first is not None else t, t)
            self.last = max(self.last if self.last is not None else t, t)
            if extend and self.current is not None: self.current['end'] = max(self.current['end'], t)

    def turn(self, t, title='', record_id='', task=None):
        if t is None: return
        if self.current is not None: self.finish(self.current['end'], True)
        if self.budget.turns >= MAX_TURNS:
            self.counts['limited_turns'] += 1
            return
        if self.turns and t < self.turns[-1]['end']:
            # A queued prompt can carry its typing time, before the previous turn ended.
            self.counts['out_of_order_turns'] += 1
            t = self.turns[-1]['end']
        self.current = {'id': len(self.turns), 'start': t, 'end': t, 'title': title or 'turn', 'incomplete': True,'task':task or packet_tag(title)}
        if record_id: self.current['start_record_id'] = str(record_id)
        self.turns.append(self.current)
        self.budget.turns += 1
        if title and not self.title: self.title = title

    def finish(self, t, incomplete=False, record_id=''):
        if self.current is None: return
        self.current['end'] = max(self.current['start'], t or self.current['end'])
        self.current['incomplete'] = incomplete
        if record_id: self.current['end_record_id'] = str(record_id)
        self.counts['unfinished_tools'] += len(self.pending)
        self.pending.clear()
        self.current = None

    def span(self, start, end, activity, detail='', call_id='', turn=None, category='', full='', start_record_id='', end_record_id=''):
        if start is None or end is None: return
        if self.budget.spans >= MAX_SPANS or len(self.spans) >= MAX_SPANS:
            self.counts['limited_spans'] += 1
            # Not drawn, but still counted: totals must not depend on the shared budget.
            if not activity.startswith('waiting for '): self.omitted.append((start, max(start,end)))
            if activity.startswith('tool:') or activity == 'permission wait':
                self.omitted_work.append({'start':start,'end':max(start,end),'turn':turn if turn is not None else self.current['id'] if self.current else -1,'activity':activity})
            return
        self.spans.append({'start': start, 'end': max(start,end), 'turn': turn if turn is not None else self.current['id'] if self.current else -1,
                           'activity': activity, 'detail': compact(safe_text(detail)), 'class': category, 'full': compact(safe_text(full),240), 'call_id': str(call_id)})
        if start_record_id: self.spans[-1]['start_record_id'] = str(start_record_id)
        if end_record_id: self.spans[-1]['end_record_id'] = str(end_record_id)
        self.budget.spans += 1

    def call(self, t, call_id, name, data):
        if self.current is None or t is None: return
        if len(self.pending) >= MAX_SPANS:
            self.counts['limited_spans'] += 1
            return
        detail = tool_detail(name, data)
        if call_id in self.pending: self.counts['duplicate_calls'] += 1
        self.pending[call_id] = (t, name, detail, self.current['id'])

    def result(self, t, call_id):
        call = self.pending.pop(call_id, None)
        if not call:
            self.counts['unmatched_results'] += 1
            return
        start, name, detail, turn = call
        self.span(start, t, 'tool:' + name, detail['label'], call_id, turn, category=detail['class'],full=detail['full'])

    def usage_row(self, t, parts, detail='model call', turn=None):
        self.token_available = True
        self.usage.update(parts)
        if turn is None: turn = self.current['id'] if self.current else max(-1,len(self.turns)-1)
        if self.budget.tokens < MAX_SPANS:
            self.tokens.append({'time': t or self.last or 0, 'turn': turn, 'detail': detail, 'weights': parts})
            self.budget.tokens += 1
        else:
            self.counts['limited_tokens'] += 1
            self.omitted_usage.append((t or self.last or 0, parts))

    def complete(self):
        if self.current is not None: self.finish(self.current['end'], True)
        # Compute complements using unions, not the sum of overlapping calls.
        by_turn = collections.defaultdict(list)
        # Omitted (budget) tool intervals still occupy their turn: no model time is inferred under them.
        for span in self.spans + self.omitted_work:
            if span['activity'].startswith('tool:') or span['activity'] == 'permission wait': by_turn[span['turn']].append(span)
        for turn in self.turns:
            spans = by_turn[turn['id']]
            cursor = turn['start']
            for span in sorted(spans, key=lambda s:s['start']):
                a, b = max(turn['start'],span['start']), min(turn['end'],span['end'])
                if a > cursor: self.span(cursor,a,'model (inferred)',turn=turn['id'])
                cursor = max(cursor,b)
            if cursor < turn['end']: self.span(cursor,turn['end'],'model (inferred)',turn=turn['id'])
            turn['tool_seconds'] = union((max(turn['start'],s['start']),min(turn['end'],s['end'])) for s in spans if s['activity'].startswith('tool:'))
            by_name = collections.defaultdict(list)
            for s in spans:
                if s['activity'].startswith('tool:'): by_name[s['activity'][5:]].append((max(turn['start'],s['start']),min(turn['end'],s['end'])))
            turn['tools'] = {n:union(v) for n,v in by_name.items()}
        for left,right in zip(self.turns,self.turns[1:]):
            if right['start'] > left['end']:
                self.span(left['end'],right['start'],'waiting for resume' if right.get('resume') else 'waiting for user',turn=-1,
                          start_record_id=left.get('end_record_id',''),end_record_id=right.get('start_record_id',''))
        return self

    def document(self):
        agent_seconds = sum(s['end']-s['start'] for s in self.spans if not s['activity'].startswith('waiting for ')) + sum(b-a for a,b in self.omitted)
        tree_usage, tree_counts = self.usage.copy(), self.counts.copy()
        for child in self.children:
            tree_usage.update(child['tree_token_totals'])
            tree_counts.update(child['tree_counts'])
        return {'agent':self.agent,'title':self.title or 'session','project':safe_text(self.project),
                'start':self.first or 0,'end':self.last or 0,'turns':self.turns,'spans':self.spans,'tokens':self.tokens,
                'token_totals':dict(self.usage),'token_available':self.token_available or any(c['token_available'] for c in self.children),'counts':dict(self.counts),
                'wall_seconds':max(0,(self.last or 0)-(self.first or 0)),
                'agent_seconds':agent_seconds,
                'tree_agent_seconds':agent_seconds+sum(c['tree_agent_seconds'] for c in self.children),
                'tree_token_totals':dict(tree_usage), 'tree_counts':dict(tree_counts),
                'children':self.children, 'omitted_intervals':[list(x) for x in self.omitted],
                'omitted_usage':[[t,w] for t,w in self.omitted_usage]}


def codex(path, budget=None):
    s = Session('codex',path,budget)
    state = {'previous': {}, 'produced': []}
    for row in records(path,s.counts): codex_record(s, state, row)
    return s.complete()


def codex_record(s, state, row):
    previous, produced = state['previous'], state['produced']
    p = row.get('payload') or {}
    if not isinstance(p,dict): s.counts['malformed'] += 1; return
    kind, sub = row.get('type'), p.get('type')
    t = timestamp(row.get('timestamp'))
    if t is None and kind in ('event_msg','response_item'): s.counts['missing_timestamps'] += 1
    # A new turn starts before its timestamp can extend an unfinished one (POC parity).
    if kind == 'event_msg' and sub == 'task_started': s.turn(t)
    s.touch(t)
    if kind == 'session_meta': s.project = str(p.get('cwd','')); return
    if kind == 'event_msg' and sub == 'task_started': pass
    elif kind == 'event_msg' and sub in ('task_complete','turn_aborted'): s.finish(t, sub == 'turn_aborted')
    elif kind == 'event_msg' and sub == 'token_count':
        info = p.get('info') or {}
        total = info.get('total_token_usage')
        if isinstance(total,dict):
            s.token_available = True
            delta = {k:max(0,int(v or 0)-previous.get(k,0)) for k,v in total.items() if isinstance(v,(int,float))}
            if any(int(total.get(k,0) or 0) < v for k,v in previous.items()):
                s.counts['usage_resets'] += 1
                delta = {k:int(v) for k,v in total.items() if isinstance(v,(int,float))}
            previous = state['previous'] = {k:int(v) for k,v in total.items() if isinstance(v,(int,float))}
            if any(delta.values()):
                s.usage_row(t, token_parts(delta,'codex'), compact('; '.join(produced)) or 'model call')
                produced.clear()
        elif isinstance(info.get('last_token_usage'),dict):
            s.usage_row(t,token_parts(info['last_token_usage'],'codex'),compact('; '.join(produced)) or 'model call')
            produced.clear()
    elif kind == 'response_item' and sub in ('function_call','custom_tool_call'):
        s.call(t,p.get('call_id'),str(p.get('name','unknown')),p.get('input',p.get('arguments','')))
        if len(produced) < 32: produced.append(tool_detail(str(p.get('name','unknown')),p.get('input',p.get('arguments','')))['label'])
    elif kind == 'response_item' and sub in ('function_call_output','custom_tool_call_output'): s.result(t,p.get('call_id'))
    elif kind == 'response_item' and sub == 'message':
        if p.get('role') == 'user' and s.current and s.current['title'] == 'turn':
            title = prompt_text(p.get('content'))
            s.current['title'] = title or 'turn'
            s.current['task'] = packet_tag(prompt_text(p.get('content'),4096))
            if not s.title: s.title = title
    elif kind == 'compacted': s.counts['compactions'] += 1
    elif kind in ('turn_context','world_state','token_usage_record') or (kind == 'response_item' and sub == 'reasoning') or (kind == 'event_msg' and sub in ('item_completed','thread_settings_applied','user_message','agent_message','agent_reasoning','context_compacted')):
        s.counts['metadata'] += 1
    else: s.counts['unknown'] += 1


def claude(path, children=True, budget=None):
    s = Session('claude',path,budget)
    links = {}
    usages = {}
    for row in records(path,s.counts): claude_record(s, usages, links, row)
    s.complete()
    if children: claude_children(s, links)
    return s


def claude_record(s, usages, links, row):
    t = timestamp(row.get('timestamp'))
    kind = row.get('type')
    msg = row.get('message') or {}
    content = msg.get('content',[]) if isinstance(msg,dict) else []
    blocks = content if isinstance(content,list) else []
    results = [b for b in blocks if isinstance(b,dict) and b.get('type') == 'tool_result']
    # A prompt starts its turn before its timestamp can extend an open one:
    # the idle gap before a resumed child is not model time.
    if kind == 'user' and isinstance(msg,dict) and not results and t is not None:
        if not row.get('isMeta'):
            if s.current is not None and s.current.get('resume') and not s.current.get('worked'):
                # Harness metadata just ahead of a typed prompt: the wait was for the user.
                s.current.update(resume=False,title=prompt_text(content) or 'turn',task=packet_tag(prompt_text(content,4096)))
                s.counts['resumes'] -= 1
            else: s.turn(t,prompt_text(content),row.get('uuid',''),packet_tag(prompt_text(content,4096)))
        elif s.current is None:
            # A resume is metadata, but after handback/end_turn it starts
            # work. Metadata during an active tool must not split that tool.
            resumed = bool(s.turns)
            # Harness text (notifications, reminders) is not a prompt title.
            s.turn(t,'',row.get('uuid',''))
            if resumed and s.current is not None:
                s.current.update(resume=True,title='resumed work')
                s.counts['resumes'] += 1
    # Attachments and bookkeeping can arrive while idle; they do not extend a turn.
    s.touch(t, kind in ('user','assistant'))
    if not s.project: s.project = str(row.get('cwd',''))
    if t is None and kind in ('user','assistant'): s.counts['missing_timestamps'] += 1
    if not isinstance(msg,dict): s.counts['malformed'] += 1; return
    if kind == 'user':
        handback = False
        for b in results:
            call_id = b.get('tool_use_id')
            pending = s.pending.get(call_id)
            handback |= bool(pending and pending[1] == 'SubagentHandback')
            # Claude reports the child agent id in the tool result metadata.
            meta = row.get('toolUseResult') or {}
            if isinstance(meta,dict):
                ident = meta.get('agentId') or meta.get('resumedAgentId')
                if ident: links.setdefault(str(ident),str(call_id))
            text = str(b.get('content',''))
            match = re.search(r'agentId:\s*([\w-]+)',text)
            if match: links.setdefault(match[1],str(call_id))
            s.result(t,call_id)
        if handback:
            s.counts['handbacks'] += 1
            s.finish(t,record_id=row.get('uuid',''))
    elif kind == 'assistant':
        if s.current is None and t is not None: s.turn(t)
        if s.current is not None: s.current['worked'] = True
        usage = msg.get('usage')
        if isinstance(usage,dict):
            # Streaming records repeat a message id; retain the final/max
            # counters per call, not one input charge per content block.
            ident = str(msg.get('id') or row.get('requestId') or row.get('uuid'))
            old = usages.get(ident)
            parts = token_parts(usage,'claude')
            if old:
                delta = {k:max(0,parts[k]-old[k]) for k in TOKEN_KEYS}
                usages[ident] = {k:max(parts[k],old[k]) for k in TOKEN_KEYS}
            else: delta = parts; usages[ident] = parts
            s.usage_row(t,delta)
            if s.tokens and s.tokens[-1]['weights'] is delta: s.tokens[-1]['id'] = ident
        for b in blocks:
            if not isinstance(b,dict): continue
            if b.get('type') == 'tool_use':
                s.call(t,b.get('id'),str(b.get('name','unknown')),b.get('input',{}))
                if s.tokens: s.tokens[-1]['detail'] = tool_detail(str(b.get('name','unknown')),b.get('input',{}))['label']
        if msg.get('stop_reason') == 'end_turn': s.finish(t,record_id=row.get('uuid',''))
    elif kind == 'system':
        if row.get('subtype') in ('turn_duration','stop_hook_summary'): s.finish(t,record_id=row.get('uuid',''))
        if row.get('subtype') == 'compact_boundary': s.counts['compactions'] += 1
        s.counts['metadata'] += 1
    elif kind in ('agent-name','ai-title','atis-latch','attachment','file-history-delta','file-history-snapshot','last-prompt','mode','permission-mode','queue-operation','summary','progress'):
        s.counts['metadata'] += 1
    else: s.counts['unknown'] += 1


def claude_children(s, links, child_reader=None):
    directory = s.path.with_suffix('')/'subagents'
    if directory.is_dir():
        files = sorted(directory.glob('agent-*.jsonl'))
        s.counts['limited_children'] += max(0,len(files)-256)
        docs, parents = {}, {}
        for child in files[:256]:
            name = child.stem.removeprefix('agent-')
            doc = child_reader(child, s.budget) if child_reader else claude(child,False,s.budget).document()
            meta = {}
            meta_path=child.with_suffix('.meta.json')
            if meta_path.is_file():
                try:
                    with meta_path.open('rb') as f: data=f.read(1024*1024+1)
                    if len(data)>1024*1024: s.counts['oversize']+=1
                    else:
                        value=json.loads(data)
                        if isinstance(value,dict):meta=value
                        else:s.counts['malformed']+=1
                except (OSError,ValueError,UnicodeError):s.counts['malformed']+=1
            doc['parent_call_id'] = meta.get('toolUseId') or links.get(name)
            doc['subagent_name'] = compact(safe_text(meta.get('description') or meta.get('agentType') or 'subagent'))
            doc['forked'] = bool(meta.get('isFork'))
            docs[name]=doc
            parents[name]=str(meta.get('parentAgentId') or '').removeprefix('agent-')
        for name,doc in docs.items():
            parent=parents[name]
            visited={name}
            cursor=parent
            while cursor in docs and cursor not in visited and len(visited)<8:
                visited.add(cursor);cursor=parents[cursor]
            invalid=cursor in visited or len(visited)>=8
            owner=docs.get(parent) if not invalid else None
            spans=owner['spans'] if owner is not None else s.spans
            spawn=next((row for row in spans if row['call_id']==doc['parent_call_id']),None) if doc['parent_call_id'] else None
            linked=spawn is not None
            if spawn is not None:doc['spawn_time']=spawn['start']
            if not linked:s.counts['unlinked_subagents']+=1
            if invalid:s.counts['invalid_subagent_parent']+=1
            if owner is not None:owner['children'].append(doc)
            else:s.children.append(doc)
        forks_copy(s.tokens, s.spans, s.children)
        for doc in s.children:rollup(doc)


def grok(path, budget=None):
    s = Session('grok',path,budget)
    permission = {}
    for row in records(path,s.counts): grok_record(s, permission, row)
    return grok_complete(s, permission)


def grok_record(s, permission, row):
    t = timestamp(row.get('ts',row.get('timestamp')))
    if t is None: s.counts['missing_timestamps'] += 1
    kind = row.get('type')
    if kind == 'turn_started': s.turn(t)
    s.touch(t)
    if kind == 'turn_started': pass
    elif kind == 'turn_ended': s.finish(t, row.get('outcome') not in ('completed','success','ok'))
    elif kind == 'tool_completed':
        duration = row.get('duration_ms')
        if t is not None and isinstance(duration,(int,float)) and duration >= 0:
            s.span(t-duration/1000,t,'tool:'+str(row.get('tool_name','unknown')),call_id=row.get('tool_call_id',''))
        else: s.counts['malformed'] += 1
    elif kind == 'permission_requested': permission[str(row.get('tool_name','unknown'))] = t
    elif kind == 'permission_resolved':
        start = permission.pop(str(row.get('tool_name','unknown')),None)
        if start is not None: s.span(start,t,'permission wait')
        else: s.counts['unmatched_permissions'] += 1
    elif kind in ('loop_started','phase_changed','first_token','tool_started','yolo_toggled','session_started','session_ended'):
        s.counts['metadata'] += 1
    else: s.counts['unknown'] += 1


def grok_complete(s, permission, checkpoint=None):
    path = s.path
    s.counts['unfinished_permissions'] += len(permission)
    # Events carry precise timing but arguments live in the adjacent history.
    history = Path(path).with_name('chat_history.jsonl')
    wanted = {span['call_id']:span for span in s.spans if span['call_id']}
    active_prompt='';active_task='unlabelled'
    if checkpoint is not None:
        s.counts.update(checkpoint.session.counts)
        state = checkpoint.history
        s.title = state['title']
        for ident,detail,prompt,task in state['calls']:
            span = wanted.get(ident)
            if span is None: continue
            span.update(detail=detail['label'],**{'class':detail['class']},full=detail['full'])
            if prompt and 0<=span['turn']<len(s.turns):
                s.turns[span['turn']].update(title=prompt,task=task)
        if not grok_usage(s,path,probe=True):
            for parts in state['usage']: s.usage_row(None,parts)
    elif history.is_file():
        for row in records(history,s.counts):
            if row.get('type') == 'user' and not s.title:
                s.title = prompt_text(row.get('content'))
            if row.get('type') == 'user' and not row.get('synthetic_reason'):
                prompt=prompt_text(row.get('content'))
                if prompt:active_prompt=prompt;active_task=packet_tag(prompt_text(row.get('content'),4096))
            for call in row.get('tool_calls',[]) or []:
                if not isinstance(call,dict): continue
                span = wanted.get(str(call.get('id','')))
                if span is not None:
                    detail = tool_detail(str(call.get('name','unknown')),call.get('arguments',{}))
                    span['detail'] = detail['label']
                    span['class'] = detail['class']
                    span['full'] = detail['full']
                    if active_prompt and 0<=span['turn']<len(s.turns):
                        s.turns[span['turn']]['title']=active_prompt
                        s.turns[span['turn']]['task']=active_task
            if isinstance(row.get('usage'),dict) and not grok_usage(s,path,probe=True):
                s.usage_row(None,token_parts(row['usage'],'grok'))
    grok_usage(s,path)
    # Project directories are the URL-encoded working directory.
    s.project = unquote(Path(path).parent.parent.name)
    return s.complete()


def grok_usage(s, path, probe=False):
    """usage.json beside events.jsonl: per-turn model-call totals (1-based turnNumber).

    inputTokens includes cached reads and cache creation; outputTokens includes
    reasoning (totalTokens = input + output), as in Codex usage.
    """
    usage = Path(path).with_name('usage.json')
    if not usage.is_file() or usage.stat().st_size > 64 * 1024 * 1024: return False
    if probe: return True
    try: doc = json.loads(usage.read_bytes())
    except (ValueError, UnicodeError): s.counts['malformed'] += 1; return False
    if not isinstance(doc,dict) or not isinstance(doc.get('turns'),list): s.counts['unknown'] += 1; return False
    keys = (('inputTokens','input_tokens'),('cachedReadTokens','cached_input_tokens'),('cacheCreationTokens','cache_write_input_tokens'),('outputTokens','output_tokens'),('reasoningTokens','reasoning_output_tokens'))
    for row in doc['turns']:
        if not isinstance(row,dict) or not isinstance(row.get('turnNumber'),int): s.counts['malformed'] += 1; continue
        index = row['turnNumber'] - 1
        if not 0 <= index < len(s.turns): s.counts['unmatched_usage'] += 1; index = -1
        parts = token_parts({b:row.get(a,0) for a,b in keys},'codex')
        if any(parts.values()): s.usage_row(timestamp(row.get('endedAt')),parts,'model calls',index)
    return True


def read_session(agent,path,budget=None):
    return {'codex':codex,'claude':claude,'grok':grok}[agent](path,budget=budget).document()


class RebuildTail(Exception): pass
class TailLimit(Exception): pass


class TailFile:
    """In-memory decoder checkpoint; raw messages are never retained."""
    def __init__(self, agent, path, budget):
        self.session = Session(agent, path, budget)
        self.codex = {'previous': {}, 'produced': []}
        self.usages, self.links, self.permission = {}, {}, {}
        self.history = {'title':'','prompt':'','task':'unlabelled','calls':[],'usage':[]}
        self.offset = 0
        self.stat = None
        self.head = self.edge = b''
        self.discard = False
        self.keys = 0

    def update(self):
        s = self.session
        used = 0
        with s.path.open('rb') as stream:
            st = os.fstat(stream.fileno())
            identity = (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns)
            if identity == self.stat: return 0
            if self.stat:
                if identity[:2] != self.stat[:2] or st.st_size < self.stat[2]: raise RebuildTail()
                if st.st_size == self.stat[2]: raise RebuildTail()
                # Ordinary append logs: guard the prefix and consumed tail too.
                # Same-size edits, rotation and truncation always rebuild.
                if stream.read(len(self.head)) != self.head: raise RebuildTail()
                used += len(self.head)
                stream.seek(max(0, self.offset - len(self.edge)))
                if stream.read(len(self.edge)) != self.edge: raise RebuildTail()
                used += len(self.edge)
            stream.seek(self.offset)
            while stream.tell() < st.st_size:
                start = stream.tell()
                line = stream.readline(min(MAX_LINE + 1, st.st_size - start))
                used += len(line)
                if self.discard:
                    self.discard = not line.endswith(b'\n')
                    self.offset = stream.tell()
                    continue
                if len(line) > MAX_LINE:
                    s.counts['oversize'] += 1
                    self.discard = not line.endswith(b'\n')
                    self.offset = stream.tell()
                    continue
                if not line.endswith(b'\n'): break
                self.offset = stream.tell()
                s.counts['records'] += 1
                try:
                    row = json.loads(line)
                    if not isinstance(row,dict): raise ValueError()
                except (ValueError,UnicodeError):
                    s.counts['malformed'] += 1
                    continue
                if s.agent == 'codex': codex_record(s, self.codex, row)
                elif s.agent == 'claude': claude_record(s, self.usages, self.links, row)
                elif s.agent == 'grok-history': self.history_record(row)
                else: grok_record(s, self.permission, row)
                # Bound retained state, not harmless metadata record count.
                keys = len(self.usages)+len(self.links)+len(self.permission)+len(self.codex['previous'])+len(self.history['calls'])+len(self.history['usage'])
                s.budget.keys += keys-self.keys
                self.keys = keys
                if s.budget.keys >= MAX_SPANS or s.budget.spans >= MAX_SPANS or s.budget.tokens >= MAX_SPANS or s.budget.turns >= MAX_TURNS: raise TailLimit()
            stream.seek(0)
            self.head = stream.read(min(4096,self.offset))
            stream.seek(max(0,self.offset-4096))
            self.edge = stream.read(min(4096,self.offset))
            used += len(self.head) + len(self.edge)
            self.stat = identity
        return used

    def history_record(self, row):
        state = self.history
        if row.get('type') == 'user':
            if not state['title']: state['title'] = prompt_text(row.get('content'))
            if not row.get('synthetic_reason'):
                prompt = prompt_text(row.get('content'))
                if prompt: state.update(prompt=prompt,task=packet_tag(prompt_text(row.get('content'),4096)))
        for call in row.get('tool_calls',[]) or []:
            if not isinstance(call,dict): continue
            if len(state['calls']) >= MAX_SPANS: raise TailLimit()
            detail = tool_detail(str(call.get('name','unknown')),call.get('arguments',{}))
            state['calls'].append((str(call.get('id','')),detail,state['prompt'],state['task']))
        if isinstance(row.get('usage'),dict):
            if len(state['usage']) >= MAX_SPANS: raise TailLimit()
            state['usage'].append(token_parts(row['usage'],'grok'))

    def snapshot(self, budget):
        # Completion infers gaps and closes open turns. Do it on a copy, so
        # a result appended later can still match its pending tool call.
        s = copy.deepcopy(self.session)
        s.budget = budget
        budget.spans += len(s.spans)
        budget.tokens += len(s.tokens)
        budget.turns += len(s.turns)
        return s


class LiveTail:
    """One selected session, retained only for the lifetime of its live helper."""
    def __init__(self, agent, path):
        self.agent, self.path = agent, Path(path)
        self.files = {}
        self.fingerprint = ''
        self.fallback = False

    def refresh(self):
        try: return self._refresh()
        except (OSError,ValueError,KeyError,TypeError):
            self.files.clear()
            self.fingerprint = ''
            raise

    def _refresh(self):
        before = source_fingerprint(self.agent,self.path)
        if before == self.fingerprint: return {'unchanged': True}
        paths = [self.path]
        if self.agent == 'claude':
            directory = self.path.with_suffix('')/'subagents'
            paths += sorted(directory.glob('agent-*.jsonl'))[:256]
        elif self.agent == 'grok' and self.path.with_name('chat_history.jsonl').is_file():
            paths.append(self.path.with_name('chat_history.jsonl'))
        used = 0
        # A new child/history file does not invalidate any consumed prefix.
        # Removal (including displacement at the child cap) still rebuilds.
        rebuilt = not self.files or not set(self.files).issubset(paths)
        if rebuilt: self.files.clear()
        if not self.fallback:
            for attempt in range(2):
                if not self.files:
                    budget = Budget()
                    self.files = {p:TailFile('grok-history' if self.agent=='grok' and p!=self.path else self.agent,p,budget) for p in paths}
                else:
                    budget = self.files[self.path].session.budget
                    self.files = {p:self.files[p] if p in self.files else TailFile('grok-history' if self.agent=='grok' and p!=self.path else self.agent,p,budget) for p in paths}
                try:
                    for file in self.files.values(): used += file.update()
                    budget = Budget()
                    root = self.files[self.path]
                    s = root.snapshot(budget)
                    if self.agent == 'grok': grok_complete(s,root.permission,self.files.get(self.path.with_name('chat_history.jsonl')))
                    else:
                        s.complete()
                        if self.agent == 'claude':
                            claude_children(s,root.links,lambda path,b:self.files[path].snapshot(b).complete().document())
                    result = s.document()
                    if any(result['tree_counts'].get(k,0) for k in ('limited_spans','limited_tokens','limited_turns')): raise TailLimit()
                    break
                except RebuildTail:
                    self.files.clear()
                    rebuilt = True
                    if attempt: raise OSError('source changed during refresh')
                except TailLimit:
                    self.files.clear()
                    self.fallback = True
                    break
        if self.fallback: result = read_session(self.agent,self.path)
        after = source_fingerprint(self.agent,self.path)
        self.fingerprint = before if before == after else ''
        result['source_fingerprint'] = self.fingerprint
        result['live_read_bytes'] = used
        result['live_mode'] = 'full (checkpoint limit)' if self.fallback else 'rebuild' if rebuilt else 'append'
        return result


def strip_internal(doc):
    if isinstance(doc,dict):
        doc.pop('omitted_intervals',None);doc.pop('omitted_usage',None)
        for child in doc.get('children',[]):strip_internal(child)


LIVE_ARRAYS = ('turns','spans','tokens')
MAX_LIVE_WIRE = 64*1024*1024


def wire_json(value):
    return json.dumps(value,separators=(',',':'),ensure_ascii=True,allow_nan=False).encode()


class WireSnapshot:
    """Only fingerprints and small metadata survive between wire updates."""
    def __init__(self, doc):
        self.meta = {k:v for k,v in doc.items() if k not in (*LIVE_ARRAYS,'children')}
        encoded = wire_json(self.meta)
        self.size = len(encoded)
        self.rows = {}
        digest = hashlib.sha256(encoded)
        for name in LIVE_ARRAYS:
            rows = doc.get(name,[])
            hashes = []
            self.size += 1+len(wire_json(name))+3+max(0,len(rows)-1)
            for row in rows:
                encoded = wire_json(row)
                self.size += len(encoded)
                hashes.append(hashlib.sha256(encoded).digest())
            self.rows[name] = hashes
            digest.update(name.encode())
            for value in hashes: digest.update(value)
        self.children = [WireSnapshot(child) for child in doc.get('children',[])]
        self.size += 1+len(wire_json('children'))+3+max(0,len(self.children)-1)+sum(c.size for c in self.children)
        for child in self.children: digest.update(child.digest)
        self.digest = digest.digest()

    def patch(self, old, doc):
        if self.digest == old.digest: return None
        patch = {'meta': self.meta}
        for name in LIVE_ARRAYS:
            before, after = old.rows[name], self.rows[name]
            start = 0
            while start < min(len(before),len(after)) and before[start] == after[start]: start += 1
            if start == len(before) == len(after): continue
            end_before,end_after = len(before),len(after)
            while end_before > start and end_after > start and before[end_before-1] == after[end_after-1]:
                end_before -= 1;end_after -= 1
            # Matching blocks avoid resending the model/wait suffix when a new
            # tool span is inserted before it. Common ends make append O(n).
            matcher = difflib.SequenceMatcher(None,before[start:end_before],after[start:end_after],autojunk=False)
            ops = [[start+a,start+b,doc.get(name,[])[start+c:start+d]]
                   for tag,a,b,c,d in matcher.get_opcodes() if tag != 'equal']
            patch[name] = {'length':len(before),'ops':ops}
        if len(self.children) != len(old.children):
            # Child names can sort before existing siblings. Match unchanged
            # documents by content, not index, and retain them in native memory.
            matcher = difflib.SequenceMatcher(None,[c.digest for c in old.children],
                                             [c.digest for c in self.children],autojunk=False)
            kept = {b+i:a+i for a,b,size in matcher.get_matching_blocks() for i in range(size)}
            patch['children'] = {'length':len(old.children),'items':[
                {'old':kept[i]} if i in kept else {'reset':child}
                for i,child in enumerate(doc.get('children',[]))]}
        else:
            changes = []
            for index,(child,previous,value) in enumerate(zip(self.children,old.children,doc.get('children',[]))):
                change = child.patch(previous,value)
                if change is not None: changes.append([index,change])
            if changes: patch['children'] = {'length':len(old.children),'patches':changes}
        return patch


class LiveWire:
    def __init__(self):
        self.previous = None
        self.generation = 0

    def encode(self, doc):
        if doc.get('unchanged'): return wire_json(doc)
        # Fingerprints are helper-local change detectors, not presentation data.
        doc.pop('source_fingerprint',None)
        current = WireSnapshot(doc)
        if current.size > MAX_LIVE_WIRE: raise ValueError('snapshot limit')
        generation = self.generation+1
        frame = {'wire':1,'generation':generation,'size':current.size}
        if self.previous is None or doc.get('live_mode') != 'append': frame['reset'] = doc
        else:
            frame['base'] = self.generation
            frame['patch'] = current.patch(self.previous,doc) or {'meta':current.meta}
        data = wire_json(frame)
        if len(data) > MAX_LIVE_WIRE: raise ValueError('wire limit')
        self.previous,self.generation = current,generation
        return data


def live_serve(agent, path):
    tail = LiveTail(agent,path)
    wire = LiveWire()
    while sys.stdin.buffer.readline(32) == b'refresh\n':
        result = None
        try:
            result = tail.refresh()
            strip_internal(result)
            data = wire.encode(result)
        except (OSError,ValueError,KeyError,TypeError):
            data = b'{"failure":"AgentLogReadFailed"}'
        sys.stdout.buffer.write(len(data).to_bytes(4,'big'))
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
        # No full document or encoded reply retained while waiting for a poll.
        del result,data


def date_window(value):
    if not value:return -math.inf,math.inf
    since,separator,until=value.partition('..')
    def day(text):return datetime.datetime.combine(datetime.date.fromisoformat(text),datetime.time(),datetime.timezone.utc).timestamp()
    left=day(since) if since else -math.inf
    right=day(until)+86400 if separator and until else math.inf
    if right<=left:raise ValueError('invalid date range')
    return left,right


def extent(doc):
    children=[extent(c) for c in doc['children']]
    return min([doc['start']]+[a for a,_ in children]),max([doc['end']]+[b for _,b in children])


def clip_document(doc, left, right):
    """Window projection retains IDs, clips intervals and charges only in-window usage."""
    first,last=extent(doc)
    doc['start']=max(first,left);doc['end']=min(last,right)
    doc['wall_seconds']=max(0,doc['end']-doc['start'])
    turns=[];remap={}
    for turn in doc['turns']:
        if turn['start']>=right or turn['end']<left:continue
        old=turn['id'];turn['id']=len(turns);remap[old]=turn['id']
        turn['start']=max(left,turn['start']);turn['end']=min(right,turn['end']);turns.append(turn)
    spans=[]
    for span in doc['spans']:
        start=max(left,span['start']);end=min(right,span['end'])
        if end<=start:continue
        span.update(start=start,end=end,turn=remap.get(span['turn'],-1));spans.append(span)
    tokens=[]
    for call in doc['tokens']:
        if left<=call['time']<right:
            call['turn']=remap.get(call['turn'],-1);tokens.append(call)
    for turn in turns:
        tools=[s for s in spans if s['turn']==turn['id'] and s['activity'].startswith('tool:')]
        turn['tool_seconds']=union((s['start'],s['end']) for s in tools)
        names=collections.defaultdict(list)
        for span in tools:names[span['activity'][5:]].append((span['start'],span['end']))
        turn['tools']={name:union(intervals) for name,intervals in names.items()}
    doc.update(turns=turns,spans=spans,tokens=tokens)
    omitted=[(max(a,left),min(b,right)) for a,b in doc.get('omitted_intervals',[]) if min(b,right)>max(a,left)]
    usage=[(t,w) for t,w in doc.get('omitted_usage',[]) if left<=t<right]
    doc.update(omitted_intervals=[list(x) for x in omitted],omitted_usage=[[t,w] for t,w in usage])
    doc['token_totals']={key:sum(call['weights'].get(key,0) for call in tokens)+sum(w.get(key,0) for _,w in usage) for key in TOKEN_KEYS}
    doc['agent_seconds']=sum(s['end']-s['start'] for s in spans if not s['activity'].startswith('waiting for '))+sum(b-a for a,b in omitted)
    doc['children']=[clip_document(child,left,right) for child in doc['children'] if extent(child)[0]<right and extent(child)[1]>=left]
    rollup(doc)
    return doc


def fleet(options):
    left,right=date_window(options.get('dates',''))
    docs=[];budget=Budget();failures=0
    entries=options.get('sessions',[])[:MAX_FLEET_SESSIONS]
    for entry in entries:
        try:
            doc=read_session(entry['agent'],entry['path'],budget)
            first,last=extent(doc)
            if first<right and last>=left:docs.append(clip_document(doc,left,right))
        except (OSError,ValueError,KeyError,TypeError):failures+=1
    starts=[d['start'] for d in docs];ends=[d['end'] for d in docs]
    start=left if math.isfinite(left) else min(starts,default=0)
    end=right if math.isfinite(right) else max(ends,default=start)
    root={'agent':'fleet','title':f'Fleet / {len(docs)} sessions / usage unknown in {sum(not d["token_available"] for d in docs)}',
          'project':'','start':start,'end':max(start,end),'wall_seconds':max(0,end-start),'agent_seconds':0,
          'turns':[],'spans':[],'tokens':[],'token_totals':{},'token_available':any(d['token_available'] for d in docs),
          'counts':{'limited_sessions':max(0,options.get('matched',len(entries))-len(entries)),'failed_sessions':failures},'children':docs,
          'display_turn_count':sum(len(d['turns']) for d in docs),'session_count':len(docs)}
    rollup(root)
    return root


def adapter_hash():
    """Any adapter edit invalidates cached summaries; no manual bump needed."""
    try: source = Path(__file__).read_bytes()
    except NameError:
        # The native app runs the embedded source with -c; the code is in orig_argv.
        argv = getattr(sys, 'orig_argv', [])
        source = argv[argv.index('-c') + 1].encode() if '-c' in argv[:-1] else b''
    return hashlib.sha256(source).hexdigest()[:16] if source else 'unknown'


ADAPTER_HASH = adapter_hash()


def source_fingerprint(agent, path):
    """Only the requested transcript and adapter-known sidecars affect a hit."""
    path=Path(path)
    sources=[path]
    if agent=='grok':sources += [path.with_name('chat_history.jsonl'),path.with_name('usage.json')]
    if agent=='claude':
        directory=path.with_suffix('')/'subagents'
        sources.append(directory)
        if directory.is_dir():
            for child in sorted(directory.glob('agent-*.jsonl'))[:256]:sources += [child,child.with_suffix('.meta.json')]
    digest=hashlib.sha256(f'{CACHE_VERSION}:{ADAPTER_HASH}:{agent}'.encode())
    for source in sources:
        try:
            st=source.stat()
            identity=(st.st_dev,st.st_ino,st.st_size,st.st_mtime_ns,st.st_ctime_ns)
        except FileNotFoundError:identity=None
        digest.update(str(source).encode());digest.update(repr(identity).encode())
    return digest.hexdigest()


def numeric_summary(doc):
    first,last=extent(doc)
    return {'start':doc['start'],'end':doc['end'],'duration':doc['wall_seconds'],
            'tokens':sum(doc['tree_token_totals'].values()) if doc['token_available'] else None,
            'turn_count':len(doc['turns']),'activity_start':first,'activity_end':last}


def dates(summary):
    start=summary.get('start')
    started=datetime.datetime.fromtimestamp(start,datetime.timezone.utc).isoformat(timespec='seconds').replace('+00:00','Z') if start is not None else ''
    end=summary.get('activity_end',summary.get('end'))
    ended=datetime.datetime.fromtimestamp(end,datetime.timezone.utc).date().isoformat() if end is not None else ''
    first=summary.get('activity_start',start)
    activity_date=datetime.datetime.fromtimestamp(first,datetime.timezone.utc).date().isoformat() if first is not None else ''
    return {'date':started[:10],'started':started,'ended':ended,'activity_date':activity_date}


class IndexCache:
    """Derived numeric metadata only; no transcript paths, prompts or commands.

    Each private, atomic entry is <=4 KiB, with at most MAX_SESSIONS entries.
    Bad entries are misses. Cache failures never prevent opening a work log.
    """
    def __init__(self, root=None):
        # XDG: a relative XDG_CACHE_HOME is invalid and ignored (as remote_source.zig does).
        base=os.environ.get('XDG_CACHE_HOME','')
        self.root=Path(root) if root is not None else Path(base if base.startswith('/') else Path.home()/'.cache')/'xodb/agent-time/index-v1'
    def entry(self, agent, path):
        key=hashlib.sha256((agent+'\0'+str(Path(path).resolve())).encode()).hexdigest()
        return self.root/(key+'.json')
    def load(self, agent, path, fingerprint):
        try:
            with self.entry(agent,path).open('rb') as f:data=f.read(4097)
            if len(data)>4096:return None
            row=json.loads(data);s=row['summary']
            if row['version']!=CACHE_VERSION or row['fingerprint']!=fingerprint:return None
            if set(s)!={'start','end','duration','tokens','turn_count','activity_start','activity_end'}:return None
            if not all(isinstance(s[k],(int,float)) and not isinstance(s[k],bool) and math.isfinite(s[k]) for k in ('start','end','duration','activity_start','activity_end')):return None
            if s['end']<s['start'] or s['duration']<0:return None
            if s['tokens'] is not None and (type(s['tokens']) is not int or s['tokens']<0):return None
            if type(s['turn_count']) is not int or not 0<=s['turn_count']<=MAX_TURNS:return None
            dates(s) # Reject corrupt out-of-range timestamps before a catalog hit.
            return s
        except (OSError,ValueError,KeyError,TypeError,OverflowError):return None
    def store(self, agent, path, fingerprint, summary):
        temporary=None
        try:
            data=json.dumps({'version':CACHE_VERSION,'fingerprint':fingerprint,'summary':summary},allow_nan=False,separators=(',',':')).encode()
            if len(data)>4096:return False
            self.root.mkdir(parents=True,exist_ok=True,mode=0o700)
            destination=self.entry(agent,path)
            fd,temporary=tempfile.mkstemp(prefix='.index-',dir=self.root)
            with os.fdopen(fd,'wb') as f:f.write(data)
            os.replace(temporary,destination);temporary=None
            # Evict only this cache's hash-named derived entries, never source logs.
            entries=[p for p in self.root.glob('*.json') if re.fullmatch(r'[0-9a-f]{64}\.json',p.name)]
            if len(entries)>MAX_SESSIONS:
                dated=[]
                for entry in entries:
                    try:dated.append((entry.stat().st_mtime_ns,entry))
                    except FileNotFoundError:pass
                for _,entry in sorted(dated)[:max(0,len(dated)-MAX_SESSIONS)]:
                    try:entry.unlink()
                    except FileNotFoundError:pass
            return True
        except (OSError,ValueError):return False
        finally:
            if temporary is not None:
                try:os.unlink(temporary)
                except OSError:pass


def index_session(agent, path, cache=None):
    cache=cache or IndexCache()
    before=source_fingerprint(agent,path)
    cached=cache.load(agent,path,before)
    if cached is not None:
        return {**peek(path,agent),**cached,**dates(cached),'indexed':True,'cached':True,'cache_state':'cached'}
    doc=read_session(agent,path)
    summary=numeric_summary(doc)
    stable=before==source_fingerprint(agent,path)
    state=('indexed' if cache.store(agent,path,before,summary) else 'cache unavailable') if stable else 'source changed; uncached'
    return {**summary,**dates(summary),'title':doc['title'],'project':doc['project'],'indexed':True,'cached':False,'cache_state':state}


def peek(path, agent):
    """Cheap browser labels; usage/turn totals stay unknown until indexed."""
    path = Path(path)
    title, project, start, end = '', '', None, None
    def chunks(source):
        with source.open('rb') as stream:
            head = stream.read(256 * 1024)
            size = stream.seek(0,2)
            offset=max(0,size-64*1024)
            stream.seek(offset)
            tail = stream.read(64*1024)
        first=head.splitlines()
        last=tail.splitlines()
        if not head.endswith(b'\n'):first=first[:-1]
        if offset:last=last[1:]
        if not tail.endswith(b'\n'):last=last[:-1]
        return first+last
    for line in chunks(path):
        try: row=json.loads(line)
        except (ValueError,UnicodeError):continue
        if not isinstance(row,dict):continue
        t=timestamp(row.get('timestamp',row.get('ts')))
        if t is not None:
            start=min(start if start is not None else t,t)
            end=max(end if end is not None else t,t)
        p=row.get('payload') or {}
        if not isinstance(p,dict):continue
        if agent=='codex':
            if row.get('type')=='session_meta':project=str(p.get('cwd',''))
            if not title and p.get('role')=='user':title=prompt_text(p.get('content'))
            if not title and p.get('type')=='user_message':title=compact(safe_text(p.get('message','')),100)
        elif agent=='claude':
            if not project:project=str(row.get('cwd',''))
            msg=row.get('message') or {}
            if not title and row.get('type')=='user' and isinstance(msg,dict):title=prompt_text(msg.get('content'))
    if agent=='grok':
        project=unquote(path.parent.parent.name)
        history=path.with_name('chat_history.jsonl')
        if history.is_file():
            for line in chunks(history):
                try:row=json.loads(line)
                except (ValueError,UnicodeError):continue
                if isinstance(row,dict) and row.get('type')=='user':
                    title=prompt_text(row.get('content'))
                    if title:break
    started=datetime.datetime.fromtimestamp(start,datetime.timezone.utc).isoformat(timespec='seconds').replace('+00:00','Z') if start is not None else ''
    return {'title':title or agent+' session','project':safe_text(project),'start':start,'end':end,**dates({'start':start,'end':end}),'indexed':False,'duration':None,'tokens':None,'turn_count':None}


def discover():
    roots = [('codex',Path(os.environ.get('CODEX_HOME',Path.home()/'.codex'))/'sessions','rollout-*.jsonl'),
             ('claude',Path.home()/'.claude/projects','*.jsonl'),
             ('grok',Path.home()/'.grok/sessions','events.jsonl')]
    result = []
    cache=IndexCache()
    for agent,root,pattern in roots:
        for path in root.rglob(pattern):
            if agent == 'claude' and 'subagents' in path.parts: continue
            if len(result) >= MAX_SESSIONS: break
            try: stat = path.stat()
            except OSError: continue # Session removed during the read-only scan.
            try: summary=peek(path,agent)
            except OSError: summary={'title':'unreadable session','project':'','indexed':False,'start':None,'end':None,'duration':None,'tokens':None,'turn_count':None}
            try: cached=cache.load(agent,path,source_fingerprint(agent,path))
            except OSError:cached=None
            if cached is not None:summary.update(cached,**dates(cached),indexed=True,cached=True,cache_state='cached')
            result.append({'agent':agent,'path':str(path),'modified':stat.st_mtime,'bytes':stat.st_size,**summary})
    return sorted(result,key=lambda r:(-r['modified'],r['path']))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--agent',choices=('codex','claude','grok'))
    parser.add_argument('--file')
    parser.add_argument('--list',action='store_true')
    parser.add_argument('--index',action='store_true')
    parser.add_argument('--fleet')
    parser.add_argument('--if-fingerprint')
    parser.add_argument('--live',action='store_true')
    parser.add_argument('--redact',action='store_true')
    args = parser.parse_args()
    global REDACT
    REDACT = args.redact
    if args.live:
        if not args.agent or not args.file: parser.error('--live needs --agent and --file')
        return live_serve(args.agent,args.file)
    if args.list: result = {'sessions':discover()}
    elif args.fleet:result=fleet(json.loads(args.fleet))
    elif args.agent and args.file:
        if args.index:result=index_session(args.agent,args.file)
        else:
            before=source_fingerprint(args.agent,args.file)
            if args.if_fingerprint and args.if_fingerprint==before:result={'unchanged':True}
            else:
                result=read_session(args.agent,args.file)
                result['source_fingerprint']=before if before==source_fingerprint(args.agent,args.file) else ''
    else: parser.error('--agent and --file, or --list, required')
    strip_internal(result)
    json.dump(result,sys.stdout,separators=(',',':'),ensure_ascii=True)


if __name__ == '__main__': main()
