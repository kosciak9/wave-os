#!/usr/bin/env python3
"""Direct hosted decision/contract study against disposable synthetic Camofox fixtures."""
import argparse
import hashlib
import json
import os
import secrets
import select
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

import decision_probe as provider
import run

HERE = Path(__file__).resolve().parent
MODELS = provider.MODELS
H12 = ('challenge-55', 'challenge-51', 'challenge-63')
H7 = ('challenge-38', 'challenge-52')
FIELDS = {'challenge-38': ['Search catalog', 'Location', 'Preference'],
          'challenge-52': ['Location', 'Location', 'Service']}
MANUAL = {'challenge-38': {'target': 'Search catalog', 'location': 'Location', 'preference': 'Preference'},
          'challenge-52': {'location': 'Location', 'service': 'Service'}}
SYSTEM_DECISION = ('Use only the supplied synthetic goal, facts, and observed executor problem. '
                   'Choose one listed option only when the user supplied enough information; do not infer a '
                   'preference from a default or sidebar. Compute totals when prices are observed and the goal '
                   'explicitly asks for cheapest. Return JSON {"action":"ask"} or '
                   '{"action":"choose","option":"exact listed value"}. No tools.')


def generation_request(model, task, arm):
    shape = ('{"variables": {fact keys and values}, "bindings": {fact keys: exact field labels}}'
             if arm == 'procedural' else
             '{"facts": {fact keys and values}, "bindings": {fact keys: exact field labels} or omit bindings}')
    prompt = {'goal': task['goal'], 'task_facts': task['variables'],
              'field_manifest': FIELDS[task['id']], 'output_shape': shape}
    return {'model': model, 'messages': [{'role': 'system', 'content':
        'Author one browser executor contract from only the synthetic facts and the controlled field manifest. '
        'Preserve ALL task facts exactly; do not invent facts or actions. Reply as a JSON object in the output shape.'},
        {'role': 'user', 'content': json.dumps(prompt, sort_keys=True)}],
        'response_format': {'type': 'json_object'}, 'reasoning': {'effort': 'low'},
        'max_completion_tokens': 2048, 'stream': False}


def decision_request(model, payload):
    return {'model': model, 'messages': [{'role': 'system', 'content': SYSTEM_DECISION},
        {'role': 'user', 'content': json.dumps(payload, sort_keys=True)}],
        'response_format': {'type': 'json_object'}, 'reasoning': {'effort': 'low'},
        'max_completion_tokens': 2048, 'stream': False}


def hosted(request, key):
    import urllib.error
    import urllib.request
    body = json.dumps(request, sort_keys=True).encode()
    row = {'request_bytes': len(body), 'request_sha256': hashlib.sha256(body).hexdigest(),
           'usage': None, 'http_status': None, 'error': None, 'answer': None}
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), provider.NoRedirect())
    req = urllib.request.Request(provider.ENDPOINT, body, method='POST', headers={
        'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'})
    try:
        with opener.open(req, timeout=90) as response:
            row['http_status'] = response.status
            raw = response.read(256_001)
        if len(raw) > 256_000:
            row['error'] = 'response_too_large'
        else:
            data = json.loads(raw)
            row['usage'] = provider.usage_fields(data)
            if isinstance(data, dict) and not data.get('error') and data['choices'][0]['finish_reason'] == 'stop':
                content = data['choices'][0]['message']['content']
                if isinstance(content, str) and len(content) <= 4000:
                    row['answer'] = json.loads(content)
            if row['answer'] is None:
                row['error'] = 'invalid_or_incomplete_answer'
    except urllib.error.HTTPError as error:
        row['http_status'] = error.code
        row['error'] = 'provider_http_error'
        error.close()
    except (ValueError, KeyError, IndexError, TypeError, OSError):
        row['error'] = 'transport_or_response_error'
    return row


