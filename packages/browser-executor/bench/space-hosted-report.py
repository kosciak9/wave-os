#!/usr/bin/env python3
"""Project value-free evidence from selected synthetic hosted space runs."""

import argparse
import json
import os
import re
from pathlib import Path


TASKS = {'space-01', 'space-02', 'space-03', 'space-04'}
CALLS = {'tool_search', 'tool_describe', 'camofox_create_tab', 'camofox_snapshot',
         'camofox_click', 'camofox_type', 'camofox_select', 'camofox_navigate',
         'camofox_scroll', 'camofox_close_tab', 'camofox_list_tabs'}
MUTATIONS = {'camofox_click', 'camofox_type', 'camofox_select',
             'camofox_navigate', 'camofox_scroll'}
ARGUMENT_NAMES = {'ref', 'tabId', 'text', 'url', 'direction', 'amount', 'offset', 'option', 'value'}
HEX = re.compile(r'[a-f0-9]{64}\Z')


def safe_hash(value):
    return value if isinstance(value, str) and HEX.fullmatch(value) else None


def safe_count(value):
    return value if type(value) is int and value >= 0 else None


def project(source):
    manifest = json.loads((source / 'manifest.json').read_text())
    count = manifest.get('task_count')
    if type(count) is not int or not 1 <= count <= 4 or not isinstance(manifest.get('fixture_sha256'), dict) or \
            not safe_hash(manifest['fixture_sha256'].get('space-fixtures.js')):
        raise ValueError('not a hosted space fixture source')
    rows = [json.loads(line) for line in (source / 'measurements.jsonl').read_text().splitlines() if line.strip()]
    if len(rows) != count or len({row.get('task') for row in rows}) != count or \
            not {row.get('task') for row in rows} <= TASKS or \
            any(row.get('scenario') != 'space' for row in rows):
        raise ValueError('unexpected space measurement selection')
    records = []
    for row in rows:
        task = row['task']
        traces = list(source.glob(task + '-*/hosted-trace.json'))
        if len(traces) != 1:
            raise ValueError('exactly one value-free hosted trace required for ' + task)
        timeline = json.loads(traces[0].read_text())
        if not isinstance(timeline, list):
            raise ValueError('invalid hosted timeline')
        calls = []
        snapshot_bytes = []
        tool_result_errors = 0
        stop_reasons = []
        for event in timeline:
            if event.get('role') == 'assistant':
                if event.get('stop') in ('toolUse', 'stop', 'error', 'length'):
                    stop_reasons.append(event['stop'])
                for call in event.get('calls', []):
                    name = call.get('tool')
                    if name not in CALLS:
                        name = 'other_tool'
                    calls.append({'tool': name, 'argument_names': sorted(set(call.get('argument_names', [])) & ARGUMENT_NAMES)
                                  if name.startswith('camofox_') else []})
            elif event.get('role') == 'result':
                if event.get('error'):
                    tool_result_errors += 1
                if event.get('tool') == 'camofox_snapshot':
                    snapshot_bytes.append(safe_count(event.get('output_bytes')))
        usage = row.get('hosted_usage') or []
        diagnostic = row.get('space_diagnostics') or {}
        inner_results = []
        for result in diagnostic.get('tool_results') or []:
            if result.get('tool') not in CALLS:
                continue
            inner_results.append({key: result.get(key) for key in
                ('tool', 'outer_is_error', 'wrapper_parse', 'inner_parse', 'inner_is_error',
                 'inner_status', 'error_class', 'snapshot_lines', 'snapshot_ref_markers',
                 'snapshot_editable_markers')})
        final = diagnostic.get('final_answer') or {}
        final_class = (final.get('class') if final.get('class') in
            ('unable_or_error', 'asks_for_information', 'claims_completion', 'other_or_empty', 'empty') else None)
        failure = row.get('failure') or {}
        provider_incomplete = failure.get('kind') == 'incomplete_turn' and \
            failure.get('message') == 'Provider returned an incomplete or malformed tool call'
        observed = {key: sum(entry[key] for entry in usage) if usage and
                    all(type(entry.get(key)) is int and entry[key] >= 0 for entry in usage) else None
                    for key in ('input', 'cacheRead', 'cacheWrite', 'output')}
        mutations = sum(call['tool'] in MUTATIONS for call in calls)
        server_steps = safe_count(row.get('server_action_steps'))
        first_failure = safe_count(row.get('first_failure_server_step'))
        completion = safe_count(row.get('success_server_step'))
        records.append({
            'task': task, 'agent_status': row.get('status') if row.get('status') in ('ok', 'error', 'timeout') else 'other',
            'supplied_fact_count': safe_count(row.get('supplied_fact_count')),
            'prompt_contains_variables': row.get('prompt_contains_variables') if
                type(row.get('prompt_contains_variables')) is bool else None,
            'formatted_prompt_sha256': safe_hash(row.get('formatted_prompt_sha256')),
            'final_assistant_stop': stop_reasons[-1] if stop_reasons else None,
            'oracle_passed': row.get('success') is True, 'oracle_available': row.get('oracle_unavailable') is False,
            'oracle_mistakes': safe_count(row.get('mistakes')),
            'failure_class': ('oracle_error' if first_failure is not None else
                              'provider_incomplete_tool_call' if provider_incomplete else
                              'completed_then_overran' if completion is not None and row.get('post_success_overrun') else
                              'model_stopped_before_completion' if stop_reasons[-1:] == ['stop'] and completion is None else
                              'incomplete_or_censored' if completion is None else 'completed'),
            'server_action_steps': server_steps, 'server_transitions': safe_count(row.get('server_transitions')),
            'provider_failure_kind': failure.get('kind') if failure.get('kind') in ('incomplete_turn', 'timeout', 'unknown') else None,
            'provider_http_status': failure.get('http_status') if failure.get('http_status') in (400, 401, 403, 429, 500, 502, 503, 504) else None,
            'first_failure_server_step': first_failure,
            'success_server_step': completion, 'post_success_overrun': row.get('post_success_overrun') is True,
            'server_actions_after_success': safe_count(row.get('server_actions_after_success')),
            'browser_mutation_calls': mutations,
            'first_failure_browser_mutation_bounds': row.get('first_failure_browser_mutation_bounds'),
            'completion_browser_mutation_bounds': row.get('completion_browser_mutation_bounds'),
            'browser_mutations_after_completion_bounds': row.get('browser_mutations_after_completion_bounds'),
            'snapshots_exposed': safe_count(row.get('snapshots_exposed')),
            'snapshot_result_bytes': sum(snapshot_bytes) if all(v is not None for v in snapshot_bytes) else None,
            'snapshot_repeat_exact_count': safe_count(row.get('snapshot_repeat_exact_count')),
            'snapshot_repeated_state_inference': 'unknown: only exact serialized result hashes are available',
            'tool_result_errors_visible': tool_result_errors,
            'tool_result_inner_error_class': 'classified in classified_tool_results' if diagnostic.get('available') is True
                else 'unavailable: historical value-free timeline omits result bodies',
            'diagnostics_added': diagnostic.get('available') is True,
            'classified_tool_results': inner_results if diagnostic.get('available') is True else None,
            'final_answer_class': final_class,
            'final_answer_present': final.get('text_present') if type(final.get('text_present')) is bool else None,
            'tool_calls': calls,
            'turns_observed': safe_count(row.get('turns_observed')),
            'observed_tokens': observed,
            'usage_complete': row.get('usage_complete') is True,
            'catalog_estimated_usd': row.get('estimated_usd') if isinstance(row.get('estimated_usd'), (float, int)) else None,
            'billed_usd': None,
            'outer_tool_budget': safe_count(row.get('hosted_tool_budget')),
            'outer_tool_budget_hit': row.get('steps_budget_hit') is True,
        })
    return {'schema_version': 1, 'source_label': source.name if re.fullmatch(r'[a-zA-Z0-9_-]{1,100}', source.name) else 'source',
            'selection': 'Operator-selected synthetic space hosted tasks; not a capability ranking.',
            'model': manifest.get('model') if manifest.get('model') in ('openrouter/openai/gpt-6-luna', 'openrouter/openai/gpt-6-sol') else None,
            'source_fingerprint_sha256': safe_hash(manifest.get('code_fingerprint_sha256')),
            'fixture_sha256': safe_hash(manifest['fixture_sha256']['space-fixtures.js']),
            'prompt_template_sha256': safe_hash(manifest.get('prompt_template_sha256')),
            'manifest_supplied_fact_count': safe_count(manifest.get('supplied_fact_count')),
            'manifest_prompt_contains_variables': manifest.get('prompt_contains_variables') if
                type(manifest.get('prompt_contains_variables')) is bool else None,
            'packaged_plugin_sha256': safe_hash((manifest.get('packaged_plugin_sha256') or {}).get('wrapper')),
            'limits': ['Oracle steps count server navigations/submissions, not client typing or attempted clicks.',
                       'A null first-failure step means no server-recorded mistake; it does not mean task success.',
                       'Mutation counts are model tool calls, not confirmed successful DOM mutations.',
                       'Sampled mutation bounds are absent when no failure/completion was observed.',
                       'A successful CLI exit is not a fixture oracle pass.',
                       'Exact serialized snapshot hashes do not establish semantic equality of browser states.',
                       'Hosted timeline omits assistant final message and tool-result bodies; intent and inner error causes are unknown.',
                       'Provider usage is normalized by OpenClaw; catalog estimates are not invoices.'],
            'runs': records}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    if (output.parent != Path(__file__).resolve().parent / 'results' or
            not re.fullmatch(r'space-large-(?:(?:luna|sol)-[a-z0-9-]{1,48}|diag-(?:luna|sol)|matched-(?:luna|sol))\.json',
                             output.name) or output.exists()):
        parser.error('output must be a new space-large-luna/sol-*.json or space-large-diag/matched-luna/sol.json in bench/results')
    payload = project(args.source.resolve())
    with os.fdopen(os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644), 'w') as stream:
        json.dump(payload, stream, sort_keys=True, indent=2)
        stream.write('\n')
    print(json.dumps({'runs': len(payload['runs']), 'oracle_passed': sum(row['oracle_passed'] for row in payload['runs'])}))


if __name__ == '__main__':
    main()
