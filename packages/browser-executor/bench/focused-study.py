#!/usr/bin/env python3
"""Run isolated synthetic fixture trajectories; publish only bounded aggregate records."""
import argparse
import json
import os
import secrets
import subprocess
import tempfile
from pathlib import Path

import run


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--executable', type=Path, required=True)
    parser.add_argument('--connection', default='openclaw-sandbox')
    parser.add_argument('--group', choices=('all', 'recovery'), default='all')
    args = parser.parse_args()
    if args.output.exists() or run.REPO not in args.output.resolve().parents:
        parser.error('output must be a new file inside this repository')
    if not args.executable.is_absolute() or not os.access(args.executable, os.X_OK):
        parser.error('native executable unavailable')
    key = secrets.token_hex(32)
    env = dict(os.environ, CAMOFOX_ACCESS_KEY=key)
    cases = [(id, boundary, 'semantic', 'normal', 'local-oracle-policy')
             for id in ('challenge-31', 'challenge-56', 'challenge-57', 'challenge-52', 'challenge-58',
                        'challenge-59', 'challenge-60', 'challenge-61')
             for boundary in ('conservative', 'adaptive', 'none')]
    cases += [('challenge-55', 'adaptive', 'semantic', variant, 'local-oracle-policy')
              for variant in ('no-preference', 'resume', 'resume-stale', 'resume-replay',
                              'resume-wrong-fact', 'resume-wrong-scope', 'resume-refchurn')]
    cases += [(id, 'adaptive', 'semantic', 'no-preference', 'local-oracle-policy')
              for id in ('challenge-62', 'challenge-63')]
    cases += [(id, 'adaptive', mode, 'normal', 'local-oracle-policy')
              for id in ('challenge-31', 'challenge-52') for mode in ('semantic-bound', 'procedural')]
    cases += [('challenge-38', 'adaptive', 'semantic', 'entry38', 'local-oracle-policy'),
              ('challenge-56', 'adaptive', 'semantic', 'receipt-remaining', 'local-oracle-policy')]
    cases += [(id, boundary, 'semantic', 'normal', backend)
              for id in ('challenge-56', 'challenge-57', 'challenge-60', 'challenge-61')
              for boundary in ('conservative', 'adaptive', 'none')
              for backend in ('laya', 'kev')]
    if args.group == 'recovery':
        cases = [('challenge-55', 'adaptive', 'semantic', 'reprice-recover', 'local-oracle-policy'),
                 ('challenge-55', 'adaptive', 'semantic', 'resume', 'local-oracle-policy')]
        cases += [(id, 'adaptive', 'semantic', 'normal', 'local-oracle-policy')
                  for id in ('challenge-56', 'challenge-60', 'challenge-61')]
    rows = []
    with run.temporary_fixture('podman', args.connection, run.IMAGE, env) as (ports, oracle_key):
        tasks = {task['id']: task for task in run.fetch_json(
            f'http://127.0.0.1:{ports["fixture"]}/api/challenge/tasks')}
        with tempfile.TemporaryDirectory(prefix='focused-', dir='/var/folders/l9/6md8t1991gndsmclcpg0_6340000gn/T/opencode') as tmp:
            for id, boundary, mode, variant, backend in cases:
                spec = Path(tmp) / 'input.json'
                raw = Path(tmp) / 'output.json'
                spec.write_text(json.dumps({'task': tasks[id], 'boundary': boundary, 'mode': mode,
                    'variant': variant, 'backend': backend, 'executable': str(args.executable),
                    'baseUrl': f'http://127.0.0.1:{run.PORT_INSIDE}',
                    'camofoxUrl': f'http://127.0.0.1:{ports["camofox"]}'}))
                try:
                    proc = subprocess.run(['node', str(run.HERE / 'focused-study.mjs'), str(spec), str(raw)],
                        env=env, capture_output=True, text=True, timeout=155, check=False)
                    if proc.returncode or not raw.exists():
                        rows.append({'task': id, 'boundary': boundary, 'mode': mode, 'variant': variant,
                                     'backend': backend, 'error': 'node_exit_or_timeout', 'exit': proc.returncode})
                        continue
                    data = json.loads(raw.read_text())
                    oracle = run.fetch_json(f'http://127.0.0.1:{ports["fixture"]}/api/challenge/runs/{data.pop("runId")}', oracle_key)
                    events = oracle['events']
                    data['oracle'] = {'passed': oracle['passed'], 'mistakes': oracle['mistakes'],
                        'final_submits': sum(event.get('action') == 'submit:finish' and event.get('valid') is True for event in events),
                        'invalid_submits': sum(event.get('action', '').startswith('submit:') and event.get('valid') is False for event in events),
                        'overrun': any(event.get('action') == 'restart_after_receipt' for event in events),
                        'advances': sum(event.get('action') == 'submit:advance' and event.get('valid') is True for event in events)}
                    rows.append(data)
                except subprocess.TimeoutExpired:
                    rows.append({'task': id, 'boundary': boundary, 'mode': mode, 'variant': variant,
                                 'backend': backend, 'error': 'node_timeout'})
                finally:
                    spec.unlink(missing_ok=True)
                    raw.unlink(missing_ok=True)
                print(json.dumps(rows[-1], separators=(',', ':')), flush=True)
    args.output.write_text(json.dumps({'provenance': {'head': subprocess.check_output(
        ['git', 'rev-parse', 'HEAD'], cwd=run.REPO, text=True).strip(),
        'sha256': {name: run.digest(run.HERE / name) for name in ('challenge.js', 'server.js', 'focused-study.mjs', 'focused-study.py')},
        'core_sha256': run.digest(run.HERE.parent / 'core.mjs'),
        'resolver_sha256': run.digest(run.HERE.parent / 'resolver.mjs'),
        'executable_sha256': run.digest(args.executable), 'hosted_calls': 0, 'group': args.group}, 'rows': rows}, indent=2) + '\n')


if __name__ == '__main__':
    main()