def validate(contract, task, arm):
    facts_key = 'variables' if arm == 'procedural' else 'facts'
    expected = task['variables']
    top = contract if isinstance(contract, dict) else {}
    facts = top.get(facts_key)
    bindings = top.get('bindings', {})
    diagnostic = {'top_level_type': 'object' if isinstance(contract, dict) else 'non_object',
        'present_known_keys': sorted(set(top) & {facts_key, 'bindings'}),
        'unknown_top_level_key_count': len(set(top) - {facts_key, 'bindings'}),
        'missing_required_keys': [facts_key] if facts_key not in top else [],
        'facts_type': 'object' if isinstance(facts, dict) else 'missing' if facts_key not in top else 'non_object',
        'missing_fact_keys': sorted(set(expected) - set(facts)) if isinstance(facts, dict) else sorted(expected),
        'extra_fact_key_count': len(set(facts) - set(expected)) if isinstance(facts, dict) else 0,
        'changed_fact_keys': sorted(k for k in expected if k in facts and facts[k] != expected[k])
                             if isinstance(facts, dict) else [],
        'bindings_type': 'object' if isinstance(bindings, dict) else 'non_object',
        'missing_binding_keys': sorted(set(expected) - set(bindings)) if isinstance(bindings, dict) else sorted(expected),
        'extra_binding_key_count': len(set(bindings) - set(expected)) if isinstance(bindings, dict) else 0,
        'invalid_label_count': sum(not isinstance(v, str) or v not in FIELDS[task['id']]
                                   for v in bindings.values()) if isinstance(bindings, dict) else 0}
    if not isinstance(contract, dict) or set(contract) - {facts_key, 'bindings'} or facts != expected:
        return None, 'invalid_facts_or_shape', diagnostic
    if not isinstance(bindings, dict) or set(bindings) - set(task['variables']) or any(
            not isinstance(v, str) or v not in FIELDS[task['id']] for v in bindings.values()):
        return None, 'invalid_bindings', diagnostic
    if arm == 'procedural' and set(bindings) != set(task['variables']):
        return None, 'incomplete_procedural_bindings', diagnostic
    return {facts_key: task['variables'], **({'bindings': bindings} if 'bindings' in contract else {})}, None, diagnostic


def oracle_summary(ports, oracle_key, result):
    oracle = run.fetch_json(f'http://127.0.0.1:{ports["fixture"]}/api/challenge/runs/{result.pop("runId")}', oracle_key)
    events = oracle['events']
    result['oracle'] = {'passed': oracle['passed'], 'mistakes': oracle['mistakes'],
        'valid_final_submits': sum(e.get('action') == 'submit:finish' and e.get('valid') is True for e in events),
        'invalid_submits': sum(e.get('action', '').startswith('submit:') and e.get('valid') is False for e in events)}


def local_case(spec, ports, oracle_key, env, tmp, key=None):
    source, target = Path(tmp) / 'input.json', Path(tmp) / 'result.json'
    spec = {**spec, 'baseUrl': f'http://127.0.0.1:{run.PORT_INSIDE}',
            'camofoxUrl': f'http://127.0.0.1:{ports["camofox"]}'}
    source.write_text(json.dumps(spec))
    try:
        if spec['study'] == 'h12' and spec['arm'] != 'mapping_diagnostic':
            proc = subprocess.Popen(['node', str(HERE / 'hosted-focused.mjs'), str(source), str(target)],
                                    env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                    text=True, bufsize=1)
            try:
                # Node emits exactly one bounded problem line; no native snapshot leaves the process.
                if not select.select([proc.stdout], [], [], 145)[0]:
                    raise RuntimeError('initial_problem_timeout')
                initial = proc.stdout.readline(16385)
                if not initial.endswith('\n') or len(initial) > 16384:
                    proc.communicate(timeout=10)
                    if target.is_file():
                        result = json.loads(target.read_text())
                        result['hosted_calls'] = 0
                        oracle_summary(ports, oracle_key, result)
                        return result
                    raise RuntimeError('bounded_initial_problem_unavailable')
                payload = json.loads(initial)
                call = hosted(decision_request(spec['model'], payload), key)
                options = [o['value'] for o in payload['problem']['options']]
                answer = call.pop('answer')
                valid = isinstance(answer, dict) and (set(answer) == {'action'} and answer['action'] == 'ask' or
                    set(answer) == {'action', 'option'} and answer['action'] == 'choose' and answer['option'] in options)
                proc.stdin.write(json.dumps(answer if valid else {'action': 'invalid'}) + '\n')
                proc.stdin.flush()
                proc.communicate(timeout=145)
                result = json.loads(target.read_text())
                result['hosted'] = {**call, 'answer': answer if valid else None,
                                    'answer_valid': valid, 'answer_adapted': False,
                                    'payload_bytes': len(initial.encode()),
                                    'payload_sha256': hashlib.sha256(initial.encode()).hexdigest()}
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.communicate()
        else:
            completed = subprocess.run(['node', str(HERE / 'hosted-focused.mjs'), str(source), str(target)],
                env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=145, check=False)
            if completed.returncode:
                raise RuntimeError('local_executor_exit')
            result = json.loads(target.read_text())
        oracle_summary(ports, oracle_key, result)
        return result
    finally:
        source.unlink(missing_ok=True)
        target.unlink(missing_ok=True)


