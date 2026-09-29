#!/usr/bin/env python3
"""Disposable, synthetic-only OpenClaw/Camofox benchmark runner.

Never points at a live browser or account store. Run from `devenv shell --`.
Output contains metrics only; no transcripts, tokens, oracle key or host paths.
"""

import argparse
import hashlib
import hmac
import json
import os
import re
import secrets
import signal
import socket
import sqlite3
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from contextlib import contextmanager
from pathlib import Path


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
IMAGE = 'localhost/wave-os/camofox-browser:1.15.0'
PORT_INSIDE = 38891
TOOLS = ('read', 'web_search', 'web_fetch', 'camofox_create_tab', 'camofox_snapshot',
         'camofox_click', 'camofox_type', 'camofox_navigate', 'camofox_scroll',
         'camofox_close_tab', 'camofox_list_tabs')
EXTRA_TOOLS = {'camofox_select', 'browser_execute'}
SAFE_FACT_NAMES = {'target', 'location', 'service', 'date', 'summary', 'destination', 'arrival',
                   'travel', 'reference', 'attendee', 'seat', 'access', 'ticket', 'meal',
                   'session', 'venue', 'reminder', 'timezone', 'contact', 'confirm', 'party',
                   'preference', 'quantity', 'label', 'search', 'time', 'filter',
                   'room_tier', 'tier', 'guests', 'origin', 'from', 'to', 'departure', 'arrivalPlace'}
AUTH_ENV = {'OPENAI_API_KEY', 'OPENROUTER_API_KEY', 'OPENCODE_API_KEY'}
PROVIDER_ENV = {'openai': 'OPENAI_API_KEY', 'openrouter': 'OPENROUTER_API_KEY',
                'opencode-go': 'OPENCODE_API_KEY'}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def pick_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def fetch_json(url, key=None, timeout=5):
    headers = {'x-fixture-key': key} if key else {}
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=timeout) as response:
        return json.load(response)


def redact(text):
    """Defense in depth for optional synthetic trace summaries; never save raw blobs."""
    if not isinstance(text, str):
        return ''
    text = re.sub(r'(?i)(authorization\s*[:=]\s*bearer\s+)\S+', r'\1[REDACTED]', text)
    text = re.sub(r'(?i)\bsk-[a-z0-9_-]{4,}\b', '[REDACTED]', text)
    text = re.sub(r'https?://[^\s"<>]+', '[URL]', text)
    text = re.sub(r'(?i)(password|passphrase|token|api[_-]?key)(["\s:=]+)[^\s,"}]+',
                  r'\1\2[REDACTED]', text)
    return text[:600]


def failure_details(envelope, stderr, exit_code, credentials=()):
    """Keep diagnostic text, never the original CLI envelope or unfiltered stderr."""
    error = envelope.get('error') if isinstance(envelope, dict) else None
    error = error if isinstance(error, dict) else {}
    kind = error.get('kind') or error.get('type')
    kind = kind if isinstance(kind, str) and re.fullmatch(r'[a-zA-Z0-9_-]{1,48}', kind) else 'unknown'

    def clean(value):
        if not isinstance(value, str):
            return ''
        for secret in credentials:
            if secret:
                value = value.replace(secret, '[REDACTED]')
        value = re.sub(r'(?i)\bsk-[a-z0-9_-]{4,}\b', '[REDACTED]', value)
        value = re.sub(r'(?i)\bBearer\s+\S+', 'Bearer [REDACTED]', value)
        value = re.sub(r'(?i)\b(?:api[_-]?key|token|password|secret)\s*[:=]\s*\S+',
                       '[REDACTED]', value)
        value = re.sub(r'(?i)\b(?:https?|file)://\S+', '[URL]', value)
        value = re.sub(r'(?<!\w)/(?:[^\s,:;()\[\]{}]+/?)+', '[PATH]', value)
        value = re.sub(r'[^\x20-\x7e]', ' ', value)
        return re.sub(r'\s+', ' ', value).strip()[:240]

    message = error.get('message')
    stderr_lines = [clean(line) for line in stderr.splitlines()[-16:]
                    if re.search(r'(?i)error|fail|HTTP|provider|model|auth|plugin', line)]
    # An HTTP status is useful even when its surrounding provider text is discarded.
    source = '\n'.join((message if isinstance(message, str) else '', stderr[-4000:]))
    status = re.search(r'(?i)\b(?:HTTP|status(?:\s+code)?|error)\s*[:=]?\s*([45]\d\d)\b', source)
    return {'kind': kind, 'exit_code': exit_code,
            'http_status': int(status[1]) if status else None,
            'message': clean(message), 'stderr_tail': [line for line in stderr_lines if line][-3:]}


def provider_block_reason(failure):
    """Classify terminal provider authorization failures, not normal model/tool refusals."""
    if not isinstance(failure, dict):
        return None
    status = failure.get('http_status')
    if status not in (401, 403):
        return None
    diagnostic = ' '.join([str(failure.get('message') or '')] +
                          [str(line) for line in (failure.get('stderr_tail') or [])])
    if status == 403 and re.search(r'(?i)workspace lifetime budget\b.{0,80}\bexceeded\b', diagnostic):
        return 'workspace_lifetime_budget_exceeded'
    return 'provider_unauthorized' if status == 401 else 'provider_forbidden'


