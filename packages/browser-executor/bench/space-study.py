#!/usr/bin/env python3
"""Isolated local synthetic comparator; publishes only value-free fixture evidence."""
import argparse
import hashlib
import json
import os
import secrets
import subprocess
import tempfile
from pathlib import Path

import run

HERE = Path(__file__).resolve().parent
TEMP = Path('/var/folders/l9/6md8t1991gndsmclcpg0_6340000gn/T/opencode')
TRANSFORMS = {
    'cap': ('maxSteps > 24', 'maxSteps > 128'),
    'timeout': ('timeoutMs > 120_000', 'timeoutMs > 240_000'),
    'semantic_stop': ('const canStop = !semanticPlan && !request.stopAfter && !stageHasPendingValues',
                       'const canStop = (!semanticPlan || !incompleteForm) && !request.stopAfter && !stageHasPendingValues'),
    'manual_fields': ('const prepared = (applyPrepared || semantic) ? choices.filter(',
                      'const prepared = (applyPrepared || false) ? choices.filter('),
}
STOP_VARIANTS = ('aggressive', 'deterministic', 'planner', 'planner-full', 'binary', 'binary-memory')
EXTENDED_VARIANTS = (*STOP_VARIANTS, 'hybrid-extended', 'aggressive-continue')


def sha(data):
    return hashlib.sha256(data).hexdigest()


def guarded_copy(source, target, variant):
    original = source.read_text()
    config = {'variant': variant, 'cap': 128, 'timeout_ms': 240000,
              'semantic_stop_offered': variant in STOP_VARIANTS,
              'manual_fields': variant == 'planner-full'}
    derived = original
    # The copied module resolves the unmodified resolver by an explicit trusted file URL.
    replacements = [('resolver_import', "from './resolver.mjs'",
                     f"from '{(source.parent / 'resolver.mjs').as_uri()}'"),
                    *[(name, *TRANSFORMS[name]) for name in ('cap', 'timeout')],
                    *([('semantic_stop', *TRANSFORMS['semantic_stop'])] if config['semantic_stop_offered'] else []),
                    *([('manual_fields', *TRANSFORMS['manual_fields'])] if config['manual_fields'] else [])]
    for name, before, after in replacements:
        if derived.count(before) != 1:
            raise RuntimeError(f'core_anchor_mismatch_{name}')
        derived = derived.replace(before, after, 1)
    target.write_text(derived)
    return {'original_sha256': sha(original.encode()), 'derived_sha256': sha(derived.encode()),
            'config': config, 'config_sha256': sha(json.dumps(config, sort_keys=True).encode()),
            'transforms_sha256': sha(json.dumps(replacements, separators=(',', ':')).encode()),
            'anchors': [name for name, _, _ in replacements]}


