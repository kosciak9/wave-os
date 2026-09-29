#!/usr/bin/env python3
"""Summarize already-sanitized hosted benchmark artifacts without running a model."""

import argparse
import hashlib
import json
import os
import re
from pathlib import Path

import run


def summarize(directory):
    manifest = json.loads((directory / 'manifest.json').read_text())
    records = []
    for line in (directory / 'measurements.jsonl').read_text().splitlines():
        row = json.loads(line)
        task = row['task']
        matched = list(directory.glob(task + '-*/synthetic-tool-trace.json'))
        if len(matched) > 1:
            raise ValueError('duplicate sanitized traces for measured task')
        trace = json.loads(matched[0].read_text()) if matched else []
        timelines = list(directory.glob(task + '-*/hosted-trace.json'))
        if len(timelines) > 1:
            raise ValueError('duplicate hosted timelines for measured task')
        timeline = json.loads(timelines[0].read_text()) if timelines else []
        usage = row.get('hosted_usage') or []
        observed_usage = bool(usage) and (row.get('status') == 'ok' or any(
            entry.get(key) for entry in usage for key in ('input', 'cacheRead', 'cacheWrite', 'output')))
        components = {key: sum(entry.get(key) or 0 for entry in usage) if observed_usage else None for key in
                      ('input', 'cacheRead', 'cacheWrite', 'output')}
        complete = observed_usage and all(all(isinstance(entry.get(key), int) and entry[key] >= 0
                                           for key in components) for entry in usage)
        run_complete = row.get('usage_complete', row.get('status') == 'ok' and
                               not row.get('step_budget_hit') and not row.get('steps_budget_hit'))
        contracts = []
        for index, event in enumerate(trace):
            if event.get('tool') != 'browser_execute':
                continue
            contract = event.get('fixture_contract') or {}
            shape = {'variable_count': contract.get('variable_count'),
                     'variable_names': contract.get('variable_names'),
                     'binding_count': contract.get('binding_count'),
                     'binding_names': contract.get('binding_names'),
                     'raw_key_metadata_available': 'variable_count' in contract,
                     'visible_fixture_variable_names': sorted((contract.get('variables') or {}).keys()),
                     'visible_fixture_binding_names': sorted((contract.get('bindings') or {}).keys())}
            following = []
            for candidate in trace[index + 1:]:
                if candidate.get('tool') == 'browser_execute':
                    break
                following.append(candidate)
            outcome = next((candidate['executor_outcome'] for candidate in following
                            if 'executor_outcome' in candidate), None)
            next_snapshot = next((candidate['snapshot_excerpt'] for candidate in following
                                  if 'snapshot_excerpt' in candidate), None)
            heading = re.search(r'heading "([^"\n]{1,80})"', next_snapshot or '')
            contracts.append({'request': event.get('fixture_contract'), 'contract_shape': shape,
                              'outcome': outcome,
                              'next_exposed_heading': heading[1] if heading else None})
        calls = [call for entry in timeline for call in entry.get('calls', [])
                 if call.get('tool') == 'browser_execute']
        results = [entry for entry in timeline if entry.get('role') == 'result' and
                   entry.get('tool') == 'browser_execute']
        if len(calls) == len(results) == len(contracts):
            for contract, call, result in zip(contracts, calls, results):
                contract['tool_request_json_bytes'] = call.get('request_bytes')
                contract['tool_result_text_bytes'] = result.get('output_bytes')
        else:
            for contract in contracts:
                contract['tool_request_json_bytes'] = None
                contract['tool_result_text_bytes'] = None
        snapshot_bytes = [entry.get('output_bytes') for entry in timeline if entry.get('role') == 'result' and
                          entry.get('tool') == 'camofox_snapshot']
        direct = {name: sum(event.get('tool') == name for event in trace) for name in
                  ('camofox_click', 'camofox_type', 'camofox_select', 'camofox_scroll', 'camofox_navigate')} if matched else None
        failure = row.get('failure') or {}
        records.append({'task': task, 'status': row.get('status'), 'oracle_passed': row.get('success'),
                        'oracle_unavailable': row.get('oracle_unavailable'),
                        'mistakes': row.get('mistakes'), 'wrong_actions': row.get('wrong_actions'),
                        'wall_seconds': row.get('wall_seconds'), 'assistant_turns': row.get('turns_observed'),
                        'assistant_usage_entries': len(usage), 'observed_tokens': components,
                        'sanitized_trace_available': bool(matched),
                        'usage_complete': run_complete,
                        'normalized_prompt_tokens': (sum(components[key] for key in
                            ('input', 'cacheRead', 'cacheWrite')) if complete and run_complete else None),
                        'observed_prompt_tokens': (sum(components[key] for key in
                            ('input', 'cacheRead', 'cacheWrite')) if complete else None),
                        'legacy_input_plus_cache_read': row.get('model_input_plus_cache'),
                        'catalog_estimated_usd': row.get('estimated_usd'),
                        'billed_usd': None, 'model_visible_camofox_calls': row.get('camofox_actions'),
                        'model_visible_snapshots': row.get('snapshots_exposed'),
                        'model_visible_snapshot_result_bytes': sum(snapshot_bytes) if timeline and
                            all(isinstance(value, int) and value >= 0 for value in snapshot_bytes) else None,
                        'direct_mutation_calls': direct,
                        'executor_calls': contracts if matched else None, 'executor_steps_reported':
                        sum((call['outcome'] or {}).get('steps', 0) for call in contracts) if matched else None,
                        'local_action_telemetry': row.get('local_steps'),
                        'local_model_calls': row.get('local_calls'),
                        'local_model_errors': row.get('local_model_errors'),
                        'local_model_actions': row.get('local_model_actions'),
                        'local_deterministic_actions': row.get('local_deterministic_actions'),
                        'local_snapshots_unexposed': row.get('local_snapshots_unexposed'),
                        'local_snapshots_by_purpose': row.get('snapshots_by_purpose'),
                        'local_latency_ms': row.get('local_latency_ms'),
                        'local_result_reasons': row.get('executor_results'),
                        'hosted_tool_budget': row.get('hosted_tool_budget', manifest.get('hosted_tool_budget')),
                        'hosted_tool_calls_observed': row.get('hosted_tool_calls_observed'),
                        'hosted_tool_budget_hit': row.get('steps_budget_hit'),
                        'model_visible_tool_errors': sum('tool_error' in event for event in trace) if matched else None,
                        'provider_stop_reason': run.provider_block_reason(failure),
                        'failure': {key: failure.get(key) for key in ('kind', 'exit_code', 'http_status')}
                        if failure else None})
    return {'source_directory': directory.name, 'model': manifest.get('model'),
            'suite': manifest.get('suite'), 'source_fingerprint': manifest.get('code_fingerprint_sha256'),
            'fixture_sha256': manifest.get('fixture_sha256'),
            'executor_configuration': manifest.get('executor_configuration'),
            'recorded_prompt_template_sha256': manifest.get('prompt_template_sha256'),
            'manifest_hosted_tool_budget': manifest.get('hosted_tool_budget'), 'runs': records}