def export_compact(source, destination):
    """Project private fixture records into bounded, synthetic-only public evidence."""
    if not source.is_dir() or destination.exists() or destination.parent != HERE / 'results':
        raise ValueError('export requires an existing run directory and a new bench/results file')
    manifest_path, attempts_path, summary_path = (source / name for name in
        ('manifest.json', 'attempts.jsonl', 'summary.json'))
    manifest = json.loads(manifest_path.read_text())
    summary = json.loads(summary_path.read_text())
    rows = [json.loads(line) for line in attempts_path.read_text().splitlines()]
    if manifest.get('models') != list(MODELS) or len(rows) != summary.get('attempted') or len(rows) > 90:
        raise ValueError('unexpected hosted run manifest or row count')
    hashes = {**manifest['sha256'], 'core.mjs': manifest['core_sha256'],
              'resolver.mjs': manifest['resolver_sha256']}
    current = {name: (HERE / name if name not in ('core.mjs', 'resolver.mjs') else HERE.parent / name)
               for name in hashes}
    hash_match = {name: run.digest(path) == value for name, (path, value) in
                  ((name, (current[name], value)) for name, value in hashes.items())}
    allowed_reasons = {'missing_fact', 'ambiguous_mapping', 'terminal_observed', 'boundary_unresolved',
                       'continuation_stale', 'invalid_hosted_answer'}
    allowed_status = {'needs_decision', 'needs_mapping', 'checkpoint', 'completed', 'escalated'}
    def outcome(value):
        if not isinstance(value, dict):
            return None
        return {key: value.get(key) if value.get(key) in allowed_status | allowed_reasons else None
                for key in ('status', 'reason')} | {'steps': value.get('steps') if type(value.get('steps')) is int else None}
    def usage(value):
        raw = value.get('usage') or {}
        return {name: raw.get(name) if provider.safe_number(raw.get(name), name != 'cost_usd') is not None else None
                for name in ('prompt_tokens', 'completion_tokens', 'cached_tokens', 'cache_write_tokens', 'cost_usd')}
    h12, h7 = [], []
    for row in rows:
        task, arm, model, repetition = (row.get(k) for k in ('task', 'arm', 'model', 'repetition'))
        if task not in (*H12, 'challenge-62', *H7) or model not in (*MODELS, None) or type(repetition) is not int or repetition not in (0, 1):
            raise ValueError('unknown row identity')
        base = {'task': task, 'arm': arm, 'model': model, 'repetition': repetition}
        if 'pause' in row:
            base['oracle'] = {k: row['oracle'].get(k) for k in
                              ('passed', 'mistakes', 'valid_final_submits', 'invalid_submits')}
            if arm not in ('original', 'selected', 'structured', 'stale', 'compact', 'mapping_diagnostic'):
                raise ValueError('unknown H12 arm')
            answer = row.get('hosted', {}).get('answer')
            safe_answer = {'action': answer['action']} if isinstance(answer, dict) and answer.get('action') == 'ask' else (
                {'action': 'choose', 'option': answer['option']} if isinstance(answer, dict) and
                answer.get('action') == 'choose' and answer.get('option') in ('Quiet', 'Standard',
                'Standard   75', 'Deluxe   90') else None)
            call = row.get('hosted') or {}
            h12.append({**base, 'pause': outcome(row['pause']),
                'pause_kind': row['pause'].get('problem', {}).get('kind') if row['pause'].get('problem', {}).get('kind') in
                    ('missing_fact', 'ambiguous_mapping') else None,
                'continuation_available': row['pause'].get('continuation') is True,
                'snapshot_exposed': row.get('snapshot_exposed') is True,
                'hosted_calls': 0 if row.get('hosted_calls') == 0 else 1,
                'answer': safe_answer, 'answer_valid': call.get('answer_valid'),
                'answer_adapted': call.get('answer_adapted'), 'http_status': call.get('http_status'),
                'payload_bytes': call.get('payload_bytes'), 'usage': usage(call) if call else None,
                'resume': outcome(row.get('resume')), 'resume_actions': row.get('resume_actions'),
                'external_fixture_change': row.get('external_fixture_change') == 'refresh_prices_after_hosted_choice'})
        elif 'generator' in row:
            if task not in H7 or arm not in ('procedural', 'semantic'):
                raise ValueError('unknown H7 row')
            contract = row.get('contract')
            # validate against frozen public synthetic facts, not arbitrary model-provided strings.
            expected = {'challenge-38': {'target': 'Harbor Studio', 'location': 'North Pier', 'preference': 'Quiet'},
                        'challenge-52': {'location': 'North Pier', 'service': 'Express'}}[task]
            facts_key = 'variables' if arm == 'procedural' else 'facts'
            if contract is not None and (contract.get(facts_key) != expected or not isinstance(contract.get('bindings', {}), dict)
                or any(key not in expected or val not in FIELDS[task] for key, val in contract.get('bindings', {}).items())):
                raise ValueError('unvalidated contract in run')
            replays = {label: {'outcome': outcome(v.get('result')), 'oracle': v.get('oracle', {}).get('passed'),
                'mistakes': v.get('oracle', {}).get('mistakes'), 'actions': len(v.get('actions', [])),
                'bindings': v.get('contract', {}).get('bindings')}
                for label, v in row.get('replays', {}).items() if label in ('returned', 'fixed_manual', 'local_resolver')}
            diagnostic = row.get('validation_diagnostic')
            if diagnostic is not None:
                keys = ('present_known_keys', 'unknown_top_level_key_count', 'missing_required_keys',
                        'facts_type', 'missing_fact_keys', 'extra_fact_key_count', 'changed_fact_keys',
                        'bindings_type', 'missing_binding_keys', 'extra_binding_key_count', 'invalid_label_count',
                        'top_level_type')
                if (set(diagnostic) != set(keys) or any(key not in expected for name in
                    ('missing_fact_keys', 'changed_fact_keys', 'missing_binding_keys') for key in diagnostic[name]) or any(
                    type(diagnostic[name]) is not int or diagnostic[name] < 0 for name in
                    ('unknown_top_level_key_count', 'extra_fact_key_count', 'extra_binding_key_count', 'invalid_label_count')) or
                    diagnostic['top_level_type'] not in ('object', 'non_object') or diagnostic['facts_type'] not in
                    ('object', 'missing', 'non_object') or diagnostic['bindings_type'] not in ('object', 'non_object') or
                    not set(diagnostic['present_known_keys']) <= {facts_key, 'bindings'} or
                     not set(diagnostic['missing_required_keys']) <= {facts_key}):
                    raise ValueError('unsafe contract diagnostic')
                diagnostic = {key: diagnostic[key] for key in keys}
            h7.append({**base, 'validation': row.get('validation') if row.get('validation') in
                ('valid', 'invalid_facts_or_shape', 'invalid_bindings', 'incomplete_procedural_bindings') else 'other',
                'validation_diagnostic': diagnostic,
                'adapter': row.get('adapter'), 'controlled_field_manifest_exposed': True,
                'facts': contract.get(facts_key) if contract else None,
                'bindings': contract.get('bindings') if contract else None,
                'http_status': row['generator'].get('http_status'), 'usage': usage(row['generator']),
                'request_bytes': row['generator'].get('request_bytes'), 'replays': replays})
        else:
            raise ValueError('unexpected run row')
    costs = [row['usage']['cost_usd'] for row in (*h12, *h7) if row['usage']]
    if len(costs) != manifest['calls_max'] or any(cost is None for cost in costs) or abs(sum(costs) - summary['total_cost_usd']) > 1e-8:
        raise ValueError('provider usage or cost incomplete')
    report = {'scope': 'Direct OpenRouter decision/contract calls plus local synthetic Camofox; not OpenClaw sessions',
              'limits': ['H12 snapshot never exposed to hosted model; H7 controlled fixture field manifest is exposed.',
                         'A checkpoint alone is not oracle success; ask and stale are intentional non-completions.',
                         'No hosted decision for duplicate-context challenge-62: local needs_mapping only.',
                         'Explicit task facts and field manifest make H7 authoring easier; no general Luna/Sol bottleneck inference.'],
              'source': {'manifest_sha256': run.digest(manifest_path), 'attempts_sha256': run.digest(attempts_path),
                         'summary_sha256': run.digest(summary_path), 'sha256': hashes, 'current_source_hash_matches': hash_match,
                         'h7_runtime': manifest['h7_runtime'], 'models': list(MODELS), 'repetitions': manifest['repetitions']},
              'provider_usage': {'calls': len(costs), 'provider_cost_usd': summary['total_cost_usd'],
                  'prompt_tokens': sum(x['usage']['prompt_tokens'] for x in (*h12, *h7) if x['usage']),
                  'completion_tokens': sum(x['usage']['completion_tokens'] for x in (*h12, *h7) if x['usage'])},
              'h12': h12, 'h7': h7}
    with destination.open('x', encoding='utf8') as stream:
        json.dump(report, stream, sort_keys=True, indent=2)
        stream.write('\n')


