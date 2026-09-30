#!/usr/bin/env python3
"""Local-only live Camofox judgment comparator on disposable synthetic runs."""

import argparse
import hashlib
import json
import os
import re
import secrets
import select
import subprocess
import tempfile
import time
from pathlib import Path

import run
from importlib.util import module_from_spec, spec_from_file_location

HERE = Path(__file__).resolve().parent
TEMP = Path('/var/folders/l9/6md8t1991gndsmclcpg0_6340000gn/T/opencode')


def module(name):
    spec = spec_from_file_location(name.replace('-', '_'), HERE / name)
    obj = module_from_spec(spec)
    spec.loader.exec_module(obj)
    return obj


def exchange(proc, worker, limit=48):
    counts = {'pre': 0, 'post': 0}
    deadline = time.monotonic() + 245
    while time.monotonic() < deadline:
        if not select.select([proc.stdout], [], [], min(10, max(0, deadline - time.monotonic())))[0]:
            if proc.poll() is not None:
                break
            continue
        raw = proc.stdout.readline(65537)
        if len(raw) > 65536 or not raw.endswith('\n'):
            raise RuntimeError('invalid_node_message')
        item = json.loads(raw)
        if item.get('type') == 'result':
            proc.stdin.close()
            proc.wait(timeout=3)
            if proc.returncode:
                raise RuntimeError('node_exit')
            return item['record']
        if item.get('type') != 'ask':
            raise RuntimeError('invalid_node_message')
        question = item.get('question')
        evidence = item.get('evidence')
        if not isinstance(question, str) or not isinstance(evidence, dict) or len(json.dumps(evidence)) > 8000:
            answer = {'error': 'evidence_limit'}
        else:
            phase = 'post' if 'after' in evidence else 'pre'
            counts[phase] += 1
            if counts[phase] > limit:
                answer = {'error': 'judgment_call_limit'}
            else:
                try:
                    answer = worker.ask(question, evidence)
                except (ValueError, KeyError, TimeoutError, BrokenPipeError, RuntimeError):
                    answer = {'error': 'native_worker_failed'}
        proc.stdin.write(json.dumps(answer, separators=(',', ':')) + '\n')
        proc.stdin.flush()
    raise TimeoutError('node_timeout_or_exit')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--executable', type=Path)
    parser.add_argument('--backend', choices=('laya', 'kev', 'kev-browser'), default='laya')
    parser.add_argument('--mode', choices=('pre', 'post', 'both'), action='append')
    parser.add_argument('--task', choices=('space-01', 'space-02', 'space-04'), action='append')
    parser.add_argument('--negative', action='store_true', help='Isolated post-only wrong-branch/restart interventions')
    parser.add_argument('--negative-only', choices=('wrong_branch', 'restart'))
    parser.add_argument('--collect-result', type=Path, action='append',
                        help='Combine previously measured local runs without new model calls')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--connection', default='openclaw-sandbox')
    args = parser.parse_args()
    if args.output.exists() or not args.output.parent.is_dir() or not (
        str(args.output.resolve()).startswith(str(TEMP.resolve()) + '/') or
        run.REPO in args.output.resolve().parents):
        parser.error('output must be a new file in repository or approved temporary directory')
    if args.collect_result:
        if args.executable or args.negative or args.negative_only or args.mode or args.task:
            parser.error('collection cannot execute browser runs')
        records = []
        for path in args.collect_result:
            if TEMP.resolve() not in path.resolve().parents:
                parser.error('collection only accepts approved temporary run outputs')
            item = json.loads(path.read_text())
            if item.get('provenance', {}).get('hosted_calls') != 0 or not isinstance(item.get('rows'), list):
                parser.error('invalid local result provenance')
            for row in item['rows']:
                row['result'] = {k: row.get('result', {}).get(k) for k in ('status', 'reason', 'steps')}
                if row.get('semantic_stop', {}).get('kind') == 'post':
                    row['mutations_after_semantic_stop'] = 0 if row.get('rows', [{}])[-1].get('kind') == 'post' else None
                for event in row.get('rows', []):
                    for side in ('before', 'after'):
                        if side in event:
                            event[side]['text'] = '\n'.join(line for line in event[side]['text'].splitlines()
                                if not re.search(r'\s- /url:', line))
            if re.search(r'https?://|/space/run/|\[e\d+\]|\b(?:Bearer|api[_-]?key)\s*[:=]',
                         json.dumps(item['rows']), re.I):
                parser.error('unsafe run payload: refusing publication')
            records.append({'provenance': item['provenance'], 'backend': item['backend'], 'rows': item['rows']})
        with args.output.open('x') as stream:
            json.dump({'schema_version': 1, 'capture_type': 'measured_local_synthetic_runs',
                'source_files': [p.name for p in args.collect_result], 'captures': records,
                'notes': 'Independent runs; each has its own source hash and oracle verdict. No hosted calls.'},
                stream, indent=2)
            stream.write('\n')
        return
    if not args.executable or not args.executable.is_absolute() or not os.access(args.executable, os.X_OK):
        parser.error('native executable must be absolute and executable')
    modes = args.mode or ['pre', 'post', 'both']
    tasks_selected = args.task or ['space-01', 'space-02', 'space-04']
    source = HERE.parent / 'core.mjs'
    study = module('space-study.py')
    engine = module('judgment-engine.py')
    relevant = [source, HERE / 'space-fixtures.js', HERE / 'server.js', HERE / 'run.py',
                HERE / 'space-study.py', HERE / 'judgment-live.mjs', HERE / 'judgment-live.py',
                HERE / 'judgment-engine.py', HERE / 'judgment-worker.py',
                HERE.parent / 'bridge.mjs', HERE.parent / 'resolver.mjs', HERE.parent / 'camofox.mjs']
    before = {str(p.relative_to(run.REPO)): run.digest(p) for p in relevant}
    env = dict(os.environ, CAMOFOX_ACCESS_KEY=secrets.token_hex(32))
    rows = []
    with tempfile.TemporaryDirectory(prefix='judgment-live-', dir=TEMP) as tmp:
        private = Path(tmp)
        copy = private / 'core.mjs'
        provenance = study.guarded_copy(source, copy, 'aggressive-continue')
        with engine.NativeWorker(args.executable, args.backend) as worker:
            with run.temporary_fixture('podman', args.connection, run.IMAGE, env) as (ports, oracle_key):
                tasks = {t['id']: t for t in run.fetch_json(f'http://127.0.0.1:{ports["fixture"]}/api/space/tasks')}
                configurations = [(t, m, 'none') for m in modes for t in tasks_selected]
                if args.negative_only:
                    configurations = [('space-02' if args.negative_only == 'wrong_branch' else 'space-04',
                                       'post', args.negative_only)]
                if args.negative:
                    configurations.extend([('space-02', 'post', 'wrong_branch'),
                                           ('space-04', 'post', 'restart')])
                for task_id, mode, intervention in configurations:
                    spec = private / 'spec.json'
                    spec.write_text(json.dumps({'task': tasks[task_id], 'baseUrl': f'http://127.0.0.1:{run.PORT_INSIDE}',
                        'camofoxUrl': f'http://127.0.0.1:{ports["camofox"]}', 'corePath': str(copy),
                        'coreHash': provenance['derived_sha256'], 'mode': mode, 'intervention': intervention,
                        'backend': args.backend}))
                    proc = subprocess.Popen(['node', str(HERE / 'judgment-live.mjs'), str(spec)], env=env,
                                            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                            stderr=subprocess.DEVNULL, text=True, bufsize=1)
                    try:
                        row = exchange(proc, worker)
                        oracle = run.fetch_json(f'http://127.0.0.1:{ports["fixture"]}/api/space/runs/{row.pop("runId")}', oracle_key)
                        row['oracle'] = study.oracle_summary(oracle, [], row.get('result') or {}, 128)
                        # Only fixture verdicts, never oracle events/values, accompany public traces.
                        row['oracle'] = {k: row['oracle'][k] for k in ('passed', 'failure', 'mistakes',
                            'first_error_server_step', 'success_server_step', 'post_success_overrun', 'server_action_steps')}
                    except (TimeoutError, subprocess.TimeoutExpired, RuntimeError, ValueError, KeyError, BrokenPipeError) as error:
                        row = {'task': task_id, 'mode': mode, 'intervention': intervention,
                               'runner_error': type(error).__name__}
                    finally:
                        if proc.poll() is None:
                            proc.kill()
                        proc.wait()
                        spec.unlink(missing_ok=True)
                    rows.append(row)
                    print(json.dumps({'task': task_id, 'mode': mode, 'intervention': intervention,
                        'result': row.get('result', {}).get('reason'), 'semantic_stop': row.get('semantic_stop'),
                        'passed': row.get('oracle', {}).get('passed'), 'runner_error': row.get('runner_error')}), flush=True)
    after = {str(p.relative_to(run.REPO)): run.digest(p) for p in relevant}
    if before != after or run.digest(source) != provenance['original_sha256']:
        raise RuntimeError('source_changed_during_study')
    with args.output.open('x') as stream:
        json.dump({'provenance': {'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'],
            cwd=run.REPO, text=True).strip(), 'source_sha256_before': before,
            'source_sha256_after': after, 'core_copy': provenance,
            'native_sha256': run.digest(args.executable), 'hosted_calls': 0},
            'backend': args.backend, 'rows': rows}, stream, indent=2)
        stream.write('\n')


if __name__ == '__main__':
    main()