def public_text(value, limit=240):
    if not isinstance(value, str):
        return None
    value = re.sub(r'(?i)\b(?:https?|file)://\S+|\bsk-[a-z0-9_-]{4,}\b', '[redacted]', value)
    value = re.sub(r'(?i)\b(?:api[_-]?key|bearer|password|passphrase|secret|token)\b\s*[:=]?\s*\S*',
                   '[redacted]', value)
    value = re.sub(r'\b[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\b|'
                   r'(?<!\w)/(?:run|Users|var|nix|private|tmp)/\S+', '[redacted]', value)
    value = re.sub(r'\b127\.0\.0\.1(?::\d+)?\b', '[fixture-host]', value)
    return re.sub(r'[^\x20-\x7e]', ' ', value)[:limit]


def public_value(value, limit=240):
    if isinstance(value, str):
        return public_text(value, limit)
    if isinstance(value, (int, float, bool)) or value is None:
        return value
    if isinstance(value, list):
        return [public_value(item, limit) for item in value[:32]]
    if isinstance(value, dict):
        return {key: public_value(item, 600 if key == 'goal' else 360 if key == 'modelGoal' else limit)
                for key, item in list(value.items())[:32]
                if isinstance(key, str) and re.fullmatch(r'[a-zA-Z][a-zA-Z0-9_]{0,47}', key)}
    return None