def replay_frozen(source, output, connection):
    """Replay only validated, frozen synthetic contracts; no provider, regeneration or repair."""
    prior = json.loads(source.read_text())
    if prior.get('scope') != 'Direct OpenRouter decision/contract calls plus local synthetic Camofox; not OpenClaw sessions':
        raise ValueError('replay requires a bounded hosted export')
    entries = prior.get('h7')
    if not isinstance(entries, list) or len(entries) > 32:
        raise ValueError('invalid frozen contract set')
    output.mkdir(mode=0o700)
    env = dict(os.environ, CAMOFOX_ACCESS_KEY=secrets.token_hex(32))
    env.pop('OPENROUTER_API_KEY', None)
    comparison = {'source_export_sha256': run.digest(source),
                  'original_source_sha256': prior['source']['sha256'],
                  'current_core_sha256': run.digest(HERE.parent / 'core.mjs'),
                  'current_resolver_sha256': run.digest(HERE.parent / 'resolver.mjs'),
                  'current_fixture_sha256': run.digest(HERE / 'challenge.js'),
                  'current_harness_sha256': run.digest(HERE / 'hosted-focused.mjs'),
                  'hosted_calls': 0, 'contract_regenerations': 0,
                  'held_constant': {'semantic_boundary': 'adaptive', 'max_steps': 8,
                                    'backend': 'semantic', 'policy': 'fixed-oracle-navigation'},
                  'rows': []}
    with run.temporary_fixture('podman', connection, run.IMAGE, env) as (ports, oracle_key):
        tasks = {t['id']: t for t in run.fetch_json(f'http://127.0.0.1:{ports["fixture"]}/api/challenge/tasks')}
        with tempfile.TemporaryDirectory(prefix='hosted-frozen-', dir='/var/folders/l9/6md8t1991gndsmclcpg0_6340000gn/T/opencode') as tmp:
            for entry in entries:
                task_id, arm, model, repetition = (entry.get(k) for k in ('task', 'arm', 'model', 'repetition'))
                if task_id not in H7 or arm not in ('procedural', 'semantic') or model not in MODELS or repetition not in (0, 1):
                    raise ValueError('invalid frozen identity')
                row = {'task': task_id, 'arm': arm, 'model': model, 'repetition': repetition,
                       'original_validation': entry['validation'], 'replays': {}}
                if entry['validation'] == 'valid':
                    fact_key = 'variables' if arm == 'procedural' else 'facts'
                    contract = {fact_key: entry['facts'], **({'bindings': entry['bindings']}
                                if entry['bindings'] is not None else {})}
                    validated, error, _ = validate(contract, tasks[task_id], arm)
                    if error or validated != contract:
                        raise ValueError('frozen contract failed fixture-fact validation')
                    for label, bindings in (('returned', contract.get('bindings')),
                                            ('fixed_manual', MANUAL[task_id]), ('local_resolver', None)):
                        adapted = {**contract}
                        if bindings is None:
                            adapted.pop('bindings', None)
                        else:
                            adapted['bindings'] = bindings
                        result = local_case({'study': 'h7', 'task': tasks[task_id], 'arm': arm,
                            'model': model, 'repetition': repetition, 'contract': adapted},
                            ports, oracle_key, env, tmp)
                        row['replays'][label] = {'oracle_passed': result['oracle']['passed'],
                            'oracle_mistakes': result['oracle']['mistakes'],
                            'executor_status': result.get('result', {}).get('status'),
                            'executor_reason': result.get('result', {}).get('reason'),
                            'action_count': len(result['actions']), 'local_error': result.get('error')}
                comparison['rows'].append(row)
    with (output / 'replay.json').open('x', encoding='utf8') as stream:
        json.dump(comparison, stream, sort_keys=True, indent=2)
        stream.write('\n')
    (output / 'replay.json').chmod(0o600)


