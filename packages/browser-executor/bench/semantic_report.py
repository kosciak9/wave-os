#!/usr/bin/env python3
"""Export explicitly selected synthetic semantic-contract evidence without model calls."""

import argparse
import json
import os
import re
from pathlib import Path

import hosted_report
import run


SUFFIXES = ('diagnostics.jsonl', 'hosted.json', 'manifest.json', 'decisions.json')


def source_names(paths):
    resolved = [path.resolve() for path in paths]
    if len(resolved) != len(set(resolved)) or any(not path.is_dir() or
            not re.fullmatch(r'[a-zA-Z0-9_-]{1,80}', path.name) or
            not (path / 'manifest.json').is_file() for path in resolved):
        raise ValueError('each source must be a distinct named synthetic artifact directory with a manifest')
    if resolved and len({path.parent for path in resolved}) != 1:
        raise ValueError('all selected sources must share one artifact root')
    return resolved


def decision_evidence(directories):
    sources = []
    for directory in directories:
        manifest = json.loads((directory / 'manifest.json').read_text())
        summary = json.loads((directory / 'summary.json').read_text())
        rows = [json.loads(line) for line in (directory / 'attempts.jsonl').read_text().splitlines() if line.strip()]
        attempts = []
        for row in rows:
            answer = row.get('answer') or {}
            usage = row.get('usage') or {}
            attempts.append({'case': row.get('case'), 'question': hosted_report.public_text(row.get('question')),
                             'payload': hosted_report.public_value(row.get('payload')),
                             'diagnostic_expected': hosted_report.public_value(row.get('diagnostic_expected')),
                             'status': row.get('status'), 'error_kind': row.get('error_kind'),
                             'http_status': row.get('http_status'), 'finish_reason': row.get('finish_reason'),
                             'answer': {'action': answer.get('action'), 'option': answer.get('option'),
                                        'reason': hosted_report.public_text(answer.get('reason'))} if answer else None,
                             'matches_authored_expectation': row.get('matches_authored_expectation'),
                             'usage': {key: usage.get(key) for key in ('prompt_tokens', 'completion_tokens',
                                 'cached_tokens', 'cache_write_tokens', 'cost_usd')} if usage else None,
                             'request_sha256': row.get('request_sha256'),
                             'request_bytes': row.get('request_bytes'), 'elapsed_ms': row.get('elapsed_ms')})
        sources.append({'source_directory': directory.name, 'model': manifest.get('model'),
                        'probe_sha256': manifest.get('probe_sha256'),
                        'system_sha256': manifest.get('system_sha256'),
                        'parameters': manifest.get('request_parameters'),
                        'case_ids': manifest.get('case_ids'),
                        'summary': {key: summary.get(key) for key in ('attempted', 'requested',
                            'known_cost_usd', 'total_cost_usd', 'cost_complete',
                            'stopped_on_provider_block', 'stopped_on_http_error')},
                        'attempts': attempts})
    return sources


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--hosted', type=Path, action='append', default=[], help='Explicit completed or failed hosted source')
    parser.add_argument('--diagnostic', type=Path, action='append', default=[], help='Explicit synthetic diagnostic source')
    parser.add_argument('--decision', type=Path, action='append', default=[], help='Explicit standalone authored decision-probe source')
    parser.add_argument('--results', type=Path, required=True, help='Existing repository bench/results directory')
    parser.add_argument('--study', default='semantic', help='New safe evidence prefix; never overwrites earlier studies')
    parser.add_argument('--diagnostics-only', action='store_true',
                        help='Write only local diagnostic facts and manifest when no hosted/decision data exists')
    parser.add_argument('--decision-evidence', action='store_true',
                        help='Include bounded tool choices and selected decision for local-only evidence')
    args = parser.parse_args()
    if not re.fullmatch(r'[a-z][a-z0-9-]{0,31}', args.study):
        parser.error('--study must be a safe public label')
    if args.diagnostics_only and (args.hosted or args.decision or not args.diagnostic):
        parser.error('--diagnostics-only requires local --diagnostic sources and no hosted/decision sources')
    if args.decision_evidence and not args.diagnostics_only:
        parser.error('--decision-evidence requires --diagnostics-only')
    suffixes = (SUFFIXES[0], SUFFIXES[2]) if args.diagnostics_only else SUFFIXES
    names = tuple(args.study + '-' + suffix for suffix in suffixes)
    hosted = source_names(args.hosted)
    diagnostics = source_names(args.diagnostic)
    decisions = source_names(args.decision)
    selected = hosted + diagnostics + decisions
    if not selected or len(selected) != len(set(selected)) or len({path.parent for path in selected}) != 1:
        parser.error('select distinct hosted/diagnostic directories from one approved artifact root')
    output = args.results.resolve()
    if output != run.HERE / 'results' or any((output / name).exists() for name in names):
        parser.error('output must be untouched semantic evidence files in bench/results')
    root = selected[0].parent
    hosted_sources = hosted_report.hosted_evidence(root, [path.name for path in hosted])
    facts, provenance = hosted_report.local_evidence(root, [path.name for path in diagnostics],
                                                      include_decision_evidence=args.decision_evidence)
    decision_sources = decision_evidence(decisions)
    current_cores = {source['source_sha256']['core'] for source in hosted_sources
                     if isinstance(source.get('source_sha256'), dict) and source['source_sha256'].get('core')}
    for fact in facts:
        fact['fact_id'] = fact['artifact_sha256']
    for source in provenance:
        core = source['runtime_sha256'].get('core_sha256')
        source['hosted_core_match'] = core in current_cores if current_cores and core else None
    prompt_hashes = sorted({source['recorded_prompt_template_sha256'] for source in hosted_sources
                            if source.get('recorded_prompt_template_sha256')})
    manifest = {'schema_version': 1, 'study': args.study,
                'decision_evidence_included': args.decision_evidence,
                'selection': 'Explicit operator-selected synthetic evidence; not an independent or exhaustive suite.',
                'hosted_sources': [{key: source.get(key) for key in
                    ('source_directory', 'model', 'suite', 'source_fingerprint', 'source_sha256',
                     'fixture_sha256', 'packaged_plugin_sha256', 'tool_contract_schema_sha256',
                     'model_catalog_sha256', 'selected_model_row_sha256', 'catalog_cost_per_million_usd',
                     'model_limits', 'executor_configuration', 'manifest_hosted_tool_budget',
                     'recorded_prompt_template_sha256')} for source in hosted_sources],
                'local_sources': provenance, 'recorded_prompt_hashes': prompt_hashes,
                'decision_sources': [{key: source.get(key) for key in ('source_directory', 'model',
                    'probe_sha256', 'system_sha256', 'parameters', 'case_ids')} for source in decision_sources],
                'same_recorded_prompt': (len(prompt_hashes) == 1 and len(hosted_sources) == sum(
                    source.get('recorded_prompt_template_sha256') is not None for source in hosted_sources))
                    if hosted_sources else None,
                'hosted_run_count': sum(len(source['runs']) for source in hosted_sources),
                'decision_attempt_count': sum(len(source['attempts']) for source in decision_sources),
                'limits': ['Only the selected artifact directories are represented.',
                           'Incomplete or zero-usage errors do not establish zero spend.',
                           'A checkpoint or needs_decision/needs_mapping is not a fixture-oracle success.',
                           'Optional local decision evidence includes bounded choice names only; AX refs become'
                           ' [ref], typed values and raw snapshots are excluded. An available CLICK candidate'
                           ' is not an executed click or invalid submission.',
                           'Source tool schema hashes describe the registered source definition; packaged wrapper'
                           ' and runtime hashes are retained separately. Absent historical hashes remain null.',
                           'Only fixture-matched facts are shown by value; other fact values are redacted.',
                           'Safe fact-name filtering can render an identifier as [other]; never infer that'
                           ' an alias was absent from that placeholder. Compare full key counts separately.',
                           'Local diagnostic provenance may differ from hosted core; source hashes and'
                           ' hosted_core_match prevent treating historical local runs as current-runtime parity.',
                           'H1-H8 taxonomy labels are not encoded by the source artifacts; fact_id links'
                           ' observations without inventing hypothesis assignments.',
                           'Standalone decision probes are authored payload questions, not browser-loop outcomes'
                           ' or fixture oracles. A malformed answer does not reveal the discarded raw response.',
                           'Hosted OpenClaw costs are catalog estimates. Standalone decision-probe costs'
                           ' are OpenRouter response usage.cost when present, not independent account invoices.']}
    payloads = {args.study + '-diagnostics.jsonl': ''.join(json.dumps(fact, sort_keys=True) + '\n' for fact in facts),
                args.study + '-manifest.json': json.dumps(manifest, indent=2, sort_keys=True) + '\n'}
    if not args.diagnostics_only:
        payloads[args.study + '-hosted.json'] = json.dumps({'sources': hosted_sources}, indent=2, sort_keys=True) + '\n'
        payloads[args.study + '-decisions.json'] = json.dumps({'sources': decision_sources}, indent=2, sort_keys=True) + '\n'
    for name, contents in payloads.items():
        with os.fdopen(os.open(output / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644), 'w') as stream:
            stream.write(contents)
    print(json.dumps({'local_facts': len(facts), 'hosted_runs': sum(len(source['runs']) for source in hosted_sources),
                      'decision_attempts': sum(len(source['attempts']) for source in decision_sources)}))


if __name__ == '__main__':
    main()