LOCAL_SOURCES = (
    'semantic-final-model-34', 'semantic-negatives-final', 'semantic-identical-final',
    'semantic-regression-31', 'semantic-qualified-34', 'semantic-wrong-final',
    'preserve-final-spotcheck', 'preserve-final-changed', 'preserve-future-binding-31',
    'preserve-oracle-conflict', 'preserve-oracle-hidden-final', 'preserve-oracle-unsafe-caller',
    'preserve-model-positive', 'preserve-model-changed',
    'workflow-final-baseline40', 'workflow-final-counter41', 'workflow-final-counter42',
    'workflow-final-counter43', 'workflow-final-multiroute', 'workflow-final-scope',
    'workflow-booking-reasoning-model',
    'outcome-final-broad', 'outcome-final-strong', 'outcome-final-missing-preference',
    'outcome-final-oracle-multiroute', 'outcome-final-oracle-scope',
    'final-verify-31-strong-285d', 'final-verify-31-weak-285d',
    'final-verify-36-changed-285d', 'final-verify-41-duplicate-285d',
    'final-verify-42-sensitive-285d', 'final-verify-44-strong-285d',
    'final-verify-44-weak-285d', 'final-verify-challenge38-285d',
    'final-verify-long07-285d',
    'stop-after-model-garden', 'stop-after-model-long',
    'stop-after-oracle-advance', 'stop-after-oracle-duplicate',
    'stop-after-oracle-garden', 'stop-after-oracle-long',
)

HOSTED_SOURCES = (
    'luna-control-forms03-pr19', 'luna-control-forms03-retry-pr19',
    'luna-control-forms03-endpoint-pr19', 'luna-hybrid-forms03-pr19',
    'luna-delegated-control-pair-a', 'luna-delegated-hybrid-pair-a',
    'luna-workflow-control-final', 'luna-workflow-hybrid-final',
    'luna-workflow-control-budget60-a', 'luna-workflow-hybrid-budget60-a',
    'luna-contract-v2-long-control', 'luna-contract-v2-long-hybrid',
    'luna-contract-v2-workflow-control', 'luna-contract-v2-workflow-hybrid',
    'sol-contract-v2-long-control', 'sol-contract-v2-long-hybrid',
    'sol-contract-v2-workflow-control', 'sol-contract-v2-workflow-hybrid',
    'sol-contract-v2-budget5-long-control', 'sol-contract-v2-budget5-long-hybrid',
    'sol-contract-v2-budget5-workflow-control', 'sol-contract-v2-budget5-workflow-hybrid',
    'luna-action-boundary-long-control', 'luna-action-boundary-long-hybrid',
    'luna-action-boundary-booking-control', 'luna-action-boundary-booking-hybrid',
    'sol-action-boundary-long-control', 'sol-action-boundary-long-hybrid',
    'sol-action-boundary-booking-control', 'sol-action-boundary-booking-hybrid',
)