def synthetic_contract(arguments, item, contract_mode='procedural'):
    """Only bounded fixture text and public fields; omit tab IDs and arbitrary model data."""
    if not isinstance(arguments, dict) or not isinstance(item, dict):
        return {}
    public = {key: str(value) for key, value in item.get('variables', {}).items()}
    if item.get('category') == 'forms' and 'target' in public:
        public['location'] = public['target']
    def text(value, limit=200):
        if not isinstance(value, str) or len(value) > limit or re.search(
                r'(?i)\b(?:bearer|password|passphrase|secret|token|api[_-]?key|sk-[\w-]+)\b|'
                r'(?:https?|file)://|/(?:run|Users|private|var|tmp|nix)/|[\\@]', value):
            return '[omitted]'
        return value if re.fullmatch(r'[\x20-\x7e]*', value) else '[omitted]'

    def binding(value):
        if isinstance(value, str):
            return text(value, 120)
        if isinstance(value, dict):
            return {key: text(value[key], 120) for key in ('field', 'context') if key in value}
        return '[omitted]'

    variables = arguments.get('variables')
    facts = arguments.get('facts')
    bindings = arguments.get('bindings')
    policies = arguments.get('fieldPolicies')
    success = arguments.get('success')
    keys = ({'goal', 'tabId', 'facts', 'constraints', 'bindings', 'fieldPolicies'}
            if contract_mode == 'semantic' else
            {'goal', 'modelGoal', 'tabId', 'variables', 'bindings', 'fieldPolicies',
             'executionScope', 'stopAfter', 'success', 'allowedOrigins', 'forbidActions'})
    constraints = arguments.get('constraints')
    scope = arguments.get('executionScope')
    stop_after = arguments.get('stopAfter')
    origins = arguments.get('allowedOrigins')
    forbidden = arguments.get('forbidActions')
    return {
        'contract_mode': contract_mode,
        'present_keys': sorted(set(arguments) & keys), 'unknown_key_count': len(set(arguments) - keys),
        'variable_count': len(variables) if isinstance(variables, dict) else None,
        'variable_names': [key if key in SAFE_FACT_NAMES else '[other]'
                           for key in list(variables)[:32]] if isinstance(variables, dict) else None,
        'fact_count': len(facts) if isinstance(facts, dict) else None,
        'fact_names': [key if key in SAFE_FACT_NAMES else '[other]'
                       for key in list(facts)[:32]] if isinstance(facts, dict) else None,
        'facts': {key: (public[key] if key in public and value == public[key] else '[redacted]')
                  for key, value in list(facts.items())[:32] if key in SAFE_FACT_NAMES}
        if isinstance(facts, dict) else None,
        'binding_count': len(bindings) if isinstance(bindings, dict) else None,
        'binding_names': [key if key in SAFE_FACT_NAMES else '[other]'
                          for key in list(bindings)[:32]] if isinstance(bindings, dict) else None,
        'fixture_variable_values_only': True,
        'goal': text(arguments.get('goal'), 600), 'modelGoal': text(arguments.get('modelGoal'), 360)
        if 'modelGoal' in arguments else None,
        'variables': {key: value if variables.get(key) == value else '[other]'
                      for key, value in public.items() if isinstance(variables, dict) and key in variables},
        'bindings': {key: binding(value) for key, value in list(bindings.items())[:32] if key in public}
        if isinstance(bindings, dict) else None,
        'fieldPolicies': [{'field': binding(row.get('field')), 'preserve': text(row.get('preserve'), 120)}
                          for row in policies[:32] if isinstance(row, dict)] if isinstance(policies, list) else None,
        'executionScope': {key: text(scope[key], 200 if key == 'context' else 140)
                           for key in ('title', 'context') if key in scope}
        if isinstance(scope, dict) else None,
        'stopAfter': {key: text(stop_after[key], 200 if key == 'context' else 120)
                      for key in ('click', 'context') if key in stop_after}
        if isinstance(stop_after, dict) else None,
        'allowed_origins': [('[fixture-origin]' if origin == 'http://127.0.0.1:%d' % PORT_INSIDE
                             else '[other-origin]') for origin in origins[:8]] if isinstance(origins, list) else None,
        'allowed_origins_count': len(origins) if isinstance(origins, list) else None,
        'forbid_actions': [text(action, 100) for action in forbidden[:24]]
        if isinstance(forbidden, list) else None,
        'forbid_actions_count': len(forbidden) if isinstance(forbidden, list) else None,
        'constraints': {
            'present_keys': sorted(set(constraints) & {'allowedOrigins', 'forbidActions'}),
            'unknown_key_count': len(set(constraints) - {'allowedOrigins', 'forbidActions'}),
            'allowed_origins_count': len(constraints['allowedOrigins'])
                if isinstance(constraints.get('allowedOrigins'), list) else None,
            'allowed_origins': [('[fixture-origin]' if origin == 'http://127.0.0.1:%d' % PORT_INSIDE
                                 else '[other-origin]') for origin in constraints['allowedOrigins'][:8]]
                if isinstance(constraints.get('allowedOrigins'), list) else None,
            'forbid_actions_count': len(constraints['forbidActions'])
                if isinstance(constraints.get('forbidActions'), list) else None,
            'forbid_actions': [text(value, 100) for value in constraints['forbidActions'][:24]]
                if isinstance(constraints.get('forbidActions'), list) else None,
        } if isinstance(constraints, dict) else None,
        'success': {key: (('[fixture-route:%s]' % match[1] if (match := re.fullmatch(
                            r'/run/[\w-]{8,128}/[a-z]+-\d\d/([a-z]+)', value)) else '[path]')
                         if key == 'urlPath' and isinstance(value, str) else
                         text(value, 160) if isinstance(value, str) else
                         [text(part, 160) for part in value[:16] if isinstance(part, str)] if isinstance(value, list) else
                         {text(k, 80): text(v, 120) for k, v in list(value.items())[:16]}
                         if isinstance(value, dict) else '[omitted]')
                    for key, value in success.items() if key in
                    ('urlPath', 'textIncludes', 'allText', 'fieldValues')}
        if isinstance(success, dict) else None,
    }


def oracle_actions(oracle, target):
    events = oracle['events']
    invalid = sum(event.get('valid') is False for event in events)
    wrong_views = sum(event.get('action') in ('view:detail', 'view:modal')
                      and event.get('item') not in (None, target) for event in events)
    return {'success': bool(oracle['passed']), 'mistakes': oracle['mistakes'],
            'wrong_actions': invalid + wrong_views,
            'oracle_actions': max(0, len(events) - 1)}


def transcript_metrics(db, session_id):
    """Only aggregate own session's transcript; do not return message bodies."""
    if not session_id or not db.exists():
        return {}
    conn = sqlite3.connect('file:' + str(db) + '?mode=ro', uri=True, timeout=1)
    try:
        events = [json.loads(row[0]) for row in conn.execute(
            'SELECT event_json FROM transcript_events WHERE session_id=? ORDER BY seq', (session_id,))]
    finally:
        conn.close()
    tokens, actions, snapshots, image_blocks, image_chars = [], 0, 0, 0, 0
    pending = {}
    for event in events:
        if event.get('type') != 'message':
            continue
        msg = event.get('message', {})
        if msg.get('role') == 'assistant':
            usage = msg.get('usage') or {}
            if usage:
                tokens.append(usage)
            for block in msg.get('content', []):
                if not isinstance(block, dict) or block.get('type') != 'toolCall':
                    continue
                args = block.get('arguments') or {}
                name = args.get('id', 'tool_call') if block.get('name') == 'tool_call' and isinstance(args, dict) else block.get('name', '')
                name = name.split(':')[-1] if isinstance(name, str) else ''
                if block.get('id'):
                    pending[block['id']] = name
                if name.startswith('camofox_'):
                    actions += 1
        elif msg.get('role') == 'toolResult':
            name = pending.pop(msg.get('toolCallId'), msg.get('toolName'))
            if not isinstance(name, str) or not name.endswith('camofox_snapshot'):
                continue
            snapshots += 1
            for block in msg.get('content', []):
                if not isinstance(block, dict):
                    continue
                if block.get('type') == 'image':
                    image_blocks += 1
                    image_chars += len(block.get('data', ''))
                if block.get('type') != 'text':
                    continue
                try:
                    payload = json.loads(block.get('text', ''))
                    for part in payload.get('result', {}).get('content', []):
                        if isinstance(part, dict) and part.get('type') == 'image':
                            image_blocks += 1
                            image_chars += len(part.get('data', ''))
                except (ValueError, AttributeError, TypeError):
                    pass
    prompts = [entry.get('contextUsage', {}).get('promptTokens') for entry in tokens]
    return {'turns_observed': len(tokens),
            'model_input_plus_cache': sum((u.get('input') or 0) + (u.get('cacheRead') or 0) for u in tokens),
            'prompt_peak_tokens': max((p or 0 for p in prompts), default=0),
            'camofox_actions': actions, 'snapshots_exposed': snapshots,
            'image_blocks': image_blocks, 'image_encoded_chars': image_chars}


def hosted_usage(db, session_id, catalog):
    """Per-turn OpenClaw usage; costs are catalog estimates, NOT OpenRouter billed cost."""
    if not session_id or not db.is_file():
        return []
    conn = sqlite3.connect('file:' + str(db) + '?mode=ro', uri=True, timeout=1)
    try:
        rows = conn.execute('SELECT event_json FROM transcript_events WHERE session_id=? ORDER BY seq',
                            (session_id,)).fetchall()
    finally:
        conn.close()
    row = next(iter(next(iter(catalog['providers'].values()))['models']))
    rates = row.get('cost') or {}
    result = []
    for (raw,) in rows:
        event = json.loads(raw)
        message = event.get('message') or {}
        if event.get('type') != 'message' or message.get('role') != 'assistant' or not message.get('usage'):
            continue
        usage = message['usage']
        values = {key: usage.get(key) for key in ('input', 'cacheRead', 'cacheWrite', 'output')}
        valid = all(isinstance(v, int) and v >= 0 for v in values.values() if v is not None)
        estimate = None
        if valid and all(values[key] is not None for key in ('input', 'cacheRead', 'cacheWrite', 'output')) and all(
                isinstance(rates.get(k), (float, int)) and rates[k] >= 0 for k in ('input', 'output')):
            estimate = (values['input'] * rates['input'] + values['output'] * rates['output'] +
                        (values['cacheRead'] or 0) * rates.get('cacheRead', rates['input']) +
                        (values['cacheWrite'] or 0) * rates.get('cacheWrite', rates['input'])) / 1_000_000
        result.append({**values, 'estimated_usd': round(estimate, 8) if estimate is not None else None})
    return result


