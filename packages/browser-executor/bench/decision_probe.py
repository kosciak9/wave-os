#!/usr/bin/env python3
"""Bounded, standalone synthetic decision payload probe; never controls a browser."""

import argparse
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
ENDPOINT = 'https://openrouter.ai/api/v1/chat/completions'
MODELS = ('openai/gpt-6-luna', 'openai/gpt-6-sol')
SYSTEM = ('Given only the supplied synthetic goal and executor problem, either ask for missing user '
          'information or choose exactly one supplied option. Do not invent a preference or price. '
          'Reply with a JSON object: {"action":"ask"|"choose","option":"exact supplied option" '
          'only when choosing,"reason":"brief explanation"}. Never infer browser state not supplied.')
CASES = (
    {'id': 'no-preference', 'question': 'H11: is a preference supplied?',
     'goal': 'Request a room for one guest; no room preference or optimization criterion was supplied.',
     'problem': {'kind': 'needs_decision', 'field': 'Room', 'context': 'Demo room request',
                 'options': [{'label': 'Standard', 'value': 'Standard', 'total': 75},
                             {'label': 'Deluxe', 'value': 'Deluxe', 'total': 90}]},
     'observed_evidence': [], 'diagnostic_expected': {'action': 'ask'}},
    {'id': 'explicit-cheapest', 'question': 'H11: does an explicit cheapest criterion suffice?',
     'goal': 'Choose the cheapest available room by its stated total.',
     'problem': {'kind': 'needs_decision', 'field': 'Room', 'context': 'Demo room request',
                 'options': [{'label': 'Standard', 'value': 'Standard', 'total': 75},
                             {'label': 'Deluxe', 'value': 'Deluxe', 'total': 90}]},
     'observed_evidence': [], 'diagnostic_expected': {'action': 'choose', 'option': 'Standard'}},
    {'id': 'price-evidence-missing', 'question': 'H12: can a goal substitute for missing prices?',
     'goal': 'For two guests choose the room with the lowest total including any booking fee.',
     'problem': {'kind': 'needs_decision', 'field': 'Preference', 'context': 'Garden Room pricing',
                 'options': [{'label': 'Standard', 'value': 'Standard'},
                             {'label': 'Quiet', 'value': 'Quiet'}]},
     'observed_evidence': [], 'diagnostic_expected': {'action': 'ask'}},
    {'id': 'price-evidence-present', 'question': 'H12: is observed pricing sufficient?',
     'goal': 'For two guests choose the room with the lowest total including any booking fee.',
     'problem': {'kind': 'needs_decision', 'field': 'Preference', 'context': 'Garden Room pricing',
                 'options': [{'label': 'Standard', 'value': 'Standard'},
                             {'label': 'Quiet', 'value': 'Quiet'}]},
     'observed_evidence': ['Standard costs 45 per guest.',
                           'Quiet costs 35 per guest plus a 5 booking fee.'],
     'diagnostic_expected': {'action': 'choose', 'option': 'Quiet'}},
)


def request_for(model, case):
    question = {key: case[key] for key in ('goal', 'problem', 'observed_evidence')}
    return {'model': model, 'messages': [{'role': 'system', 'content': SYSTEM},
            {'role': 'user', 'content': json.dumps(question, sort_keys=True)}],
            'response_format': {'type': 'json_object'}, 'reasoning': {'effort': 'low'},
            'max_completion_tokens': 2048, 'stream': False}


def safe_number(value, integer=False):
    if type(value) not in (int, float) or value < 0 or value != value or value == float('inf'):
        return None
    return value if not integer or type(value) is int else None


def usage_fields(payload):
    usage = payload.get('usage') if isinstance(payload, dict) else None
    if not isinstance(usage, dict):
        return None
    details = usage.get('prompt_tokens_details') or {}
    details = details if isinstance(details, dict) else {}
    return {'prompt_tokens': safe_number(usage.get('prompt_tokens'), True),
            'completion_tokens': safe_number(usage.get('completion_tokens'), True),
            'cached_tokens': safe_number(details.get('cached_tokens'), True),
            'cache_write_tokens': safe_number(details.get('cache_write_tokens'), True),
            'cost_usd': safe_number(usage.get('cost'))}


def parse_answer(payload, options):
    try:
        choice = payload['choices'][0]
        content = choice['message']['content']
        if not isinstance(content, str) or len(content) > 4000:
            return None, 'missing_or_oversized_content'
        answer = json.loads(content)
        if not isinstance(answer, dict) or set(answer) - {'action', 'option', 'reason'}:
            return None, 'invalid_answer_shape'
        action, option, reason = answer.get('action'), answer.get('option'), answer.get('reason')
        if action not in ('ask', 'choose') or not isinstance(reason, str) or not reason.strip() or len(reason) > 240 or not re.fullmatch(r'[\x20-\x7e]+', reason) or re.search(r'(?i)\b(?:sk-[\w-]+|bearer|api[_-]?key|password|secret|token)\b|https?://|/(?:Users|var|run|nix)/', reason):
            return None, 'invalid_answer_shape'
        if action == 'ask' and option is not None or action == 'choose' and option not in options:
            return None, 'invalid_or_unlisted_option'
        return {'action': action, 'option': option if action == 'choose' else None, 'reason': reason}, None
    except (ValueError, KeyError, IndexError, TypeError):
        return None, 'invalid_json_response'


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_):
        return None