def local_evidence(root):
    facts, provenance = [], []
    settings = ('threshold', 'margin', 'candidateMode', 'applyPrepared', 'representation',
                 'modelHistory', 'modelGoal', 'stopPolicy', 'successContract', 'semanticBinding',
                'preserveVariant', 'executionScope', 'stopAfter', 'successMode', 'maxSteps')
    for name in LOCAL_SOURCES:
        directory = root / name
        manifest = json.loads((directory / 'manifest.json').read_text())
        provenance.append({'source': name, 'fixture_sha256': {key: manifest.get(key) for key in
                           ('tasks_sha256', 'server_sha256', 'challenge_sha256')},
                           'runtime_sha256': {key: manifest.get(key) for key in
                           ('core_sha256', 'bridge_sha256', 'camofox_sha256', 'source_runtime_sha256',
                            'packaged_runtime_sha256', 'model_executable_sha256')},
                           'producer_sha256': manifest.get('diagnostic_sha256'),
                           'source_head': manifest.get('source_head'),
                           'settings': {key: public_value(manifest.get('configuration', {}).get(key))
                                        for key in settings if key in manifest.get('configuration', {})}})
        for artifact in sorted(directory.glob('*.json')):
            if artifact.name == 'manifest.json':
                continue
            data = json.loads(artifact.read_text())
            result = data.get('result') or {}
            oracle = data.get('oracle') or {}
            url = result.get('current_url') or ''
            route = url.rsplit('/', 1)[-1] if isinstance(url, str) and re.fullmatch(
                r'http://127\.0\.0\.1:38891/run/[\w-]{8,128}/[a-z]+-\d\d/[a-z]+', url) else None
            events = oracle.get('events') or []
            trace = data.get('trace') or []
            facts.append({'source': name, 'task': data.get('task'), 'backend': data.get('backend'),
                          'artifact_sha256': hashlib.sha256(artifact.read_bytes()).hexdigest(),
                          'executed_core_sha256': data.get('source'),
                          'error_kind': public_text(data.get('errorKind'), 80),
                          'status': result.get('status'), 'reason': result.get('reason'),
                          'verification': result.get('verification'),
                          'observed_action': public_value(result.get('observed_action'))
                          if result.get('verification') == 'action_and_fresh_observation' and route else None,
                          'diagnostic_reason': result.get('diagnostic_reason'),
                          'diagnostic_field': public_text(result.get('diagnostic_field'), 140),
                          'matched_conditions': [value for value in result.get('matched_conditions', [])
                                                 if value in ('textIncludes', 'allText', 'fieldValues', 'urlPath')],
                          'fixture_route': route, 'relevant_state': public_text(result.get('relevant_state'), 240)
                          if route else None, 'steps': result.get('steps'),
                          'oracle_passed': oracle.get('passed'), 'oracle_unavailable': oracle.get('unavailable'),
                          'oracle_mistakes': oracle.get('mistakes'),
                          'oracle_valid_submissions': sum(e.get('valid') is True for e in events),
                          'oracle_invalid_submissions': sum(e.get('valid') is False for e in events),
                          'model_calls': data.get('model_calls'), 'local_actions': data.get('local_actions'),
                          'hidden_snapshots': data.get('hidden_snapshots'),
                          'local_deterministic_actions': sum(e.get('metric', {}).get('event') == 'action' and
                              e['metric'].get('deterministic') is True for e in trace
                              if isinstance(e.get('metric'), dict)),
                           'request': {'success': public_value((data.get('request') or {}).get('success')),
                                       'stop_after': public_value((data.get('request') or {}).get('stopAfter')),
                                       'bindings': public_value((data.get('request') or {}).get('bindings')),
                                      'field_policies': public_value((data.get('request') or {}).get('fieldPolicies')),
                                      'model_goal': public_text((data.get('request') or {}).get('modelGoal'), 300)}})
    return facts, provenance


def hosted_evidence(root):
    sources = [summarize(root / name) for name in HOSTED_SOURCES]
    for source in sources:
        for row in source['runs']:
            for call in row.get('executor_calls') or []:
                call['request'] = public_value(call.get('request'))
                call['outcome'] = public_value(call.get('outcome'))
                call['next_exposed_heading'] = public_text(call.get('next_exposed_heading'), 80)
    return sources