def synthetic_trace(db, session_id, item=None, contract_mode='procedural'):
    """Optional compact tool-only evidence: omit typed values, images, URLs and all user/system text."""
    if not db.is_file() or not session_id:
        return []
    conn = sqlite3.connect('file:' + str(db) + '?mode=ro', uri=True, timeout=1)
    try:
        events = [json.loads(row[0]) for row in conn.execute(
            'SELECT event_json FROM transcript_events WHERE session_id=? ORDER BY seq', (session_id,))]
    finally:
        conn.close()
    result = []
    pending = {}
    for event in events:
        if event.get('type') != 'message':
            continue
        msg = event.get('message', {})
        if msg.get('role') == 'assistant':
            for block in msg.get('content', []):
                if not isinstance(block, dict) or block.get('type') != 'toolCall':
                    continue
                outer = block.get('arguments') or {}
                name = outer.get('id', '') if block.get('name') == 'tool_call' and isinstance(outer, dict) else block.get('name', '')
                name = name.split(':')[-1] if isinstance(name, str) else ''
                if block.get('id'):
                    pending[block['id']] = name
                if name not in TOOLS and name not in EXTRA_TOOLS:
                    continue
                arguments = outer.get('args', {}) if block.get('name') == 'tool_call' else outer
                if isinstance(arguments, str):
                    try:
                        arguments = json.loads(arguments)
                    except ValueError:
                        arguments = {}
                if not isinstance(arguments, dict):
                    arguments = {}
                entry = {'tool': name, 'args': {key: arguments[key] for key in
                    ('ref', 'offset', 'direction', 'amount') if key in arguments
                    and isinstance(arguments[key], (int, float, str)) and
                    (not isinstance(arguments[key], str) or re.fullmatch(r'[a-zA-Z0-9_-]{1,32}', arguments[key]))},
                    'at': msg.get('timestamp')}
                if name == 'browser_execute' and item:
                    entry['fixture_contract'] = synthetic_contract(arguments, item, contract_mode)
                result.append(entry)
        elif msg.get('role') == 'toolResult':
            name = pending.pop(msg.get('toolCallId'), msg.get('toolName'))
            if msg.get('isError'):
                result.append({'tool_error': True, 'at': msg.get('timestamp')})
            if name == 'browser_execute' and item:
                for part in msg.get('content', []):
                    if not isinstance(part, dict) or part.get('type') != 'text':
                        continue
                    try:
                        payload = json.loads(part.get('text', ''))
                        contents = payload.get('result', {}).get('content', [])
                        body = json.loads(contents[0]['text']) if contents else payload
                        if isinstance(body, dict):
                            outcome = {key: body[key] for key in
                                ('status', 'reason', 'steps', 'diagnostic_reason', 'verification')
                                if type(body.get(key)) is int and 0 <= body[key] <= 24 or
                                isinstance(body.get(key), str) and re.fullmatch(r'[a-z_]{1,48}', body[key])}
                            matched = body.get('matched_conditions')
                            if isinstance(matched, list):
                                outcome['matched_conditions'] = [value for value in matched[:4] if value in
                                    ('urlPath', 'textIncludes', 'allText', 'fieldValues')]
                            url = body.get('current_url')
                            fixture_url = isinstance(url, str) and bool(re.fullmatch(
                                r'http://127\.0\.0\.1:%d/run/[\w-]{8,128}/%s/[a-z]+'
                                % (PORT_INSIDE, re.escape(item['id'])), url))

                            def fixture_label(value, limit=120):
                                if not isinstance(value, str) or len(value) > limit or not re.fullmatch(
                                        r'[\x20-\x7e]*', value) or re.search(
                                        r'(?i)password|passphrase|secret|token|api[_-]?key|sk-[\w-]+|'
                                        r'https?://|/(?:run|Users|var|nix|tmp)/|\b[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\b', value):
                                    return '[redacted]'
                                return value

                            if fixture_url:
                                outcome['fixture_route'] = url.rsplit('/', 1)[-1]
                                for key in ('relevant_state', 'diagnostic_field'):
                                    if isinstance(body.get(key), str):
                                        outcome[key] = redact(body[key])[:240]
                                if body.get('verification') == 'action_and_fresh_observation' and isinstance(
                                        body.get('observed_action'), dict):
                                    observed = body['observed_action']
                                    outcome['observed_action'] = {key: value for key, value in
                                        ((key, observed.get(key)) for key in ('click', 'context'))
                                        if isinstance(value, str) and len(value) <= (120 if key == 'click' else 200)
                                        and re.fullmatch(r'[a-zA-Z0-9 .,;:/_-]+', value) and
                                        not re.search(r'(?i)password|passphrase|secret|token|api[_-]?key|/(?:run|Users|var|nix|tmp)/', value)}
                            if contract_mode == 'semantic' and (fixture_url or body.get('status') in
                                    ('needs_decision', 'needs_mapping')):
                                progress = body.get('progress')
                                if isinstance(progress, dict):
                                    remaining = progress.get('remaining_fact_keys')
                                    outcome['progress'] = {key: progress[key] for key in
                                        ('assignments_verified', 'pages_seen', 'remaining_facts')
                                        if type(progress.get(key)) is int and 0 <= progress[key] <= 32}
                                    if isinstance(remaining, list):
                                        outcome['progress']['remaining_fact_key_count'] = len(remaining)
                                        outcome['progress']['remaining_fact_keys'] = [key if key in SAFE_FACT_NAMES
                                            else '[other]' for key in remaining[:32] if isinstance(key, str)]
                                problem = body.get('problem')
                                if isinstance(problem, dict) and problem.get('kind') in (
                                        'missing_fact', 'ambiguous_mapping', 'unsupported_choice'):
                                    compact = {'kind': problem['kind'],
                                               'field': fixture_label(problem.get('field')),
                                               'context': fixture_label(problem.get('context'), 200)}
                                    if 'evidence' in problem:
                                        compact['evidence'] = fixture_label(problem.get('evidence'), 320)
                                    fact_keys = problem.get('fact_keys')
                                    if isinstance(fact_keys, list):
                                        compact['fact_key_count'] = len(fact_keys)
                                        compact['fact_keys'] = [key if key in SAFE_FACT_NAMES else '[other]'
                                            for key in fact_keys[:8] if isinstance(key, str)]
                                    for key in ('options', 'candidates'):
                                        entries = problem.get(key)
                                        if isinstance(entries, list):
                                            compact[key + '_count'] = len(entries)
                                            compact[key] = [{name: fixture_label(entry[name], 200) for name in
                                                ('label', 'value', 'field', 'context') if name in entry}
                                                for entry in entries[:8] if isinstance(entry, dict)]
                                    outcome['problem'] = compact
                            result.append({'executor_outcome': outcome, 'at': msg.get('timestamp')})
                    except (ValueError, IndexError, KeyError, TypeError, AttributeError):
                        pass
            if name != 'camofox_snapshot':
                continue
            for part in msg.get('content', []):
                if not isinstance(part, dict) or part.get('type') != 'text':
                    continue
                try:
                    payload = json.loads(part.get('text', ''))
                    contents = payload.get('result', {}).get('content', [])
                    inner = json.loads(contents[0]['text']) if contents else payload
                    if not re.fullmatch(r'http://127\.0\.0\.1:%d/run/[\w-]+/[a-z]+-\d\d/[a-z]+' % PORT_INSIDE,
                                        inner.get('url', '')):
                        continue
                    result.append({'snapshot_excerpt': redact(inner.get('snapshot', '')),
                                   'at': msg.get('timestamp')})
                except (ValueError, IndexError, KeyError, TypeError, AttributeError):
                    pass
    return result