def oracle_summary(oracle, trace, result, cap):
    events = oracle['events']
    mutations = [row for row in trace if row.get('event') == 'mutation']
    views = [row for row in trace if row.get('event') == 'observation']
    server = [row for row in events if row.get('server_mutation')]
    # Server mutations are click-triggered; align ordinals only if the observed
    # click count agrees (client-side TYPE/SELECT never increment server steps).
    click_indices = [index for index, row in enumerate(mutations, 1) if row['kind'] == 'click']
    aligned = len(click_indices) == len(server)
    first_error = oracle.get('first_error_step')
    success = oracle.get('success_step')
    correct = sum(1 for row in server if row.get('server_action_step', 0) < (first_error or 10**9)
                  and row.get('valid') is not False)
    if first_error is not None:
        failure = 'wrong_branch' if any(row.get('action') == 'transition:branch' and
            row.get('valid') is False for row in server) else 'overrun' if oracle.get('post_success_overrun') else 'wrong_submission_or_loop'
    elif oracle['passed']:
        failure = None
    elif result.get('status') == 'needs_decision':
        failure = 'missing_information'
    elif result.get('reason') in ('model_stop', 'terminal_observed', 'boundary_unresolved', 'submission_observed'):
        failure = 'premature_stop'
    elif result.get('reason') == 'max_steps':
        failure = 'cap_censored'
    elif result.get('reason') in ('timeout_or_cancelled', 'model_timeout'):
        failure = 'timeout_censored'
    else:
        failure = 'incomplete_other'
    return {'passed': oracle['passed'], 'failure': failure, 'mistakes': oracle['mistakes'],
            'first_error_server_step': first_error, 'success_server_step': success,
            'first_error_browser_mutation': click_indices[first_error - 1]
                if aligned and first_error and first_error <= len(click_indices) else None,
            'action_alignment': 'click_ordinal_matches_server_count' if aligned else 'unverified',
            'server_action_steps': oracle['server_action_steps'], 'correct_server_transitions_before_error': correct,
            'post_success_overrun': oracle['post_success_overrun'],
            'server_actions': [{'step': e['server_action_step'], 'action': e['action'],
                'valid': e.get('valid'), 'stage': e.get('stage')}
                for e in events if e.get('server_mutation') or e['action'] in ('success:final_receipt', 'decision:defer')],
            'browser_mutations': len(mutations), 'browser_observations': len(views),
            'duplicate_observations': sum(bool(v.get('repeated')) for v in views),
            'cap_censored': result.get('reason') == 'max_steps' and not oracle['passed'],
            'cap': cap}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--variant', choices=('baseline', 'aggressive', 'aggressive-continue', 'hybrid-extended',
        'deterministic', 'planner', 'planner-full', 'binary', 'binary-memory'), required=True)
    parser.add_argument('--backend', choices=('laya', 'kev'), default='laya')
    parser.add_argument('--task', action='append', choices=('space-01', 'space-02', 'space-03', 'space-04'))
    parser.add_argument('--repeat', type=int, default=1)
    parser.add_argument('--policy-mode', choices=('unique', 'structural'))
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--executable', type=Path, required=True)
    parser.add_argument('--connection', default='openclaw-sandbox')
    args = parser.parse_args()
    if args.repeat < 1 or args.repeat > 10 or not args.executable.is_absolute() or not os.access(args.executable, os.X_OK):
        parser.error('invalid repeat or native executable')
    if args.policy_mode and args.variant != 'deterministic':
        parser.error('--policy-mode is only valid with deterministic')
    if args.output.exists() or not args.output.parent.is_dir() or not (str(args.output.resolve()).startswith(str(TEMP.resolve()) + '/') or
        run.REPO in args.output.resolve().parents):
        parser.error('--output must be a new file in temporary storage or the repository')
    source = HERE.parent / 'core.mjs'
    relevant = [HERE / name for name in ('space-fixtures.js', 'server.js', 'run.py', 'space-runtime.mjs',
        'space-study.py', 'space-study.mjs') if (HERE / name).exists()]
    relevant += [HERE.parent / name for name in ('bridge.mjs', 'resolver.mjs', 'camofox.mjs')]
    relevant += [HERE / name for name in ('space-deterministic-policy.mjs', 'space-planner-policy.mjs')]
    if args.variant in ('binary', 'binary-memory'):
        relevant.append(HERE / 'space-binary-policy.mjs')
    before = {str(path.relative_to(run.REPO)): run.digest(path) for path in relevant}
    tasks_selected = args.task or ['space-01', 'space-02', 'space-03', 'space-04']
    env = dict(os.environ, CAMOFOX_ACCESS_KEY=secrets.token_hex(32))
    rows = []
    with tempfile.TemporaryDirectory(prefix='space-study-', dir=TEMP) as tmp:
        private = Path(tmp)
        copied = private / 'core.mjs'
        provenance = guarded_copy(source, copied, args.variant) if args.variant in EXTENDED_VARIANTS else {
            'original_sha256': run.digest(source), 'derived_sha256': run.digest(source),
            'config': {'variant': 'baseline', 'cap': 24, 'timeout_ms': 120000,
                       'semantic_stop_offered': False, 'manual_fields': False}, 'anchors': []}
        with run.temporary_fixture('podman', args.connection, run.IMAGE, env) as (ports, oracle_key):
            tasks = {t['id']: t for t in run.fetch_json(f'http://127.0.0.1:{ports["fixture"]}/api/space/tasks')}
            for task_id in tasks_selected * args.repeat:
                task = tasks[task_id]
                spec = private / 'spec.json'
                result_path = private / 'result.json'
                spec.write_text(json.dumps({'task': task, 'baseUrl': f'http://127.0.0.1:{run.PORT_INSIDE}',
                    'camofoxUrl': f'http://127.0.0.1:{ports["camofox"]}', 'backend': args.backend,
                    'executable': str(args.executable), 'variant': args.variant,
                    'corePath': str(source if args.variant == 'baseline' else copied),
                    'expectedCoreHash': provenance['original_sha256'] if args.variant == 'baseline'
                        else provenance['derived_sha256'], 'policyMode': args.policy_mode}))
                try:
                    proc = subprocess.run(['node', str(HERE / 'space-runtime.mjs'), str(spec), str(result_path)],
                        env=env, capture_output=True, text=True, timeout=270, check=False)
                    if proc.returncode or not result_path.exists():
                        rows.append({'task': task_id, 'runner_error': 'node_exit', 'exit': proc.returncode})
                    else:
                        row = json.loads(result_path.read_text())
                        run_id = row.pop('runId')
                        oracle = run.fetch_json(f'http://127.0.0.1:{ports["fixture"]}/api/space/runs/{run_id}', oracle_key)
                        result = row.pop('result', {}) or {}
                        row['result'] = {k: result.get(k) for k in ('status', 'reason', 'steps')}
                        if isinstance(result.get('problem'), dict):
                            row['result']['problem_kind'] = result['problem'].get('kind')
                            row['result']['problem_field'] = result['problem'].get('field')
                            row['result']['problem_fact_keys'] = result['problem'].get('fact_keys')
                        if isinstance(result.get('progress'), dict):
                            row['result']['progress'] = {k: result['progress'].get(k) for k in
                                ('assignments_verified', 'pages_seen', 'remaining_facts')}
                        row['oracle'] = oracle_summary(oracle, row['trajectory'], result, row.get('cap'))
                        row['native_timeout_censored'] = result.get('reason') == 'model_timeout' or any(
                            event.get('kind') == 'bridge' and event.get('reason') == 'model_timeout'
                            for event in row['trajectory'])
                        rows.append(row)
                except subprocess.TimeoutExpired:
                    rows.append({'task': task_id, 'runner_error': 'timeout_censored'})
                finally:
                    result_path.unlink(missing_ok=True)
                    spec.unlink(missing_ok=True)
                print(json.dumps({'task': task_id, 'variant': args.variant,
                    'result': rows[-1].get('result'), 'oracle': rows[-1].get('oracle', {}).get('failure'),
                    'passed': rows[-1].get('oracle', {}).get('passed')}), flush=True)
    after = {str(path.relative_to(run.REPO)): run.digest(path) for path in relevant}
    if before != after or run.digest(source) != provenance['original_sha256']:
        raise RuntimeError('source_changed_during_study')
    payload = {'provenance': {'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=run.REPO,
        text=True).strip(), 'source_sha256_before': before, 'source_sha256_after': after,
        'core_copy': provenance, 'native_sha256': run.digest(args.executable), 'hosted_calls': 0},
        'variant': args.variant, 'backend': args.backend, 'rows': rows}
    with args.output.open('x') as stream:
        json.dump(payload, stream, indent=2)
        stream.write('\n')


if __name__ == '__main__':
    main()
