#!/usr/bin/env python3
"""Frozen synthetic browser decision frontiers; private capture and bounded public projection."""
import argparse
import hashlib
import importlib.util
import json
import os
import secrets
import subprocess
import tempfile
from pathlib import Path

import decision_probe as provider
import run

HERE = Path(__file__).resolve().parent
NODE = HERE / 'space-frontier-probe.mjs'
TEMP = Path('/var/folders/l9/6md8t1991gndsmclcpg0_6340000gn/T/opencode')
FIXTURE_SHA256 = 'b409daf0b142a6a6c1b02e6d2c16c532dc96341bf94714526762d58a2f2343e7'


def sibling_module(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


study = sibling_module('space_study_frontier', 'space-study.py')
hosted_helper = sibling_module('hosted_focused_frontier', 'hosted-focused.py')
SYSTEM = ('Choose exactly one legal action index to advance the original goal using only the supplied '
          'native executor request and its current observed state. DONE means STOP/request human checkpoint; '
          'it is not proof of terminal success. BLOCKED means ESCALATE. '
          'Reply only JSON {"choice_index": integer}. No tools.')
LABELS = ('first_form', 'first_receipt', 'intermediate_receipt', 'final_receipt', 'branch_choice')


def digest(data):
    return hashlib.sha256(data).hexdigest()


def save(path, value):
    with path.open('x', encoding='utf8') as stream:
        json.dump(value, stream, sort_keys=True, indent=2)
        stream.write('\n')
    path.chmod(0o600)


def validate(frozen):
    records = frozen.get('records')
    if (not isinstance(records, list) or len(records) != 5 or
        [r.get('label') for r in records] != list(LABELS) or
        any(not isinstance(r.get('input', {}).get('state'), dict) or
            not isinstance(r.get('input', {}).get('choices'), list) or
            len(r['input']['choices']) > 32 or
            not isinstance(r.get('native_requests'), dict) or
            set(r['native_requests']) != {'with_stop', 'without_stop'} for r in records)):
        raise ValueError('invalid_frozen_records')
    return records


def local_only(args, output):
    if not args.executable or not args.executable.is_absolute() or not os.access(args.executable, os.X_OK):
        raise ValueError('provide an absolute executable native worker path')
    source = HERE.parent / 'core.mjs'
    hashes = {name: run.digest(path) for name, path in {
        'core': source, 'resolver': HERE.parent / 'resolver.mjs', 'bridge': HERE.parent / 'bridge.mjs',
        'fixtures': HERE / 'space-fixtures.js', 'server': HERE / 'server.js',
        'recorder': NODE, 'orchestrator': Path(__file__), 'guard': HERE / 'space-study.py'}.items()}
    if hashes['fixtures'] != FIXTURE_SHA256:
        raise ValueError('fixture_hash_not_stable_b409')
    env = dict(os.environ, CAMOFOX_ACCESS_KEY=secrets.token_hex(32))
    env.pop('OPENROUTER_API_KEY', None)
    output.mkdir(mode=0o700)
    captures = []
    try:
        with tempfile.TemporaryDirectory(prefix='space-frontier-', dir=TEMP) as tmp:
            private = Path(tmp)
            copy = private / 'core.mjs'
            provenance = study.guarded_copy(source, copy, 'aggressive')
            with run.temporary_fixture('podman', args.connection, run.IMAGE, env) as (ports, oracle_key):
                tasks = {t['id']: t for t in run.fetch_json(f'http://127.0.0.1:{ports["fixture"]}/api/space/tasks')}
                for task_id in ('space-01', 'space-02'):
                    spec = private / f'{task_id}-spec.json'
                    result = private / f'{task_id}-capture.json'
                    save(spec, {'task': tasks[task_id], 'corePath': str(copy),
                        'expectedCoreHash': provenance['derived_sha256'],
                        'baseUrl': f'http://127.0.0.1:{run.PORT_INSIDE}',
                        'camofoxUrl': f'http://127.0.0.1:{ports["camofox"]}'})
                    subprocess.run(['node', str(NODE), 'capture', str(spec), str(result)],
                        env=env, check=True, timeout=260)
                    row = json.loads(result.read_text())
                    oracle = run.fetch_json(f'http://127.0.0.1:{ports["fixture"]}/api/space/runs/{row.pop("runId")}', oracle_key)
                    if task_id == 'space-01' and (not oracle['passed'] or oracle['post_success_overrun']):
                        raise ValueError('final_receipt_not_clean')
                    if task_id == 'space-02' and (oracle['success_step'] is not None or oracle['mistakes']):
                        raise ValueError('branch_capture_mutated_choice')
                    captures.extend(row['records'])
            frozen = {'scope': 'private_callback_state_and_native_requests', 'records': captures,
                'sources': hashes, 'core_copy': provenance, 'native_sha256': run.digest(args.executable),
                'fixture': 'stable-b409', 'capture': {'space-01': 'clean_final_receipt_no_restart',
                    'space-02': 'stopped_before_branch_choice'}, 'hosted_calls': 0}
            validate(frozen)
            save(output / 'frozen-private.json', frozen)
            spec = private / 'local-spec.json'
            save(spec, {'frozen': captures, 'executable': str(args.executable)})
            subprocess.run(['node', str(NODE), 'local', str(spec), str(output / 'local-private.json')],
                env=env, check=True, timeout=260)
    finally:
        if any(run.digest(path) != hashes[name] for name, path in {
            'core': source, 'resolver': HERE.parent / 'resolver.mjs', 'bridge': HERE.parent / 'bridge.mjs',
            'fixtures': HERE / 'space-fixtures.js', 'server': HERE / 'server.js',
            'recorder': NODE, 'orchestrator': Path(__file__), 'guard': HERE / 'space-study.py'}.items()):
            raise RuntimeError('source_changed_during_capture')
    print(json.dumps({'private_directory': str(output), 'frozen_records': len(captures),
        'local_calls': len(json.loads((output / 'local-private.json').read_text())), 'hosted_calls': 0}))


def hosted_from(source, output, key, sol_final):
    frozen = json.loads(source.read_text())
    records = validate(frozen)
    if frozen.get('scope') != 'private_callback_state_and_native_requests':
        raise ValueError('invalid_private_source')
    output.mkdir(mode=0o700)
    results, cost, reason = [], 0.0, None
    # Original callback state is never augmented with an oracle answer. No AX snapshot or full fact manifest.
    for record in records:
        for arm in ('with_stop', 'without_stop'):
            for model in ((provider.MODELS[0], provider.MODELS[1]) if sol_final and
                          record['label'] == 'final_receipt' else (provider.MODELS[0],)):
                if len(results) >= 12 or cost >= 0.025:
                    reason = 'call_or_conservative_cost_cap'
                    break
                choices = record['input']['choices']
                if arm == 'without_stop':
                    choices = [c for c in choices if not c.startswith('STOP ')]
                native = record['native_requests'][arm]
                actions = [{'index': i, 'kind': c.split(' ')[0], 'operation':
                    {'STOP': 'DONE', 'ESCALATE': 'BLOCKED', 'TYPE': 'TYPE_TEXT',
                     'SELECT': 'CLICK', 'SCROLL': 'SCROLL_DOWN'}.get(c.split(' ')[0], 'CLICK'),
                    'target': c[:232]} for i, c in enumerate(choices)]
                payload = {'native_request': native, 'legal_actions': actions}
                request = {'model': model, 'messages': [{'role': 'system', 'content': SYSTEM},
                    {'role': 'user', 'content': json.dumps(payload, sort_keys=True)}],
                    'response_format': {'type': 'json_object'}, 'reasoning': {'effort': 'low'},
                    'max_completion_tokens': 384, 'stream': False}
                # Provider helper handles non-redirecting bounded HTTP and usage; keep only indices.
                call = hosted_helper.hosted(request, key)
                answer = call.pop('answer')
                index = answer.get('choice_index') if isinstance(answer, dict) and set(answer) == {'choice_index'} else None
                if type(index) is not int or not 0 <= index < len(actions):
                    index = None
                usage = call.get('usage') or {}
                row = {'label': record['label'], 'arm': arm, 'model': model,
                    'choice_index': index, 'kind': actions[index]['kind'] if index is not None else None,
                    'operation': actions[index]['operation'] if index is not None else None,
                    'request_sha256': call['request_sha256'], 'request_bytes': call['request_bytes'],
                    'http_status': call['http_status'], 'error': call['error'], 'usage': call['usage'],
                    'native_request_sha256': digest(json.dumps(native, sort_keys=True).encode())}
                results.append(row)
                save(output / f'call-{len(results):02d}.json', row)
                if usage.get('cost_usd') is None or call['http_status'] in (401, 402, 403):
                    reason = 'missing_cost_or_provider_block'
                    break
                cost += usage['cost_usd']
                if cost >= 0.03:
                    reason = 'cost_cap'
                    break
            if reason:
                break
        if reason:
            break
    save(output / 'summary.json', {'source_sha256': run.digest(source), 'calls': len(results),
        'known_cost_usd': cost, 'cost_complete': all(r['usage'] and
        r['usage'].get('cost_usd') is not None for r in results), 'stop_reason': reason,
        'endpoint': provider.ENDPOINT, 'hosted_controller': 'direct_HTTP_not_browser_loop',
        'confidence_comparable_to_local': False})
    print(json.dumps({'calls': len(results), 'known_cost_usd': cost, 'stop_reason': reason}))


def export(source, output, hosted):
    frozen_path = source / 'frozen-private.json'
    frozen = json.loads(frozen_path.read_text())
    records = validate(frozen)
    local_path = source / 'local-private.json'
    local = json.loads(local_path.read_text())
    if len(local) != 10 or output.parent != HERE / 'results':
        raise ValueError('unexpected_local_results_or_output')
    public = []
    for r in records:
        if r['label'] not in LABELS:
            raise ValueError('unexpected_label')
        public.append({'label': r['label'], 'task': 'space-02' if r['label'] == 'branch_choice' else 'space-01',
            'state_sha256': digest(json.dumps(r['input']['state'], sort_keys=True).encode()),
            'choices_sha256': digest(json.dumps(r['input']['choices'], sort_keys=True).encode()),
            'choice_count': len(r['input']['choices']),
            'available_kinds': sorted(set(c.split(' ')[0] for c in r['input']['choices'])),
            'native_request_sha256': {arm: digest(json.dumps(req, sort_keys=True).encode())
                for arm, req in r['native_requests'].items()}})
    hosted_rows, hosted_hash = [], None
    if hosted:
        summary = json.loads((hosted / 'summary.json').read_text())
        if summary['source_sha256'] != run.digest(frozen_path) or summary['calls'] > 12:
            raise ValueError('hosted_source_mismatch')
        hosted_hash = run.digest(hosted / 'summary.json')
        hosted_rows = [json.loads((hosted / f'call-{i:02d}.json').read_text())
                       for i in range(1, summary['calls'] + 1)]
        if any(row['label'] not in LABELS or row['arm'] not in ('with_stop', 'without_stop') or
               row['model'] not in provider.MODELS for row in hosted_rows):
            raise ValueError('invalid_hosted_row')
    safe_local = []
    for row in local:
        if row.get('label') not in LABELS or row.get('arm') not in ('with_stop', 'without_stop'):
            raise ValueError('unexpected_local_row')
        safe_local.append({key: value for key, value in row.items() if key in
            ('label', 'arm', 'selected_index', 'confidence', 'margin', 'operation_count',
             'target_counts', 'error')} | {'selected_kind': row.get('selected', {}).get('kind'),
            'top2': [{key: item.get(key) for key in ('index', 'kind', 'probability')}
                     for item in row.get('top2', [])]})
    save(output, {'scope': 'frozen_live_observation_decision_probe_not_full_browser_comparison',
        'semantic_gap': 'STOP is a caller checkpoint mapped to native DONE; DONE is not oracle success',
        'fixture': frozen['fixture'], 'capture': frozen['capture'], 'sources': frozen['sources'],
        'core_copy': frozen['core_copy'], 'native_sha256': frozen['native_sha256'],
        'private_source_sha256': run.digest(frozen_path), 'local_source_sha256': run.digest(local_path),
        'hosted_summary_sha256': hosted_hash, 'records': public, 'local': safe_local, 'hosted': hosted_rows,
        'limits': ['native probabilities factor operation and target; hosted choice indices have no compatible confidence',
                   'one live observation per frontier; no hosted browser control or oracle answers',
                   'provider usage and cost are reported only when present; cache/billing unknown otherwise']})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--local-only', action='store_true')
    mode.add_argument('--hosted-from', type=Path)
    mode.add_argument('--export-from', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--executable', type=Path)
    parser.add_argument('--connection', default='openclaw-sandbox')
    parser.add_argument('--sol-final', action='store_true')
    parser.add_argument('--hosted-results', type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() or not output.parent.is_dir():
        parser.error('output must be new with an existing parent')
    if args.local_only:
        if run.REPO in output.parents or TEMP.resolve() not in output.parents:
            parser.error('private output must be inside the approved temporary directory')
        local_only(args, output)
    elif args.hosted_from:
        if run.REPO in output.parents or TEMP.resolve() not in output.parents:
            parser.error('private output must be inside the approved temporary directory')
        key = os.environ.get('OPENROUTER_API_KEY')
        if not key:
            parser.error('OPENROUTER_API_KEY must be supplied by caller')
        hosted_from(args.hosted_from.resolve(), output, key, args.sol_final)
    else:
        export(args.export_from.resolve(), output, args.hosted_results.resolve() if args.hosted_results else None)


if __name__ == '__main__':
    main()