def hosted_trace(db, session_id):
    """Value-free tool and usage timeline from the isolated synthetic session."""
    if not db.is_file() or not session_id:
        return []
    conn = sqlite3.connect('file:' + str(db) + '?mode=ro', uri=True, timeout=1)
    try:
        events = [json.loads(row[0]) for row in conn.execute(
            'SELECT event_json FROM transcript_events WHERE session_id=? ORDER BY seq', (session_id,))]
    finally:
        conn.close()
    timeline, pending = [], {}
    for event in events:
        if event.get('type') != 'message':
            continue
        msg = event.get('message', {})
        if msg.get('role') == 'assistant':
            usage = msg.get('usage') or {}
            record = {'role': 'assistant', 'at': msg.get('timestamp'), 'stop': msg.get('stopReason'),
                      'usage': {key: usage.get(key) for key in ('input', 'cacheRead', 'output')},
                      'prompt_tokens': (usage.get('contextUsage') or {}).get('promptTokens'), 'calls': []}
            for block in msg.get('content', []):
                if not isinstance(block, dict):
                    continue
                if block.get('type') != 'toolCall':
                    continue
                outer = block.get('arguments') or {}
                name = outer.get('id', '') if block.get('name') == 'tool_call' and isinstance(outer, dict) else block.get('name', '')
                name = name.split(':')[-1] if isinstance(name, str) else ''
                raw = outer.get('args', {}) if block.get('name') == 'tool_call' else outer
                if isinstance(raw, str):
                    try:
                        raw = json.loads(raw)
                    except ValueError:
                        raw = {}
                arguments = raw if isinstance(raw, dict) else {}
                pending[block.get('id')] = name
                detail = {'tool': name}
                if name == 'browser_execute':
                    detail['request_bytes'] = len(json.dumps(arguments).encode())
                    detail['goal_bytes'] = len(str(arguments.get('goal', '')).encode())
                    detail['model_goal_bytes'] = len(str(arguments.get('modelGoal', '')).encode())
                    variables = arguments.get('variables')
                    facts = arguments.get('facts')
                    bindings = arguments.get('bindings')
                    public_names = {'target', 'location', 'service', 'date', 'summary', 'destination',
                                    'arrival', 'travel', 'reference', 'quantity', 'party', 'time',
                                    'guest', 'seat', 'meal', 'fare', 'name', 'email', 'search', 'venue',
                                    'item', 'entry', 'label', 'notes', 'departure', 'return'}
                    detail['variable_names'] = [key if key in public_names else '[other]'
                                                 for key in list(variables)[:32]] if isinstance(variables, dict) else []
                    detail['fact_names'] = [key if key in SAFE_FACT_NAMES else '[other]'
                                            for key in list(facts)[:32]] if isinstance(facts, dict) else None
                    detail['fact_count'] = len(facts) if isinstance(facts, dict) else None
                    detail['contract_mode'] = 'semantic' if isinstance(facts, dict) else 'procedural'
                    detail['binding_count'] = len(bindings) if isinstance(bindings, dict) else 0
                    success = arguments.get('success')
                    detail['success_criteria'] = sorted(key for key in success if key in
                        ('urlPath', 'textIncludes', 'allText', 'fieldValues')) if isinstance(success, dict) else []
                elif name.startswith('camofox_'):
                    detail['argument_names'] = sorted(key for key in arguments if key in
                        ('ref', 'option', 'offset', 'direction', 'amount', 'tabId', 'url', 'text', 'value'))
                record['calls'].append(detail)
            if usage or record['calls']:
                timeline.append(record)
        elif msg.get('role') == 'toolResult':
            name = pending.pop(msg.get('toolCallId'), msg.get('toolName'))
            if name not in ('browser_execute', 'camofox_snapshot'):
                continue
            texts = [part.get('text', '') for part in msg.get('content', [])
                     if isinstance(part, dict) and part.get('type') == 'text']
            raw = '\n'.join(texts)
            record = {'role': 'result', 'tool': name, 'at': msg.get('timestamp'),
                      'error': bool(msg.get('isError')), 'output_bytes': len(raw.encode())}
            if name == 'browser_execute':
                try:
                    payload = json.loads(raw)
                    content = payload.get('result', {}).get('content', [])
                    body = json.loads(content[0]['text']) if content else payload
                    if isinstance(body, dict):
                        record['result'] = {key: body[key] for key in ('status', 'reason', 'steps')
                                            if isinstance(body.get(key), int) or isinstance(body.get(key), str)
                                            and re.fullmatch(r'[a-z_]{1,48}', body[key])}
                except (ValueError, TypeError, KeyError, IndexError, AttributeError):
                    record['result_parse_error'] = True
            timeline.append(record)
    return timeline


def private_access_profile(path, remaining_seconds):
    path = Path(path)
    status = path.lstat()
    if not path.is_file() or path.is_symlink() or status.st_uid != os.getuid() or status.st_mode & 0o077:
        raise ValueError('auth profile must be an owned regular file with no group/other access')
    credential = json.loads(path.read_text())
    if set(credential) != {'provider', 'access', 'expires', 'accountId'} or credential['provider'] != 'openai':
        raise ValueError('only access-only OpenAI OAuth profiles are supported (no refresh token)')
    if not isinstance(credential['access'], str) or not credential['access'] or not isinstance(credential['accountId'], str):
        raise ValueError('invalid access-only OAuth profile')
    if not isinstance(credential['expires'], (int, float)) or credential['expires'] < (time.time() + remaining_seconds + 90) * 1000:
        raise ValueError('OAuth access expires before the bounded task; no refresh is attempted')
    return {'provider': 'openai', 'type': 'oauth', 'access': credential['access'],
            'refresh': '', 'expires': int(credential['expires']), 'accountId': credential['accountId']}


def erase_db(db):
    for suffix in ('', '-wal', '-shm'):
        (db.parent / (db.name + suffix)).unlink(missing_ok=True)


def transcript_session_id(db):
    """Recover only an unambiguous session ID from this task's isolated transcript."""
    if not db.is_file():
        return None
    try:
        conn = sqlite3.connect('file:' + str(db) + '?mode=ro', uri=True, timeout=1)
        try:
            rows = conn.execute('SELECT DISTINCT session_id FROM transcript_events '
                                'WHERE session_id IS NOT NULL LIMIT 2').fetchall()
        finally:
            conn.close()
        return rows[0][0] if len(rows) == 1 and isinstance(rows[0][0], str) else None
    except sqlite3.Error:
        return None


def install_access_profile(openclaw, config_path, state, cwd, env, profile, model):
    db = state / 'agents/main/agent/openclaw-agent.sqlite'
    # Pinned 2026.9.4 initializes its SQLite schema on a no-auth agent exec.
    subprocess.run([openclaw, 'agent', 'exec', '--config', str(config_path), '--state-dir', str(state),
                    '--cwd', str(cwd), '--model', model, '--no-auth-env-only',
                    '--timeout', '30', '--json', 'Initialize isolated synthetic state.'],
                   env=env, capture_output=True, text=True, timeout=50, check=False)
    if not db.is_file():
        raise RuntimeError('isolated OpenClaw credential DB initialization failed')
    conn = sqlite3.connect(db)
    try:
        conn.execute('INSERT OR REPLACE INTO auth_profile_store (store_key,store_json,updated_at) VALUES (?,?,?)',
                     ('primary', json.dumps({'version': 1, 'profiles': {'openai:default': profile}}), int(time.time() * 1000)))
        conn.commit()
    finally:
        conn.close()
    db.chmod(0o600)
    return db


def model_config(config_file, model):
    """Select only public catalog rows; never copy provider keys or channel settings."""
    source = json.loads(Path(config_file).read_text())
    if set(source) != {'models'} or not isinstance(source['models'], dict):
        raise ValueError('--config must contain only a public models catalog')
    provider, sep, model_id = model.partition('/')
    if not sep or provider not in PROVIDER_ENV or not model_id:
        raise ValueError('model must be provider/model-id')
    try:
        definitions = source['models']['providers'][provider]['models']
    except (KeyError, TypeError):
        raise ValueError('public model catalog is missing selected provider') from None
    selected = [row for row in definitions if row.get('id') == model_id]
    if len(selected) != 1:
        raise ValueError('exactly one matching public model row is required')
    row = selected[0]
    allowed = {'id', 'name', 'api', 'reasoning', 'input', 'contextWindow', 'contextTokens',
               'maxTokens', 'cost', 'thinkingLevelMap', 'compat'}
    if set(row) - allowed or re.search(r'(?i)(https?://|bearer\s+|api[_-]?key|secret)', json.dumps(row)):
        raise ValueError('model row contains unknown or potentially sensitive data')
    provider_config = {'models': [row]}
    if provider == 'openrouter':
        provider_config.update({'api': 'openai-completions', 'baseUrl': 'https://openrouter.ai/api/v1'})
    return {'mode': 'merge', 'providers': {provider: provider_config}}