def export_frozen_replay(source, destination):
    if destination.exists() or destination.parent != HERE / 'results':
        raise ValueError('replay export must be a new bench/results file')
    replay = json.loads(source.read_text())
    if replay.get('hosted_calls') != 0 or replay.get('contract_regenerations') != 0 or len(replay.get('rows', [])) > 32:
        raise ValueError('unexpected frozen replay')
    prior = HERE / 'results/focused-hosted-20260929.json'
    if replay.get('source_export_sha256') != run.digest(prior):
        raise ValueError('replay provenance does not match frozen export')
    for row in replay['rows']:
        if row.get('task') not in H7 or row.get('arm') not in ('procedural', 'semantic') or row.get('model') not in MODELS:
            raise ValueError('unexpected frozen replay identity')
        if set(row.get('replays', {})) - {'returned', 'fixed_manual', 'local_resolver'}:
            raise ValueError('unexpected binding arm')
        for result in row['replays'].values():
            if (set(result) != {'oracle_passed', 'oracle_mistakes', 'executor_status',
                               'executor_reason', 'action_count', 'local_error'} or result['local_error'] is not None or
                    result['executor_status'] not in ('checkpoint', 'completed', 'needs_decision', 'needs_mapping', 'escalated') or
                    result['executor_reason'] not in ('terminal_observed', 'boundary_unresolved', 'missing_fact',
                                                      'ambiguous_mapping', 'max_steps', 'no_actionable_controls')):
                raise ValueError('unexpected replay outcome')
    with destination.open('x', encoding='utf8') as stream:
        json.dump(replay, stream, sort_keys=True, indent=2)
        stream.write('\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True, help='New private directory outside repository')
    parser.add_argument('--study', choices=('h12', 'h7', 'all'), default='all')
    parser.add_argument('--repetitions', type=int, choices=(1, 2), default=2)
    parser.add_argument('--connection', default='openclaw-sandbox')
    parser.add_argument('--preview', action='store_true')
    parser.add_argument('--export-from', type=Path, help='Offline projection of an existing private run into --output JSON')
    parser.add_argument('--replay-from', type=Path, help='Offline fixture replay of a prior bounded hosted export; no provider calls')
    parser.add_argument('--export-replay-from', type=Path, help='Project a completed frozen fixture replay to bench/results')
    args = parser.parse_args()
    output = args.output.resolve()
    if args.export_from:
        export_compact(args.export_from.resolve(), output)
        return
    if args.export_replay_from:
        export_frozen_replay(args.export_replay_from.resolve(), output)
        return
    if args.replay_from:
        if output.exists() or not output.parent.is_dir() or output == run.REPO or run.REPO in output.parents:
            parser.error('replay output must be a fresh directory outside repository')
        replay_frozen(args.replay_from.resolve(), output, args.connection)
        return
    if output.exists() or not output.parent.is_dir() or output == run.REPO or run.REPO in output.parents:
        parser.error('output must be a fresh directory outside repository with existing parent')
    h12_count = ((len(H12) * 3 + 2) * 2 * args.repetitions if args.study in ('all', 'h12') else 0)
    h7_count = (len(H7) * 2 * 2 * args.repetitions if args.study in ('all', 'h7') else 0)
    if args.preview:
        print(json.dumps({'h12_calls_max': h12_count, 'h7_calls_max': h7_count,
            'models': MODELS, 'h12_cases': H12, 'h7_cases': H7, 'repetitions': args.repetitions,
             'provider_cost_stop_threshold_usd': 1.0, 'payload_bytes_not_tokens': True}))
        return
    key = os.environ.get('OPENROUTER_API_KEY')
    if not key:
        parser.error('OPENROUTER_API_KEY must be supplied by caller')
    output.mkdir(mode=0o700)
    manifest = {'created_utc': datetime.now(timezone.utc).isoformat(), 'study': args.study,
        'models': MODELS, 'repetitions': args.repetitions, 'calls_max': h12_count + h7_count,
        'endpoint': provider.ENDPOINT, 'hosted_controller': 'direct OpenRouter HTTP; not hosted OpenClaw',
        'h12_snapshot_exposed': False, 'h7_field_manifest_exposed': True,
        'field_manifest': 'controlled fixture source, not browser observation',
        'h7_runtime': 'semantic executor for both authoring schemas; procedural variables-to-facts lossless adapter',
        'provider_cost_stop_threshold_usd': 1.0, 'usage': 'provider-reported only; missing metrics remain null; one last call can exceed stop threshold',
        'sha256': {name: run.digest(HERE / name) for name in
                   ('hosted-focused.mjs', 'hosted-focused.py', 'decision_probe.py', 'run.py', 'challenge.js', 'server.js')},
        'core_sha256': run.digest(HERE.parent / 'core.mjs'),
        'resolver_sha256': run.digest(HERE.parent / 'resolver.mjs')}
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    (output / 'manifest.json').chmod(0o600)
    rows, spent = [], 0.0
    def save(row):
        rows.append(row)
        with (output / 'attempts.jsonl').open('a', encoding='utf8') as stream:
            stream.write(json.dumps(row, sort_keys=True) + '\n')
        (output / 'attempts.jsonl').chmod(0o600)
    env = dict(os.environ, CAMOFOX_ACCESS_KEY=secrets.token_hex(32))
    env.pop('OPENROUTER_API_KEY', None)
    stop_reason = None
    try:
      with run.temporary_fixture('podman', args.connection, run.IMAGE, env) as (ports, oracle_key):
        tasks = {t['id']: t for t in run.fetch_json(f'http://127.0.0.1:{ports["fixture"]}/api/challenge/tasks')}
        with tempfile.TemporaryDirectory(prefix='hosted-focused-', dir='/var/folders/l9/6md8t1991gndsmclcpg0_6340000gn/T/opencode') as tmp:
            for repetition in range(args.repetitions):
                if args.study in ('all', 'h12'):
                    save(local_case({'study': 'h12', 'task': tasks['challenge-62'], 'arm': 'mapping_diagnostic',
                        'model': None, 'repetition': repetition}, ports, oracle_key, env, tmp))
                for task_id in (H12 if args.study in ('all', 'h12') else ()):
                    for arm in ('original', 'selected', 'structured') + (('compact', 'stale') if task_id == 'challenge-55' else ()):
                        for model in MODELS:
                            if spent >= 0.9:
                                raise StopIteration('conservative_pre_call_budget_guard')
                            spec = {'study': 'h12', 'task': tasks[task_id], 'arm': arm,
                                    'model': model, 'repetition': repetition}
                            result = local_case(spec, ports, oracle_key, env, tmp, key)
                            save(result)
                            if result.get('hosted_calls') == 0:
                                continue
                            usage = result['hosted']['usage']
                            cost = usage.get('cost_usd') if usage else None
                            if cost is not None:
                                spent += cost
                            if cost is None or spent >= 1.0 or result['hosted']['http_status'] in (401, 402, 403):
                                raise StopIteration('missing_cost_or_budget_or_provider_block')
                for task_id in (H7 if args.study in ('all', 'h7') else ()):
                    for model in MODELS:
                        for arm in ('procedural', 'semantic'):
                            if spent >= 0.9:
                                raise StopIteration('conservative_pre_call_budget_guard')
                            task = tasks[task_id]
                            call = hosted(generation_request(model, task, arm), key)
                            contract, error, diagnostic = validate(call.pop('answer'), task, arm)
                            base = {'study': 'h7', 'task': task, 'arm': arm,
                                    'model': model, 'repetition': repetition}
                            entry = {**base, 'task': task_id, 'generator': call, 'validation': error or 'valid',
                                     'validation_diagnostic': diagnostic,
                                     'contract': contract, 'controlled_field_manifest_exposed': True,
                                     'adapter': 'lossless_variables_to_facts' if arm == 'procedural' else 'identity_facts',
                                     'held_constant': {'executor': 'semantic', 'boundary': 'adaptive', 'max_steps': 8,
                                                       'decision_policy': 'fixed-oracle-navigation'}}
                            if contract:
                                entry['replays'] = {}
                                for label, bindings in [('returned', contract.get('bindings')),
                                    ('fixed_manual', MANUAL[task_id]), ('local_resolver', None)]:
                                    replay = {**contract}
                                    if bindings is None:
                                        replay.pop('bindings', None)
                                    else:
                                        replay['bindings'] = bindings
                                    entry['replays'][label] = local_case({**base, 'contract': replay},
                                                                         ports, oracle_key, env, tmp)
                            save(entry)
                            usage = call['usage']
                            cost = usage.get('cost_usd') if usage else None
                            if cost is not None:
                                spent += cost
                            if cost is None or spent >= 1.0 or call['http_status'] in (401, 402, 403):
                                raise StopIteration('missing_cost_or_budget_or_provider_block')
    except StopIteration as error:
        stop_reason = str(error)
    finally:
        (output / 'summary.json').write_text(json.dumps({'attempted': len(rows),
            'known_cost_usd': round(spent, 9), 'stopped_reason': stop_reason,
            'cost_complete': all(((row.get('hosted') or row.get('generator') or {}).get('usage') or {}).get('cost_usd')
                                 is not None for row in rows if row.get('hosted_calls') != 0),
            'total_cost_usd': round(spent, 9) if not stop_reason else None}, indent=2) + '\n')
        (output / 'summary.json').chmod(0o600)
    return rows, spent


if __name__ == '__main__':
    main()
