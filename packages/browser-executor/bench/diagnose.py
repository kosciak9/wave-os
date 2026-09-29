#!/usr/bin/env python3
"""Disposable live Camofox diagnostic; outputs contain synthetic fixture data only."""
import argparse
import json
import os
import re
import secrets
import subprocess
import sys
import uuid
from pathlib import Path

import run


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--executable', type=Path)
    parser.add_argument('--backend', choices=('oracle', 'laya', 'kev'), action='append', required=True)
    parser.add_argument('--task', action='append', default=[])
    parser.add_argument('--challenge', action='store_true', help='Use separate authored challenge tasks; frozen 30 unchanged')
    parser.add_argument('--horizon', action='append', type=int, choices=(3, 8, 24))
    parser.add_argument('--success-mode', action='append', choices=('none', 'whole'))
    parser.add_argument('--candidate-mode', choices=('legacy', 'strictBindings'), default='legacy')
    parser.add_argument('--apply-prepared', action='store_true')
    parser.add_argument('--representation', choices=('full', 'current'), default='full')
    parser.add_argument('--history', type=int, choices=(0, 2), default=2)
    parser.add_argument('--model-goal', choices=('original', 'concise'), default='original')
    parser.add_argument('--stop-policy', choices=('success', 'checkpoint'), default='success')
    parser.add_argument('--success-contract', choices=('strong', 'weak-completed', 'scope-review'), default='strong')
    parser.add_argument('--binding-override', choices=('service:Shipping speed',),
                        help='Fixture-only negative contract: bind challenge-31 service to a nonexistent label')
    parser.add_argument('--semantic-binding', choices=('qualified', 'unqualified', 'wrong-context', 'future'))
    parser.add_argument('--preserve-variant', choices=('expected', 'qualified', 'wrong-default', 'conflict', 'changed', 'duplicate', 'hidden', 'future', 'unsafe-caller'))
    parser.add_argument('--execution-scope', choices=('garden', 'wrong', 'wrong-title'))
    parser.add_argument('--stop-after', choices=('long-submit', 'garden-submit', 'garden-advance', 'unqualified-inquiry'))
    parser.add_argument('--connection', default='openclaw-sandbox')
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() or run.REPO == output or run.REPO in output.parents:
        parser.error('output must be new and outside the public repository')
    if set(args.backend) - {'oracle'} and (not args.executable or not args.executable.is_absolute() or not os.access(args.executable, os.X_OK)):
        parser.error('models require an absolute executable')
    if args.horizon and len(args.horizon) != len(set(args.horizon)) or args.success_mode and len(args.success_mode) != len(set(args.success_mode)):
        parser.error('duplicate horizon or success mode')
    if args.apply_prepared and args.candidate_mode != 'strictBindings':
        parser.error('--apply-prepared requires --candidate-mode strictBindings')
    cases = ([('none', 3), ('whole', 3), ('whole', 8), ('whole', 24)]
             if not args.horizon and not args.success_mode else
             [(mode, horizon) for mode in (args.success_mode or ['whole'])
              for horizon in (args.horizon or [3, 8, 24])])
    output.mkdir(parents=True, mode=0o700)
    key = secrets.token_hex(32)
    env = dict(os.environ, CAMOFOX_ACCESS_KEY=key)
    with run.temporary_fixture('podman', args.connection, run.IMAGE, env) as (ports, oracle_key):
        frozen = run.fetch_json(f'http://127.0.0.1:{ports["fixture"]}/api/tasks')
        if len(frozen) != 30:
            raise RuntimeError('fixture manifest changed')
        tasks = (run.fetch_json(f'http://127.0.0.1:{ports["fixture"]}/api/challenge/tasks')
                 if args.challenge else frozen)
        selected = args.task or ([t['id'] for t in tasks] if args.challenge else
            ['search-01', 'booking-02', 'booking-14', 'forms-03', 'long-07', 'cart-05', 'spa-06', 'login-04'])
        if len(selected) != len(set(selected)) or set(selected) - {t['id'] for t in tasks}:
            parser.error('unknown or duplicate task')
        if args.success_contract == 'weak-completed' and (not args.challenge or selected != ['challenge-31'] or
                                                           any(mode != 'whole' for mode, _ in cases)):
            parser.error('weak-completed is only for challenge-31 with whole-workflow success')
        if args.success_contract == 'scope-review' and (not args.challenge or selected != ['challenge-44'] or
                                                         any(mode != 'whole' for mode, _ in cases)):
            parser.error('scope-review is only for challenge-44 with whole-workflow success')
        if args.binding_override and (not args.challenge or selected != ['challenge-31'] or args.backend != ['oracle'] or
                                      args.candidate_mode != 'strictBindings' or not args.apply_prepared):
            parser.error('binding override is only for prepared strict oracle challenge-31')
        if args.semantic_binding and (not args.challenge or
                                      args.semantic_binding == 'future' and selected != ['challenge-31'] or
                                      args.semantic_binding != 'future' and selected not in (['challenge-34'], ['challenge-35'])):
            parser.error('semantic binding requires its challenge fixture')
        preserve_tasks = {'expected': 'forms-03', 'qualified': 'forms-03', 'wrong-default': 'forms-03', 'conflict': 'forms-03',
                          'changed': 'challenge-36', 'duplicate': 'challenge-32', 'hidden': 'challenge-32',
                          'future': 'challenge-31', 'unsafe-caller': 'challenge-37'}
        if args.preserve_variant and (selected != [preserve_tasks[args.preserve_variant]] or
                                      args.challenge != (args.preserve_variant not in ('expected', 'qualified', 'wrong-default', 'conflict'))):
            parser.error('preserve variant requires its fixture task family')
        if args.execution_scope and (not args.challenge or selected not in
                                     (['challenge-40'], ['challenge-41'], ['challenge-42'], ['challenge-43'], ['challenge-44'])):
            parser.error('scope variant requires a booking challenge')
        stop_tasks = {'long-submit': 'long-07', 'garden-submit': 'challenge-40',
                      'garden-advance': 'challenge-44', 'unqualified-inquiry': 'challenge-32'}
        if args.stop_after and (selected != [stop_tasks[args.stop_after]] or
                                args.challenge != (args.stop_after != 'long-submit') or
                                any(mode != 'none' for mode, _ in cases)):
            parser.error('stop-after requires its fixture without a success predicate')
        wrapper = args.executable.read_text() if args.executable else ''
        runtime_path = re.search(r'/nix/store/[a-z0-9]+-runtime\.py', wrapper)
        runtime = Path(runtime_path.group()) if runtime_path else None
        (output / 'manifest.json').write_text(json.dumps({
            'tasks_sha256': run.digest(run.HERE / 'tasks.js'),
            'server_sha256': run.digest(run.HERE / 'server.js'),
            'challenge_sha256': run.digest(run.HERE / 'challenge.js'),
            'core_sha256': run.digest(run.HERE.parent / 'core.mjs'),
            'bridge_sha256': run.digest(run.HERE.parent / 'bridge.mjs'),
            'camofox_sha256': run.digest(run.HERE.parent / 'camofox.mjs'),
            'diagnostic_sha256': {name: run.digest(run.HERE / name) for name in
                                  ('diagnose.py', 'diagnose.mjs', 'diagnose-policy.mjs', 'run.py')},
            'model_executable_sha256': run.digest(args.executable) if args.executable else None,
            'packaged_runtime_sha256': run.digest(runtime) if runtime and runtime.is_file() else None,
            'source_runtime_sha256': run.digest(run.HERE.parent.parent / 'browser-decision/runtime.py'),
            'backends': args.backend, 'tasks': selected, 'authored_challenge': args.challenge,
            'cases': [{'successMode': mode, 'maxSteps': horizon} for mode, horizon in cases],
            'configuration': {'threshold': 0.5, 'margin': 0.05, 'timeoutMs': 120000,
                              'modelCallMs': 20000, 'modelHistory': args.history,
                              'candidateMode': args.candidate_mode, 'applyPrepared': args.apply_prepared,
                              'representation': args.representation, 'modelGoal': args.model_goal,
                              'stopPolicy': args.stop_policy,
                              'successContract': args.success_contract,
                              'bindingOverride': args.binding_override,
                              'semanticBinding': args.semantic_binding,
                              'preserveVariant': args.preserve_variant,
                              'executionScope': args.execution_scope,
                              'stopAfter': args.stop_after,
                              'formsVariables': 'public-target-as-location'},
            'image': run.IMAGE, 'source_head': subprocess.check_output(
                ['git', 'rev-parse', 'HEAD'], cwd=run.REPO, text=True).strip(),
        }, indent=2) + '\n')
        for backend in args.backend:
            for task in (t for t in tasks if t['id'] in selected):
                for mode, horizon in cases:
                    name = f'{backend}-{task["id"]}-{mode}-{horizon}-{uuid.uuid4().hex[:8]}'
                    spec = output / (name + '.input.json')
                    artifact = output / (name + '.json')
                    spec.write_text(json.dumps({'task': task, 'baseUrl': f'http://127.0.0.1:{run.PORT_INSIDE}',
                        'camofoxUrl': f'http://127.0.0.1:{ports["camofox"]}', 'backend': backend,
                        'horizon': horizon, 'successMode': mode, 'executable': str(args.executable or ''),
                        'candidateMode': args.candidate_mode, 'applyPrepared': args.apply_prepared,
                        'representation': args.representation, 'history': args.history,
                        'modelGoalMode': args.model_goal, 'stopPolicy': args.stop_policy,
                        'successContract': args.success_contract, 'bindingOverride': args.binding_override,
                        'semanticBinding': args.semantic_binding, 'preserveVariant': args.preserve_variant,
                        'executionScope': args.execution_scope, 'stopAfter': args.stop_after}))
                    try:
                        proc = subprocess.run(['node', str(run.HERE / 'diagnose.mjs'), str(spec), str(artifact)],
                            env={'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'TMPDIR': str(output),
                                 'CAMOFOX_ACCESS_KEY': key}, capture_output=True, text=True, timeout=160, check=False)
                        if proc.returncode or not artifact.exists():
                            print(json.dumps({'task': task['id'], 'backend': backend,
                                'failure': 'node_exit_or_timeout', 'exit': proc.returncode}), flush=True)
                        else:
                            record = json.loads(artifact.read_text())
                            try:
                                oracle_path = 'api/challenge/runs' if args.challenge else 'api/runs'
                                oracle = run.fetch_json(f'http://127.0.0.1:{ports["fixture"]}/{oracle_path}/{record["runId"]}', oracle_key)
                                outcome = {'passed': oracle['passed'], 'mistakes': oracle['mistakes'],
                                    'events': oracle['events']}
                            except OSError:
                                outcome = {'unavailable': True}
                            record['oracle'] = outcome
                            record['artifact_bytes_before_oracle'] = artifact.stat().st_size
                            for event in record['trace']:
                                if 'decision' not in event:
                                    continue
                                decision = event['decision']
                                expected_choice = decision['diagnostic']['selected']
                                decision['model_disagreed'] = (
                                    record['backend'] != 'oracle' and decision.get('choice') != expected_choice
                                ) if expected_choice and 'passed' in outcome and decision.get('choice') else None
                            artifact.write_text(json.dumps(record, indent=2) + '\n')
                            print(json.dumps({'artifact': artifact.name, 'task': task['id'], 'backend': backend,
                                'horizon': horizon, 'mode': mode, 'passed': outcome.get('passed'),
                                'reason': (record.get('result') or {}).get('reason'),
                                'decisions': record['model_calls'], 'actions': record['local_actions'],
                                'snapshots_hidden': record['hidden_snapshots']}), flush=True)
                    except subprocess.TimeoutExpired:
                        print(json.dumps({'task': task['id'], 'backend': backend, 'failure': 'node_timeout'}), flush=True)
                    finally:
                        spec.unlink(missing_ok=True)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, RuntimeError, OSError) as error:
        print('diagnostic failed: ' + type(error).__name__, file=sys.stderr)
        sys.exit(2)