def contract_schema_sha256(mode):
    """Hash the actual registered source tool schema without starting a browser or model."""
    script = ('import { pathToFileURL } from "node:url"; '
              'const { registerBrowserExecutor } = await import(pathToFileURL(process.argv[1]).href); '
              'let factory; registerBrowserExecutor({ registerTool(fn) { factory = fn; } }, '
              '{ contractMode: process.argv[2], scope: () => "synthetic", decide: async () => ({}) }); '
              'console.log(JSON.stringify(factory({}).parameters));')
    result = subprocess.run(['node', '--input-type=module', '-e', script,
                             str(REPO / 'packages/browser-executor/plugin.mjs'), mode],
                            cwd=REPO, env={'PATH': os.environ.get('PATH', '/usr/bin:/bin')},
                            capture_output=True, text=True, timeout=15, check=False)
    if result.returncode:
        raise RuntimeError('source browser tool schema unavailable')
    schema = json.loads(result.stdout)
    return hashlib.sha256(json.dumps(schema, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def agent_config(models, model, plugin_path, port_number, extras, profile, executor_backend=None,
                   max_steps=8, candidate_mode='legacy', apply_prepared=False, stop_policy='success',
                   contract_mode='procedural', semantic_problem_detail='contextual'):
    tools = list(TOOLS) + list(extras)
    return {
        'agents': {'defaults': {'skipBootstrap': True, 'contextInjection': 'never', 'thinkingDefault': 'low',
                                'model': {'primary': model, 'fallbacks': []}, 'sandbox': {'mode': 'off'},
                                'systemAgent': {'agentId': 'main'}},
                   'entries': {'main': {'name': 'Synthetic Browser', 'skills': ['browser-research'],
                                        'model': {'primary': model, 'fallbacks': []},
                                        'thinkingDefault': 'low', 'sandbox': {'mode': 'off'},
                                        'tools': {'allow': tools, 'deny': ['view_image']}}}},
        'models': models,
        **({'auth': {'profiles': {'openai:default': {'provider': 'openai', 'mode': 'oauth'}}}} if profile else {}),
        'tools': {'profile': 'minimal', 'alsoAllow': tools,
                  'deny': ['browser', 'terminal', 'exec', 'process', 'write', 'edit', 'apply_patch',
                           'message', 'gateway', 'sessions_spawn', 'sessions_send', 'camofox_screenshot',
                           'camofox_evaluate', 'camofox_import_cookies', 'view_image'],
                  'fs': {'workspaceOnly': True}, 'codeMode': False,
                  'toolSearch': {'mode': 'directory', 'searchDefaultLimit': 5, 'maxSearchLimit': 10}},
        'plugins': {'enabled': True, 'allow': [model.split('/')[0], 'camofox-browser'],
                    'load': {'paths': [str(plugin_path)]}, 'entries': {'camofox-browser': {'enabled': True,
                        'config': {'autoStart': False, 'url': 'http://127.0.0.1:' + str(port_number),
                                   **({'browserExecutor': {'enabled': True, 'backend': executor_backend,
                                          'maxSteps': max_steps, 'timeoutMs': 120000, 'threshold': 0.5, 'margin': 0.05,
                                          'candidateMode': candidate_mode, 'applyPrepared': apply_prepared,
                                           'stopPolicy': stop_policy, 'contractMode': contract_mode,
                                           'semanticProblemDetail': semantic_problem_detail}}
                                       if executor_backend else {})}}}},
        'skills': {'load': {'extraDirs': [str(REPO / 'modules/home/openclaw/skills')]}}
    }


@contextmanager
def temporary_fixture(podman, connection, image, env):
    name = 'wave-browser-bench-' + uuid.uuid4().hex[:12]
    ports = {'camofox': pick_port(), 'fixture': pick_port()}
    if ports['camofox'] == ports['fixture']:
        raise RuntimeError('port collision')
    prefix = [podman, '--connection', connection]
    launched = False
    fixture = None
    try:
        proc = subprocess.run(prefix + ['run', '--detach', '--name', name, '--pull=never',
            '--cap-drop', 'AUDIT_WRITE', '--cap-drop', 'MKNOD', '--cap-drop', 'NET_RAW',
            '--cap-drop', 'NET_BIND_SERVICE', '--security-opt', 'no-new-privileges',
            '--pids-limit', '512', '--shm-size', '2g',
            '--publish', '127.0.0.1:%d:9377' % ports['camofox'],
            '--publish', '127.0.0.1:%d:%d' % (ports['fixture'], PORT_INSIDE),
            '--mount', 'type=bind,src=%s,dst=/fixture,readonly' % HERE,
            '--env', 'CAMOFOX_ACCESS_KEY', '--env', 'CAMOFOX_PORT=9377',
            '--env', 'CAMOFOX_BIND_HOST=0.0.0.0', '--env', 'CAMOFOX_INTERACTIVE=off',
            '--env', 'CAMOFOX_CRASH_REPORT_ENABLED=false',
            '--env', 'CAMOFOX_DISABLE_DEFAULT_ADDONS=true', image],
            env=env, capture_output=True, text=True, timeout=65, check=False)
        if proc.returncode:
            raise RuntimeError('disposable Camofox container failed to start')
        launched = True
        for _ in range(60):
            try:
                if fetch_json('http://127.0.0.1:%d/health' % ports['camofox'])['ok']:
                    break
            except (OSError, KeyError):
                time.sleep(1)
        else:
            raise RuntimeError('disposable Camofox health check timed out')
        fixture = subprocess.Popen(prefix + ['exec', name, 'node', '/fixture/server.js',
                                             '--host', '0.0.0.0', '--port', str(PORT_INSIDE)],
                                   env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, text=True)
        import selectors
        selector = selectors.DefaultSelector()
        selector.register(fixture.stdout, selectors.EVENT_READ)
        if not selector.select(timeout=25):
            raise RuntimeError('disposable fixture did not start')
        first = json.loads(fixture.stdout.readline())
        if not first.get('oracleKey') or not first.get('baseUrl'):
            raise RuntimeError('invalid fixture startup')
        yield ports, first['oracleKey']  # Key stays in orchestrator memory.
    finally:
        if fixture and fixture.poll() is None:
            fixture.terminate()
            try:
                fixture.wait(timeout=8)
            except subprocess.TimeoutExpired:
                fixture.kill()
        if launched:
            subprocess.run(prefix + ['stop', '--time', '3', name], env=env, capture_output=True, timeout=35, check=False)
            subprocess.run(prefix + ['rm', '-f', name], env=env, capture_output=True, timeout=35, check=False)


def sample_rss(pid):
    try:
        result = subprocess.run(['ps', '-o', 'rss=', '-p', str(pid)], capture_output=True, text=True, timeout=2)
        return int(result.stdout.strip() or 0)
    except (ValueError, subprocess.TimeoutExpired):
        return 0


def clean_up_own_tabs(port_number, access_key, session_id):
    if not session_id or not re.fullmatch(r'[a-f0-9-]{36}', session_id):
        return
    for scope in ('agent:main:explicit:' + session_id, session_id):
        identity = hmac.new(access_key.encode(), scope.encode(), hashlib.sha256).hexdigest()
        suffix = '?userId=' + identity
        headers = {'Authorization': 'Bearer ' + access_key}
        try:
            with urllib.request.urlopen(urllib.request.Request(
                    'http://127.0.0.1:%d/tabs%s' % (port_number, suffix), headers=headers), timeout=3) as response:
                payload = json.load(response)
                tabs = payload.get('tabs', []) if isinstance(payload, dict) else []
            for tab in tabs:
                tab_id = tab.get('tabId') if isinstance(tab, dict) else None
                if not isinstance(tab_id, str) or not re.fullmatch(r'[\w-]{1,128}', tab_id):
                    continue
                request = urllib.request.Request('http://127.0.0.1:%d/tabs/%s%s' % (port_number, tab_id, suffix),
                                                 headers=headers, method='DELETE')
                urllib.request.urlopen(request, timeout=3).close()
        except (OSError, ValueError, TypeError):
            pass


def run_one(args, item, ports, oracle_key, base_env, catalog, output):
    task = item['id']
    if not re.fullmatch(r'(?:[a-z]+|challenge)-\d\d', task) or item['category'] not in ('search', 'booking', 'forms', 'login', 'cart', 'spa', 'long', 'challenge'):
        raise ValueError('invalid synthetic fixture manifest')
    duration = 600 if item['category'] == 'long' else 300
    run_id = uuid.uuid4().hex
    directory = output / (task + '-' + uuid.uuid4().hex[:8])
    directory.mkdir(mode=0o700)
    home, state, cwd = (directory / name for name in ('home', 'state', 'workspace'))
    for path in (home, state, cwd):
        path.mkdir(mode=0o700)
    config_path = directory / 'config.json'
    config_path.write_text(json.dumps(agent_config(catalog, args.model, args.plugin_path,
                             ports['camofox'], args.extra_tool, bool(args.auth_profile_file), args.executor_backend,
                             args.max_steps, args.candidate_mode, args.apply_prepared, args.stop_policy,
                             args.contract_mode, args.semantic_problem_detail)))
    config_path.chmod(0o600)
    env = dict(base_env, HOME=str(home), OPENCLAW_STATE_DIR=str(state),
               OPENCLAW_CONFIG_PATH=str(config_path), CAMOFOX_ACCESS_KEY=base_env['CAMOFOX_ACCESS_KEY'])
    db = state / 'agents/main/agent/openclaw-agent.sqlite'
    start_url = 'http://127.0.0.1:%d/run/%s/%s/start' % (PORT_INSIDE, run_id, task)
    oracle_url = 'http://127.0.0.1:%d/api/%sruns/%s' % (
        ports['fixture'], 'challenge/' if item['category'] == 'challenge' else '', run_id)
    prompt = args.prompt_template.format(goal=item['goal'], start_url=start_url,
                                         variables=json.dumps(item['variables'], sort_keys=True))
    started = time.monotonic()
    summary = {'task': task, 'category': item['category'], 'split': item['split'], 'status': 'error',
               'success': None, 'oracle_unavailable': True}
    agent = None
    session_id = None
    try:
        if args.auth_profile_file:
            profile = private_access_profile(args.auth_profile_file, duration + 70)
            install_access_profile(args.openclaw, config_path, state, cwd, env, profile, args.model)
        env['WAVE_HYBRID_METRICS_PATH'] = str(directory / 'local-metrics.jsonl')
        agent = subprocess.Popen([args.openclaw, 'agent', 'exec', '--config', str(config_path),
            '--state-dir', str(state), '--cwd', str(cwd), '--model', args.model,
            '--thinking', 'low', '--no-auth-env-only', '--timeout', str(duration), '--json',
            '--message-file', '-'], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True)
        agent.stdin.write(prompt)
        agent.stdin.close()
        agent.stdin = None
        turn_started = time.monotonic()
        rss_peak, browser_rss, steps = 0, [], 0
        while agent.poll() is None:
            rss_peak = max(rss_peak, sample_rss(agent.pid))
            try:
                browser_rss.append(fetch_json('http://127.0.0.1:%d/health' % ports['camofox'])['memory']['rssMb'])
            except (OSError, KeyError):
                pass
            if db.is_file():
                try:
                    conn = sqlite3.connect('file:' + str(db) + '?mode=ro', uri=True, timeout=.5)
                    rows = conn.execute('SELECT event_json FROM transcript_events WHERE event_json LIKE ?', ('%"toolCall"%',)).fetchall()
                    conn.close()
                    steps = sum(sum(1 for block in json.loads(row[0]).get('message', {}).get('content', [])
                                    if isinstance(block, dict) and block.get('type') == 'toolCall' and
                                    (block.get('name') == 'tool_call' or block.get('name', '').startswith('camofox_')))
                                for row in rows)
                except sqlite3.Error:
                    pass
            tool_budget = args.hosted_tool_budget or (60 if args.challenge else item['max_steps'])
            if steps >= tool_budget or time.monotonic() - turn_started > duration + 20:
                summary['step_budget_hit'] = steps >= tool_budget
                summary['timed_out'] = time.monotonic() - turn_started > duration + 20
                agent.terminate()
                break
            time.sleep(1)
        try:
            stdout, stderr = agent.communicate(timeout=12)
        except subprocess.TimeoutExpired:
            agent.kill()
            stdout, stderr = agent.communicate(timeout=8)
        try:
            envelope = json.loads(stdout)
        except ValueError:
            envelope = {}
        session_id = envelope.get('sessionId')
        if not session_id:
            session_id = transcript_session_id(db)
            summary['session_recovered_from_transcript'] = bool(session_id)
        complete_usage = (envelope.get('status') == 'ok' and agent.returncode == 0
                          and not summary.get('step_budget_hit') and not summary.get('timed_out'))
        summary.update({'status': envelope.get('status', 'error'), 'model_resolved':
                        (envelope.get('provider') or '') + '/' + (envelope.get('model') or ''),
                        'turns': envelope.get('assistantTurns'), 'agent_rss_peak_kib': rss_peak,
                        'camofox_server_rss_peak_mib': max(browser_rss, default=None),
                        'agent_turn_seconds': round(time.monotonic() - turn_started, 3),
                         'steps_budget_hit': summary.get('step_budget_hit', False),
                         'hosted_tool_budget': args.hosted_tool_budget or
                             (60 if args.challenge else item['max_steps']),
                         'hosted_tool_calls_observed': steps,
                         'usage_complete': complete_usage,
                         'termination_reason': 'hosted_tool_budget' if summary.get('step_budget_hit') else
                             'timeout' if summary.get('timed_out') else None,
                         'timed_out': summary.get('timed_out', envelope.get('status') == 'timeout')})
        if agent.returncode or summary['status'] != 'ok':
            summary['failure'] = failure_details(envelope, stderr, agent.returncode,
                [env[name] for name in args.auth_env] + [env['CAMOFOX_ACCESS_KEY']])
            if summary['status'] != 'ok':
                summary['provider_stop_reason'] = provider_block_reason(summary['failure'])
        summary.update(transcript_metrics(db, session_id))
        summary['hosted_usage'] = hosted_usage(db, session_id, catalog)
        summary['observed_usage_tokens'] = {key: sum(entry.get(key) or 0 for entry in summary['hosted_usage'])
                                            for key in ('input', 'cacheRead', 'cacheWrite', 'output')}
        for key, name in (('input', 'model_input_tokens'), ('cacheRead', 'model_cache_read_tokens'),
                          ('cacheWrite', 'model_cache_write_tokens'), ('output', 'model_output_tokens')):
            summary[name] = summary['observed_usage_tokens'][key] if complete_usage and summary['hosted_usage'] else None
        if not complete_usage:
            summary['model_input_plus_cache'] = None
        summary['model_prompt_tokens'] = (summary['model_input_tokens'] + summary['model_cache_read_tokens'] +
                                          summary['model_cache_write_tokens'] if complete_usage and summary['hosted_usage'] and
                                          all(all(isinstance(entry.get(key), int) and entry[key] >= 0 for key in
                                                  ('input', 'cacheRead', 'cacheWrite')) for entry in summary['hosted_usage'])
                                          else None)
        summary['estimated_usd'] = (round(sum(row['estimated_usd'] for row in summary['hosted_usage']), 8)
                                    if complete_usage and summary['hosted_usage']
                                    and all(row['estimated_usd'] is not None
                                    for row in summary['hosted_usage']) else None)
        if args.trace_synthetic:
            (directory / 'synthetic-tool-trace.json').write_text(json.dumps(synthetic_trace(
                db, session_id, item, args.contract_mode)))
        if args.hosted_trace:
            (directory / 'hosted-trace.json').write_text(json.dumps(hosted_trace(db, session_id), indent=2))
        metrics_file = directory / 'local-metrics.jsonl'
        if metrics_file.is_file():
            events = [json.loads(line) for line in metrics_file.read_text().splitlines() if line.strip()]
            latencies = [round(float(event['latency_ms']), 3) for event in events
                         if event.get('event') == 'model_call' and event.get('backend') in ('kev', 'laya')
                         and isinstance(event.get('latency_ms'), (float, int))]
            result_reasons = {}
            for event in events:
                if event.get('event') == 'result' and re.fullmatch('[a-z_]+', str(event.get('reason', ''))):
                    reason = event['reason']
                    result_reasons['reason:' + reason] = result_reasons.get('reason:' + reason, 0) + 1
            purposes = ('initial', 'pre_action', 'post_action')
            summary.update({'local_calls': sum(e.get('event') in ('model_call', 'failure') for e in events),
                            'local_model_errors': sum(e.get('event') == 'failure' for e in events),
                            'snapshots_by_purpose': {purpose: sum(e.get('event') == 'snapshot' and
                                e.get('purpose') == purpose for e in events) for purpose in purposes},
                            'local_steps': sum(e.get('event') == 'action' for e in events),
                            'local_deterministic_actions': sum(e.get('event') == 'action' and
                                                               e.get('deterministic') is True for e in events),
                            'local_model_actions': sum(e.get('event') == 'action' and
                                                       e.get('deterministic') is False for e in events),
                            'local_snapshots_unexposed': sum(e.get('event') == 'snapshot' and
                                                              e.get('exposed_to_large_model') is False for e in events),
                            'local_latency_ms': latencies, 'executor_results': result_reasons,
                            'loop_detected': result_reasons.get('reason:action_loop', 0)})
            metrics_file.unlink()
        else:
            summary.update({'local_calls': None, 'local_model_errors': None,
                            'snapshots_by_purpose': None, 'local_steps': None,
                            'local_deterministic_actions': None, 'local_model_actions': None,
                            'local_snapshots_unexposed': None, 'local_latency_ms': None,
                            'executor_results': None, 'loop_detected': None})
    except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as error:
        summary['error_kind'] = type(error).__name__
    finally:
        if agent and agent.poll() is None:
            agent.kill()
            agent.wait(timeout=8)
        try:
            summary.update(oracle_actions(fetch_json(oracle_url, oracle_key), item['variables'].get('target')))
            summary['oracle_unavailable'] = False
        except (OSError, KeyError, ValueError):
            pass
        try:
            clean_up_own_tabs(ports['camofox'], base_env['CAMOFOX_ACCESS_KEY'], session_id)
        finally:
            erase_db(db)  # Even unexpected tab-cleanup errors must not retain OAuth access.
            summary['wall_seconds'] = round(time.monotonic() - started, 3)
    return summary


def load_prompt(path):
    default = ('Complete this synthetic browser task: {goal} Start at {start_url}. '
               'Use Camofox on this fixture only. Do not request the oracle. '
               'Close only tabs you created and do not claim unverified completion.')
    text = Path(path).read_text() if path else default
    if len(text) > 8000 or '{goal}' not in text or '{start_url}' not in text:
        raise ValueError('prompt template must include {goal} and {start_url} and fit 8 KB')
    if set(re.findall(r'\{([a-z_]+)\}', text)) - {'goal', 'start_url', 'variables'}:
        raise ValueError('unknown prompt placeholder')
    return text


def select_fixture_tasks(frozen, challenge, selected):
    if not isinstance(frozen, list) or len(frozen) != 30:
        raise RuntimeError('frozen fixture must have 30 tasks')
    if challenge is not None:
        original = {'challenge-%02d' % n for n in range(31, 38)}
        if (not isinstance(challenge, list) or not 7 <= len(challenge) <= 50 or
                any(not isinstance(task, dict) or task.get('category') != 'challenge' or
                    not re.fullmatch(r'challenge-\d\d', str(task.get('id', ''))) or
                    not isinstance(task.get('goal'), str) or not isinstance(task.get('split'), str) or
                    not isinstance(task.get('variables'), dict) or
                    type(task.get('max_steps')) is not int or not 1 <= task['max_steps'] <= 75
                    for task in challenge)):
            raise RuntimeError('challenge fixture manifest invalid')
        ids = [task['id'] for task in challenge]
        if len(set(ids)) != len(ids) or not original.issubset(ids):
            raise RuntimeError('challenge fixture manifest invalid')
    tasks = challenge if challenge is not None else frozen
    if selected:
        names = set(selected)
        tasks = [task for task in tasks if task['id'] in names]
        if len(tasks) != len(names):
            raise ValueError('requested task not found')
    return tasks


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--openclaw', required=True, help='Absolute path to installed OpenClaw executable')
    parser.add_argument('--config', required=True, type=Path, help='JSON file with public model catalog ONLY')
    parser.add_argument('--model', required=True, help='Explicit provider/model ID')
    parser.add_argument('--plugin-path', required=True, type=Path, help='Pinned plugin directory with manifest')
    parser.add_argument('--output', required=True, type=Path, help='NEW private directory outside repository')
    parser.add_argument('--suite', required=True, help='Non-sensitive evaluation arm label')
    parser.add_argument('--implementation', default='custom', help='Non-sensitive implementation label')
    parser.add_argument('--image', default=IMAGE, help='Preloaded Camofox image; no pull')
    parser.add_argument('--podman', default='podman')
    parser.add_argument('--connection', default='openclaw-sandbox')
    parser.add_argument('--task', action='append', default=[], help='Run only selected frozen task ID; repeatable')
    parser.add_argument('--challenge', action='store_true', help='Use separate challenge fixtures instead of frozen tasks')
    parser.add_argument('--extra-tool', action='append', default=[], choices=sorted(EXTRA_TOOLS))
    parser.add_argument('--auth-env', action='append', default=[], choices=sorted(AUTH_ENV),
                        help='Read only this provider key from the caller environment')
    parser.add_argument('--auth-profile-file', type=Path, help='Explicit private access-only OAuth JSON (no refresh)')
    parser.add_argument('--model-executable', type=Path, help='Optional plugin-specific executable; see docs')
    parser.add_argument('--executor-backend', choices=('kev', 'laya'),
                        help='Enable configured browser_execute for a plugin variant that declares it')
    parser.add_argument('--max-steps', type=int, default=8, help='Executor mutation limit (1..24)')
    parser.add_argument('--hosted-tool-budget', type=int,
                        help='Outer OpenClaw tool-call cap (1..200), independent of fixture/executor steps; challenge default 60')
    parser.add_argument('--candidate-mode', choices=('legacy', 'strictBindings'), default='legacy')
    parser.add_argument('--apply-prepared', action='store_true')
    parser.add_argument('--stop-policy', choices=('success', 'checkpoint'), default='success')
    parser.add_argument('--contract-mode', choices=('procedural', 'semantic'), default='procedural',
                        help='Trusted executor tool schema; semantic requires browser_execute')
    parser.add_argument('--semantic-problem-detail', choices=('compact', 'contextual'), default='contextual',
                        help='Semantic needs_decision/mapping evidence mode; contextual default')
    parser.add_argument('--hosted-trace', action='store_true', help='Keep value-free tool and usage metrics by turn')
    parser.add_argument('--prompt-template-file', type=Path)
    parser.add_argument('--trace-synthetic', action='store_true',
                        help='Keep compact fixture-only tool names/refs; never raw transcripts or images')
    args = parser.parse_args(argv)
    if not re.fullmatch('[a-z0-9][a-z0-9-]{0,60}', args.suite) or not re.fullmatch('[a-z0-9][a-z0-9-]{0,60}', args.implementation):
        parser.error('suite and implementation must be safe, non-sensitive labels')
    args.openclaw = str(Path(args.openclaw).resolve())
    if not Path(args.openclaw).is_file() or not os.access(args.openclaw, os.X_OK):
        parser.error('OpenClaw executable unavailable')
    with Path(args.openclaw).open('rb') as binary:
        if b'secrets store get OPENCLAW_GATEWAY_TOKEN' in binary.read(8192):
            parser.error('Gateway-token-injecting CLI wrapper is not permitted; use the direct packaged executable')
    args.plugin_path = args.plugin_path.resolve()
    if not (args.plugin_path / 'openclaw.plugin.json').is_file() or not (args.plugin_path / 'plugin.js').is_file():
        parser.error('plugin directory lacks manifest/entry point')
    if set(args.extra_tool) - set(json.loads((args.plugin_path / 'openclaw.plugin.json').read_text()).get('contracts', {}).get('tools', [])):
        parser.error('extra tool not declared by plugin manifest')
    if args.model_executable and (not args.model_executable.is_absolute() or not os.access(args.model_executable, os.X_OK)):
        parser.error('local model executable must be an existing absolute executable')
    if args.model_executable and 'browser_execute' not in args.extra_tool:
        parser.error('--model-executable requires --extra-tool browser_execute')
    if args.executor_backend and 'browser_execute' not in args.extra_tool:
        parser.error('--executor-backend requires --extra-tool browser_execute')
    if args.contract_mode == 'semantic' and not args.executor_backend:
        parser.error('--contract-mode semantic requires --executor-backend')
    if args.contract_mode != 'semantic' and args.semantic_problem_detail != 'contextual':
        parser.error('--semantic-problem-detail compact requires --contract-mode semantic')
    if args.max_steps not in range(1, 25) or args.apply_prepared and args.candidate_mode != 'strictBindings':
        parser.error('invalid executor bounds or prepared mode')
    if args.hosted_tool_budget is not None and not 1 <= args.hosted_tool_budget <= 200:
        parser.error('--hosted-tool-budget must be in 1..200')
    if args.auth_profile_file and args.auth_env:
        parser.error('choose environment credentials OR an explicit OAuth profile, not both')
    if not args.auth_profile_file and not args.auth_env:
        parser.error('specify --auth-env NAME (default credential mode) or opt in to --auth-profile-file')
    provider = args.model.partition('/')[0]
    if provider not in PROVIDER_ENV:
        parser.error('only explicitly supported provider routes are allowed')
    if args.auth_env and args.auth_env != [PROVIDER_ENV[provider]]:
        parser.error('specify only the credential environment variable matching the selected provider')
    if args.auth_profile_file and provider != 'openai':
        parser.error('access-only OAuth profile is supported only for OpenAI')
    output = args.output.resolve()
    if output == REPO or REPO in output.parents or output.exists():
        parser.error('output must be a new directory outside this public repository')
    args.output = output
    args.prompt_template = load_prompt(args.prompt_template_file)
    return args


def main(argv=None):
    args = parse_args(argv)
    catalog = model_config(args.config, args.model)
    output = args.output
    output.mkdir(mode=0o700, parents=True)
    for env_name in args.auth_env:
        if not os.environ.get(env_name):
            raise ValueError('requested provider auth environment variable is missing')
    env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
           'TMPDIR': str(output), 'CAMOFOX_ACCESS_KEY': secrets.token_hex(32),
           'OPENCLAW_DISABLE_PERSISTED_PLUGIN_REGISTRY': '1'}
    for name in args.auth_env:
        env[name] = os.environ[name]
    if args.model_executable:
        env['BROWSER_DECISION_EXECUTABLE'] = str(args.model_executable)
    def interrupted(*_):
        raise KeyboardInterrupt()
    old = signal.signal(signal.SIGTERM, interrupted)
    try:
        # Podman needs its own connection configuration; agents do not inherit it.
        podman_env = dict(os.environ, CAMOFOX_ACCESS_KEY=env['CAMOFOX_ACCESS_KEY'])
        with temporary_fixture(args.podman, args.connection, args.image, podman_env) as (ports, key):
            frozen = fetch_json('http://127.0.0.1:%d/api/tasks' % ports['fixture'])
            challenge = (fetch_json('http://127.0.0.1:%d/api/challenge/tasks' % ports['fixture'])
                         if args.challenge else None)
            tasks = select_fixture_tasks(frozen, challenge, args.task)
            fingerprint = hashlib.sha256(''.join(digest(path) for path in
                (Path(__file__), HERE / 'server.js', HERE / 'tasks.js', args.config,
                  args.plugin_path / 'plugin.js')).encode()).hexdigest()
            model_row = next(iter(next(iter(catalog['providers'].values()))['models']))
            source_files = {'core': REPO / 'packages/browser-executor/core.mjs',
                            'resolver': REPO / 'packages/browser-executor/resolver.mjs',
                            'bridge': REPO / 'packages/browser-executor/bridge.mjs',
                            'browser_transport': REPO / 'packages/browser-executor/camofox.mjs',
                            'tool_definition': REPO / 'packages/browser-executor/plugin.mjs',
                            'runner': Path(__file__), 'tasks_fixture': HERE / 'tasks.js',
                            'server_fixture': HERE / 'server.js', 'challenge_fixture': HERE / 'challenge.js',
                            'browser_skill': REPO / 'modules/home/openclaw/skills/browser-research/SKILL.md'}
            manifest = {
                'suite': args.suite, 'model': args.model, 'image': args.image,
                 'fixture_sha256': {'tasks.js': digest(HERE / 'tasks.js'), 'server.js': digest(HERE / 'server.js'),
                                    'challenge.js': digest(HERE / 'challenge.js')},
                'code_fingerprint_sha256': fingerprint, 'task_count': len(tasks),
                 'source_sha256': {name: digest(path) for name, path in source_files.items()},
                 'packaged_plugin_sha256': {'wrapper': digest(args.plugin_path / 'plugin.js'),
                                            'manifest': digest(args.plugin_path / 'openclaw.plugin.json')},
                 'tool_contract_schema_sha256': contract_schema_sha256(args.contract_mode),
                 'model_catalog_sha256': digest(args.config),
                 'selected_model_row_sha256': hashlib.sha256(json.dumps(
                     model_row, sort_keys=True, separators=(',', ':')).encode()).hexdigest(),
                 'catalog_cost_per_million_usd': model_row.get('cost'),
                 'model_limits': {'maxTokens': model_row.get('maxTokens'),
                                  'contextWindow': model_row.get('contextWindow'), 'thinking': 'low'},
                 'prompt_template_sha256': hashlib.sha256(args.prompt_template.encode()).hexdigest(),
                   'executor_configuration': {'backend': args.executor_backend, 'maxSteps': args.max_steps,
                       'candidateMode': args.candidate_mode, 'applyPrepared': args.apply_prepared,
                       'stopPolicy': args.stop_policy, 'contractMode': args.contract_mode,
                       'semanticProblemDetail': args.semantic_problem_detail},
                 'hosted_tool_budget': args.hosted_tool_budget or (60 if args.challenge else 'fixture'),
                'credential_mode': 'explicit-access-only-oauth' if args.auth_profile_file else 'allowlisted-provider-environment',
                 'note': 'Agent exec uses pinned config and isolated HOME/state; --auth-env-only conflicts with --config in OpenClaw 2026.9.4. Usage costs are catalog estimates, not billed OpenRouter cost. Never route this to a live Camofox service.'
            }
            manifest_path = output / 'manifest.json'
            manifest_path.write_text(json.dumps(manifest, sort_keys=True, indent=2) + '\n')
            for index, item in enumerate(tasks):
                summary = run_one(args, item, ports, key, env, catalog, output)
                row = {'suite': args.suite, 'scenario': 'challenge' if args.challenge else 'frozen30', 'implementation': args.implementation,
                       **summary, 'historical_code_sha256': fingerprint,
                       'local_calls': summary.get('local_calls'), 'local_steps': summary.get('local_steps'),
                        'local_latency_ms': summary.get('local_latency_ms'),
                        'executor_results': summary.get('executor_results'),
                       'loop_detected': summary.get('loop_detected')}
                with (output / 'measurements.jsonl').open('a') as stream:
                    stream.write(json.dumps(row, sort_keys=True) + '\n')
                print(json.dumps({'task': item['id'], 'oracle_pass': row['success'],
                                  'status': row['status'], 'wall_seconds': row['wall_seconds']}), flush=True)
                if summary.get('provider_stop_reason'):
                    manifest.update({'abort_reason': summary['provider_stop_reason'],
                                     'attempted_task_count': index + 1,
                                     'not_attempted_tasks': [task['id'] for task in tasks[index + 1:]]})
                    manifest_path.write_text(json.dumps(manifest, sort_keys=True, indent=2) + '\n')
                    raise RuntimeError('provider blocked; suite stopped')
    finally:
        signal.signal(signal.SIGTERM, old)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, RuntimeError, OSError) as error:
        reason = str(error)
        allowed = {'frozen fixture must have 30 tasks', 'challenge fixture manifest invalid',
                   'requested task not found', 'disposable Camofox container failed to start',
                   'disposable Camofox health check timed out', 'disposable fixture did not start',
                   'invalid fixture startup', 'port collision', 'provider blocked; suite stopped'}
        safe = reason if reason in allowed else 'unclassified'
        print('benchmark failed: %s: %s' % (type(error).__name__, safe), file=sys.stderr)
        sys.exit(2)