def run_case(model, case, key):
    request_body = request_for(model, case)
    body_bytes = json.dumps(request_body).encode()
    started = time.monotonic()
    row = {'case': case['id'], 'question': case['question'],
           'started_utc': datetime.now(timezone.utc).isoformat(timespec='seconds'),
           'payload': {name: case[name] for name in ('goal', 'problem', 'observed_evidence')},
           'diagnostic_expected': case['diagnostic_expected'],
           'request_sha256': hashlib.sha256(body_bytes).hexdigest(),
           'request_bytes': len(body_bytes), 'status': 'error',
           'answer': None, 'usage': None, 'http_status': None}
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    request = urllib.request.Request(ENDPOINT, data=body_bytes, method='POST',
                                     headers={'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'})
    try:
        with opener.open(request, timeout=90) as response:
            row['http_status'] = response.status
            data = response.read(256_001)
        if len(data) > 256_000:
            row['error_kind'] = 'response_too_large'
        else:
            payload = json.loads(data)
            row['usage'] = usage_fields(payload)
            if not isinstance(payload, dict) or payload.get('error'):
                row['error_kind'] = 'provider_response_error'
            else:
                answer, error = parse_answer(payload, [item['value'] for item in case['problem']['options']])
                row['answer'] = answer
                row['error_kind'] = error
                choices = payload.get('choices')
                finish = choices[0].get('finish_reason') if isinstance(choices, list) and choices and isinstance(
                    choices[0], dict) else None
                row['finish_reason'] = finish if finish in ('stop', 'length', 'content_filter') else 'other'
                row['status'] = 'answered' if answer and finish == 'stop' else 'invalid_answer'
                if answer and finish != 'stop':
                    row['error_kind'] = 'incomplete_or_nonterminal_finish'
                row['matches_authored_expectation'] = (all(answer.get(k) == v for k, v in
                    case['diagnostic_expected'].items()) if row['status'] == 'answered' else None)
    except urllib.error.HTTPError as error:
        row['http_status'] = error.code
        row['error_kind'] = 'provider_authorization_or_budget_block' if error.code in (401, 402, 403) else 'http_error'
        error.close()
    except (OSError, ValueError, TypeError):
        row['error_kind'] = 'transport_or_response_error'
    row['elapsed_ms'] = round((time.monotonic() - started) * 1000)
    return row


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model', required=True, choices=MODELS)
    parser.add_argument('--case', choices=('all', *(case['id'] for case in CASES)), default='all')
    parser.add_argument('--output', required=True, type=Path, help='Fresh private directory outside this repository')
    parser.add_argument('--preview', action='store_true', help='No credentials, network, files, or model calls')
    args = parser.parse_args(argv)
    selected = list(CASES) if args.case == 'all' else [case for case in CASES if case['id'] == args.case]
    output = args.output.resolve()
    if output == REPO or REPO in output.parents or output.exists() or not output.parent.is_dir():
        parser.error('output must be a fresh directory outside the repository with an existing parent')
    if args.preview:
        print(json.dumps({'model': args.model, 'case_ids': [case['id'] for case in selected],
                          'request_bytes': {case['id']: len(json.dumps(request_for(args.model, case)).encode())
                                            for case in selected}}))
        return
    key = os.environ.get('OPENROUTER_API_KEY')
    if not key:
        parser.error('OPENROUTER_API_KEY must be supplied by the caller')
    output.mkdir(mode=0o700)
    def private_write(name, value, append=False):
        flags = os.O_WRONLY | os.O_CREAT | (os.O_APPEND if append else os.O_EXCL)
        with os.fdopen(os.open(output / name, flags, 0o600), 'w') as stream:
            stream.write(value)

    private_write('manifest.json', json.dumps({
        'created_utc': datetime.now(timezone.utc).isoformat(timespec='seconds'),
        'model': args.model, 'endpoint': 'OpenRouter Chat Completions (fixed public API)',
        'probe_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        'system_sha256': hashlib.sha256(SYSTEM.encode()).hexdigest(),
        'case_ids': [case['id'] for case in selected], 'requests_max': len(selected),
        'request_parameters': {'reasoning': {'effort': 'low'}, 'max_completion_tokens': 2048,
                               'response_format': {'type': 'json_object'}, 'stream': False},
        'interpretation': 'Standalone authored question: not an OpenClaw/browser loop or fixture oracle.'
                          ' Costs are provider-reported usage, not an independent account invoice.',
    }, sort_keys=True, indent=2) + '\n')
    rows = []
    for case in selected:
        row = run_case(args.model, case, key)
        rows.append(row)
        private_write('attempts.jsonl', json.dumps(row, sort_keys=True) + '\n', append=True)
        print(json.dumps({'case': case['id'], 'status': row['status'],
                          'http_status': row['http_status']}), flush=True)
        if row['http_status'] not in (None, 200):
            break
    costs = [(row.get('usage') or {}).get('cost_usd') for row in rows]
    complete = len(rows) == len(selected) and all(cost is not None for cost in costs)
    private_write('summary.json', json.dumps({
        'attempted': len(rows), 'requested': len(selected),
        'known_cost_usd': round(sum(cost for cost in costs if cost is not None), 9)
        if any(cost is not None for cost in costs) else None,
        'total_cost_usd': round(sum(costs), 9) if complete else None,
        'cost_complete': complete, 'stopped_on_provider_block': bool(rows and rows[-1]['http_status'] in (401, 402, 403)),
        'stopped_on_http_error': bool(rows and rows[-1]['http_status'] not in (None, 200)),
    }, sort_keys=True, indent=2) + '\n')


if __name__ == '__main__':
    main()