def export_evidence(root, output):
    if any((output / name).exists() for name in
           ('contract-diagnostics.jsonl', 'contract-hosted.json', 'contract-manifest.json')):
        raise ValueError('evidence files already exist; never overwrite historical evidence')
    facts, provenance = local_evidence(root)
    sources = hosted_evidence(root)
    prompt = (root / 'luna-delegation-prompt.txt').read_text()
    manifest = {'schema_version': 1, 'selection': 'Curated local diagnostic examples plus all recorded hosted'
                ' attempts from the listed source directories; NOT an independent or exhaustive suite.',
                'local_sources': provenance, 'hosted_sources': [{key: item.get(key) for key in
                    ('source_directory', 'suite', 'model', 'source_fingerprint', 'fixture_sha256',
                     'executor_configuration', 'manifest_hosted_tool_budget',
                     'recorded_prompt_template_sha256')} for item in sources],
                'unrecorded_startup': ['luna-workflow-control-a: empty directory, no manifest or measurements'],
                'prompt_template': public_text(prompt, 1200),
                'prompt_template_sha256': hashlib.sha256(prompt.encode()).hexdigest(),
                'prompt_provenance': 'Operator-supplied common template; included historical run manifests'
                ' do not attest prompt hash. Future runs record this hash in their manifests.',
                'interpretation_corrections': [
                    {'order': 1, 'earlier_claim': 'Luna and Sol challenge-45 omitted the preference variable.',
                     'correction': 'Retracted: historical trace projection included only fixture-manifest keys;'
                     ' the fixture specified party only. Historical preference key presence is unknown.'},
                    {'order': 2, 'later_instrumentation': 'Future synthetic traces record bounded safe variable'
                     ' and binding names/counts, without exporting non-manifest values. Existing traces'
                     ' remain incomplete and must not be reinterpreted as complete argument maps.'}],
                'sol_catalog_pricing_per_million_usd': {
                    'input': 20, 'output': 10, 'cacheRead': 2, 'cacheWrite': 2.5,
                    'provenance': 'Operator-supplied public model catalog; not a billing receipt.'},
                'measurement_limits': ['Older sanitized contract traces omit executionScope, origin policy,'
                    ' forbidActions, unknown-key counts and semantic result details; not evidence of their absence.',
                    'Historical synthetic variables and bindings include only fixture-manifest keys.'
                    ' Absence of preference on challenge-45 is UNKNOWN, not proof it was omitted by the model.'
                    ' New traces record bounded safe key names/counts without exposing non-manifest values.',
                    'Failed hosted runs without saved usage or trace have unknown totals, not zero billed cost.',
                    'Prices are catalog estimates; local oracle decisions are not hosted-model observations.',
                    '403 provider budget failures have no completed task outcome or reliable billed-cost total;',
                    ' a zero-usage assistant error is classified as missing usage, not zero spend.',
                    'A fixture oracle pass is independent of executor completed/checkpoint status.']}
    manifest['measurement_limits'].append('stopAfter is mutually exclusive with success and checkpoints after'
        ' the requested grounded click and fresh observation; it does not establish terminal receipt semantics.')
    manifest['measurement_limits'].append('Hosted tool result and snapshot byte counts measure sanitized transcript'
        ' tool-result text, not exact serialized wire traffic or model token counts. Hidden snapshot bytes are unavailable.')
    payloads = {'contract-diagnostics.jsonl': ''.join(json.dumps(row, sort_keys=True) + '\n' for row in facts),
                'contract-hosted.json': json.dumps({'sources': sources}, sort_keys=True, indent=2) + '\n',
                'contract-manifest.json': json.dumps(manifest, sort_keys=True, indent=2) + '\n'}
    for name, contents in payloads.items():
        with os.fdopen(os.open(output / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644), 'w') as stream:
            stream.write(contents)
    return len(facts), sum(len(source['runs']) for source in sources)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, action='append')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--evidence-temp', type=Path, help='Approved synthetic fixture artifact root')
    parser.add_argument('--evidence-results', type=Path, help='Existing repository bench/results directory')
    args = parser.parse_args()
    if args.evidence_temp or args.evidence_results:
        if (args.source or args.output or not args.evidence_temp or not args.evidence_results or
                args.evidence_results.resolve() != run.HERE / 'results'):
            parser.error('evidence export requires only --evidence-temp and --evidence-results=bench/results')
        local_count, hosted_count = export_evidence(args.evidence_temp.resolve(), args.evidence_results.resolve())
        print(json.dumps({'local_facts': local_count, 'hosted_runs': hosted_count}))
        return
    if not args.source or not args.output:
        parser.error('ordinary reports require --source and --output')
    output = args.output.resolve()
    if output.exists() or output == run.REPO or run.REPO in output.parents or not output.parent.is_dir():
        parser.error('output must be a new file outside the repository in an existing directory')
    report = {'accounting': 'OpenClaw normalized input + cacheRead + cacheWrite; raw provider prompt totals'
                             ' not retained; cost is catalog estimate, not billed OpenRouter usage.',
              'local_action_policy': 'Executor steps are outcome-reported; when available, local model calls,'
                                     ' action kinds and snapshot purposes come from value-free plugin telemetry.'
                                     ' Null means not measured, not zero.',
              'sources': [summarize(source.resolve()) for source in args.source]}
    with os.fdopen(os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as stream:
        json.dump(report, stream, indent=2, sort_keys=True)
        stream.write('\n')


if __name__ == '__main__':
    main()
