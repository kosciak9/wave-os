#!/usr/bin/env python3
"""Disposable, synthetic-only OpenClaw/Camofox benchmark runner.

Never points at a live browser or account store. Run from `devenv shell --`.
Output contains metrics only; no transcripts, tokens, oracle key or host paths.
"""

import argparse
import hashlib
import hmac
import json
import os
import re
import secrets
import signal
import socket
import sqlite3
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from contextlib import contextmanager
from pathlib import Path


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
IMAGE = 'localhost/wave-os/camofox-browser:1.15.0'
PORT_INSIDE = 38891
TOOLS = ('read', 'web_search', 'web_fetch', 'camofox_create_tab', 'camofox_snapshot',
         'camofox_click', 'camofox_type', 'camofox_navigate', 'camofox_scroll',
         'camofox_close_tab', 'camofox_list_tabs')
EXTRA_TOOLS = {'camofox_select', 'browser_execute'}
AUTH_ENV = {'OPENAI_API_KEY', 'OPENROUTER_API_KEY', 'OPENCODE_API_KEY'}
PROVIDER_ENV = {'openai': 'OPENAI_API_KEY', 'openrouter': 'OPENROUTER_API_KEY',
                'opencode-go': 'OPENCODE_API_KEY'}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def pick_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def fetch_json(url, key=None, timeout=5):
    headers = {'x-fixture-key': key} if key else {}
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=timeout) as response:
        return json.load(response)


def redact(text):
    """Defense in depth for optional synthetic trace summaries; never save raw blobs."""
    if not isinstance(text, str):
        return ''
    text = re.sub(r'(?i)(authorization\s*[:=]\s*bearer\s+)\S+', r'\1[REDACTED]', text)
    text = re.sub(r'https?://[^\s"<>]+', '[URL]', text)
    text = re.sub(r'(?i)(password|passphrase|token|api[_-]?key)(["\s:=]+)[^\s,"}]+',
                  r'\1\2[REDACTED]', text)
    return text[:600]


def oracle_actions(oracle, target):
    events = oracle['events']
    invalid = sum(event.get('valid') is False for event in events)
    wrong_views = sum(event.get('action') in ('view:detail', 'view:modal')
                      and event.get('item') not in (None, target) for event in events)
    return {'success': bool(oracle['passed']), 'mistakes': oracle['mistakes'],
            'wrong_actions': invalid + wrong_views,
            'oracle_actions': max(0, len(events) - 1)}


def transcript_metrics(db, session_id):
    """Only aggregate own session's transcript; do not return message bodies."""
    if not session_id or not db.exists():
        return {}
    conn = sqlite3.connect('file:' + str(db) + '?mode=ro', uri=True, timeout=1)
    try:
        events = [json.loads(row[0]) for row in conn.execute(
            'SELECT event_json FROM transcript_events WHERE session_id=? ORDER BY seq', (session_id,))]
    finally:
        conn.close()
    tokens, actions, snapshots, image_blocks, image_chars = [], 0, 0, 0, 0
    pending = {}
    for event in events:
        if event.get('type') != 'message':
            continue
        msg = event.get('message', {})
        if msg.get('role') == 'assistant':
            usage = msg.get('usage') or {}
            if usage:
                tokens.append(usage)
            for block in msg.get('content', []):
                if not isinstance(block, dict) or block.get('type') != 'toolCall':
                    continue
                args = block.get('arguments') or {}
                name = args.get('id', 'tool_call') if block.get('name') == 'tool_call' and isinstance(args, dict) else block.get('name', '')
                name = name.split(':')[-1] if isinstance(name, str) else ''
                if block.get('id'):
                    pending[block['id']] = name
                if name.startswith('camofox_'):
                    actions += 1
        elif msg.get('role') == 'toolResult':
            name = pending.pop(msg.get('toolCallId'), msg.get('toolName'))
            if not isinstance(name, str) or not name.endswith('camofox_snapshot'):
                continue
            snapshots += 1
            for block in msg.get('content', []):
                if not isinstance(block, dict):
                    continue
                if block.get('type') == 'image':
                    image_blocks += 1
                    image_chars += len(block.get('data', ''))
                if block.get('type') != 'text':
                    continue
                try:
                    payload = json.loads(block.get('text', ''))
                    for part in payload.get('result', {}).get('content', []):
                        if isinstance(part, dict) and part.get('type') == 'image':
                            image_blocks += 1
                            image_chars += len(part.get('data', ''))
                except (ValueError, AttributeError, TypeError):
                    pass
    prompts = [entry.get('contextUsage', {}).get('promptTokens') for entry in tokens]
    return {'turns_observed': len(tokens),
            'model_input_plus_cache': sum((u.get('input') or 0) + (u.get('cacheRead') or 0) for u in tokens),
            'prompt_peak_tokens': max((p or 0 for p in prompts), default=0),
            'camofox_actions': actions, 'snapshots_exposed': snapshots,
            'image_blocks': image_blocks, 'image_encoded_chars': image_chars}


def synthetic_trace(db, session_id):
    """Optional compact tool-only evidence: omit typed values, images, URLs and all user/system text."""
    if not db.is_file() or not session_id:
        return []
    conn = sqlite3.connect('file:' + str(db) + '?mode=ro', uri=True, timeout=1)
    try:
        events = [json.loads(row[0]) for row in conn.execute(
            'SELECT event_json FROM transcript_events WHERE session_id=? ORDER BY seq', (session_id,))]
    finally:
        conn.close()
    result = []
    pending = {}
    for event in events:
        if event.get('type') != 'message':
            continue
        msg = event.get('message', {})
        if msg.get('role') == 'assistant':
            for block in msg.get('content', []):
                if not isinstance(block, dict) or block.get('type') != 'toolCall':
                    continue
                outer = block.get('arguments') or {}
                name = outer.get('id', '') if block.get('name') == 'tool_call' and isinstance(outer, dict) else block.get('name', '')
                name = name.split(':')[-1] if isinstance(name, str) else ''
                if block.get('id'):
                    pending[block['id']] = name
                if name not in TOOLS and name not in EXTRA_TOOLS:
                    continue
                arguments = outer.get('args', {}) if block.get('name') == 'tool_call' else outer
                if not isinstance(arguments, dict):
                    arguments = {}
                result.append({'tool': name, 'args': {key: arguments[key] for key in
                    ('ref', 'selector', 'offset', 'direction', 'amount', 'option') if key in arguments
                    and isinstance(arguments[key], (int, float, str))}, 'at': msg.get('timestamp')})
        elif msg.get('role') == 'toolResult':
            name = pending.pop(msg.get('toolCallId'), msg.get('toolName'))
            if msg.get('isError'):
                result.append({'tool_error': True, 'at': msg.get('timestamp')})
            if name != 'camofox_snapshot':
                continue
            for part in msg.get('content', []):
                if not isinstance(part, dict) or part.get('type') != 'text':
                    continue
                try:
                    payload = json.loads(part.get('text', ''))
                    contents = payload.get('result', {}).get('content', [])
                    inner = json.loads(contents[0]['text']) if contents else payload
                    if not re.fullmatch(r'http://127\.0\.0\.1:%d/run/[\w-]+/[a-z]+-\d\d/[a-z]+' % PORT_INSIDE,
                                        inner.get('url', '')):
                        continue
                    result.append({'snapshot_excerpt': redact(inner.get('snapshot', '')),
                                   'at': msg.get('timestamp')})
                except (ValueError, IndexError, KeyError, TypeError, AttributeError):
                    pass
    return result


def hosted_trace(db, session_id):
    """Value-free tool and usage timeline from the isolated synthetic session."""
    if not db.is_file() or not session_id:
        return []
    conn = sqlite3.connect('file:' + str(db) + '?mode=ro', uri=True, timeout=1)
    try:
        events = [json.loads(row[0]) for row in conn.execute(
            'SELECT event_json FROM transcript_events WHERE session_id=? ORDER BY seq', (session_id,))]
    finally:
        conn.close()
    timeline, pending = [], {}
    for event in events:
        if event.get('type') != 'message':
            continue
        msg = event.get('message', {})
        if msg.get('role') == 'assistant':
            usage = msg.get('usage') or {}
            record = {'role': 'assistant', 'at': msg.get('timestamp'), 'stop': msg.get('stopReason'),
                      'usage': {key: usage.get(key) for key in ('input', 'cacheRead', 'output')},
                      'prompt_tokens': (usage.get('contextUsage') or {}).get('promptTokens'), 'calls': []}
            for block in msg.get('content', []):
                if not isinstance(block, dict):
                    continue
                if block.get('type') != 'toolCall':
                    continue
                outer = block.get('arguments') or {}
                name = outer.get('id', '') if block.get('name') == 'tool_call' and isinstance(outer, dict) else block.get('name', '')
                name = name.split(':')[-1] if isinstance(name, str) else ''
                raw = outer.get('args', {}) if block.get('name') == 'tool_call' else outer
                if isinstance(raw, str):
                    try:
                        raw = json.loads(raw)
                    except ValueError:
                        raw = {}
                arguments = raw if isinstance(raw, dict) else {}
                pending[block.get('id')] = name
                detail = {'tool': name}
                if name == 'browser_execute':
                    detail['request_bytes'] = len(json.dumps(arguments).encode())
                    detail['goal_bytes'] = len(str(arguments.get('goal', '')).encode())
                    detail['model_goal_bytes'] = len(str(arguments.get('modelGoal', '')).encode())
                    variables = arguments.get('variables')
                    bindings = arguments.get('bindings')
                    public_names = {'target', 'location', 'service', 'date', 'summary', 'destination',
                                    'arrival', 'travel', 'reference', 'quantity', 'party', 'time',
                                    'guest', 'seat', 'meal', 'fare', 'name', 'email', 'search', 'venue',
                                    'item', 'entry', 'label', 'notes', 'departure', 'return'}
                    detail['variable_names'] = [key if key in public_names else '[other]'
                                                for key in list(variables)[:32]] if isinstance(variables, dict) else []
                    detail['binding_count'] = len(bindings) if isinstance(bindings, dict) else 0
                    success = arguments.get('success')
                    detail['success_criteria'] = sorted(key for key in success if key in
                        ('urlPath', 'textIncludes', 'allText', 'fieldValues')) if isinstance(success, dict) else []
                elif name.startswith('camofox_'):
                    detail['argument_names'] = sorted(key for key in arguments if key in
                        ('ref', 'option', 'offset', 'direction', 'amount', 'tabId', 'url', 'text', 'value'))
                record['calls'].append(detail)
            if usage or record['calls']:
                timeline.append(record)
        elif msg.get('role') == 'toolResult':
            name = pending.pop(msg.get('toolCallId'), msg.get('toolName'))
            if name not in ('browser_execute', 'camofox_snapshot'):
                continue
            texts = [part.get('text', '') for part in msg.get('content', [])
                     if isinstance(part, dict) and part.get('type') == 'text']
            raw = '\n'.join(texts)
            record = {'role': 'result', 'tool': name, 'at': msg.get('timestamp'),
                      'error': bool(msg.get('isError')), 'output_bytes': len(raw.encode())}
            if name == 'browser_execute':
                try:
                    payload = json.loads(raw)
                    content = payload.get('result', {}).get('content', [])
                    body = json.loads(content[0]['text']) if content else payload
                    if isinstance(body, dict):
                        record['result'] = {key: body[key] for key in ('status', 'reason', 'steps')
                                            if isinstance(body.get(key), int) or isinstance(body.get(key), str)
                                            and re.fullmatch(r'[a-z_]{1,48}', body[key])}
                except (ValueError, TypeError, KeyError, IndexError, AttributeError):
                    record['result_parse_error'] = True
            timeline.append(record)
    return timeline


def private_access_profile(path, remaining_seconds):
    path = Path(path)
    status = path.lstat()
    if not path.is_file() or path.is_symlink() or status.st_uid != os.getuid() or status.st_mode & 0o077:
        raise ValueError('auth profile must be an owned regular file with no group/other access')
    credential = json.loads(path.read_text())
    if set(credential) != {'provider', 'access', 'expires', 'accountId'} or credential['provider'] != 'openai':
        raise ValueError('only access-only OpenAI OAuth profiles are supported (no refresh token)')
    if not isinstance(credential['access'], str) or not credential['access'] or not isinstance(credential['accountId'], str):
        raise ValueError('invalid access-only OAuth profile')
    if not isinstance(credential['expires'], (int, float)) or credential['expires'] < (time.time() + remaining_seconds + 90) * 1000:
        raise ValueError('OAuth access expires before the bounded task; no refresh is attempted')
    return {'provider': 'openai', 'type': 'oauth', 'access': credential['access'],
            'refresh': '', 'expires': int(credential['expires']), 'accountId': credential['accountId']}


def erase_db(db):
    for suffix in ('', '-wal', '-shm'):
        (db.parent / (db.name + suffix)).unlink(missing_ok=True)


def install_access_profile(openclaw, config_path, state, cwd, env, profile, model):
    db = state / 'agents/main/agent/openclaw-agent.sqlite'
    # Pinned 2026.9.4 initializes its SQLite schema on a no-auth agent exec.
    subprocess.run([openclaw, 'agent', 'exec', '--config', str(config_path), '--state-dir', str(state),
                    '--cwd', str(cwd), '--model', model, '--no-auth-env-only',
                    '--timeout', '30', '--json', 'Initialize isolated synthetic state.'],
                   env=env, capture_output=True, text=True, timeout=50, check=False)
    if not db.is_file():
        raise RuntimeError('isolated OpenClaw credential DB initialization failed')
    conn = sqlite3.connect(db)
    try:
        conn.execute('INSERT OR REPLACE INTO auth_profile_store (store_key,store_json,updated_at) VALUES (?,?,?)',
                     ('primary', json.dumps({'version': 1, 'profiles': {'openai:default': profile}}), int(time.time() * 1000)))
        conn.commit()
    finally:
        conn.close()
    db.chmod(0o600)
    return db


def model_config(config_file, model):
    """Select only public catalog rows; never copy provider keys or channel settings."""
    source = json.loads(Path(config_file).read_text())
    if set(source) != {'models'} or not isinstance(source['models'], dict):
        raise ValueError('--config must contain only a public models catalog')
    provider, sep, model_id = model.partition('/')
    if not sep or provider not in PROVIDER_ENV or not model_id:
        raise ValueError('model must be provider/model-id')
    try:
        definitions = source['models']['providers'][provider]['models']
    except (KeyError, TypeError):
        raise ValueError('public model catalog is missing selected provider') from None
    selected = [row for row in definitions if row.get('id') == model_id]
    if len(selected) != 1:
        raise ValueError('exactly one matching public model row is required')
    row = selected[0]
    allowed = {'id', 'name', 'api', 'reasoning', 'input', 'contextWindow', 'contextTokens',
               'maxTokens', 'cost', 'thinkingLevelMap', 'compat'}
    if set(row) - allowed or re.search(r'(?i)(https?://|bearer\s+|api[_-]?key|secret)', json.dumps(row)):
        raise ValueError('model row contains unknown or potentially sensitive data')
    return {'mode': 'merge', 'providers': {provider: {'models': [row]}}}


def agent_config(models, model, plugin_path, port_number, extras, profile, executor_backend=None):
    tools = list(TOOLS) + list(extras)
    return {
        'agents': {'defaults': {'skipBootstrap': True, 'contextInjection': 'never', 'thinkingDefault': 'low',
                                'model': {'primary': model, 'fallbacks': []}, 'sandbox': {'mode': 'off'},
                                'systemAgent': {'agentId': 'main'}},
                   'entries': {'main': {'name': 'Synthetic Browser', 'skills': ['browser-research'],
                                        'model': {'primary': model, 'fallbacks': []},
                                        'thinkingDefault': 'low', 'sandbox': {'mode': 'off'},
                                        'tools': {'allow': tools, 'deny': ['view_image']}}}},
        'models': models,
        **({'auth': {'profiles': {'openai:default': {'provider': 'openai', 'mode': 'oauth'}}}} if profile else {}),
        'tools': {'profile': 'minimal', 'alsoAllow': tools,
                  'deny': ['browser', 'terminal', 'exec', 'process', 'write', 'edit', 'apply_patch',
                           'message', 'gateway', 'sessions_spawn', 'sessions_send', 'camofox_screenshot',
                           'camofox_evaluate', 'camofox_import_cookies', 'view_image'],
                  'fs': {'workspaceOnly': True}, 'codeMode': False,
                  'toolSearch': {'mode': 'directory', 'searchDefaultLimit': 5, 'maxSearchLimit': 10}},
        'plugins': {'enabled': True, 'allow': [model.split('/')[0], 'camofox-browser'],
                    'load': {'paths': [str(plugin_path)]}, 'entries': {'camofox-browser': {'enabled': True,
                        'config': {'autoStart': False, 'url': 'http://127.0.0.1:' + str(port_number),
                                   **({'browserExecutor': {'enabled': True, 'backend': executor_backend,
                                        'maxSteps': 8, 'timeoutMs': 120000, 'threshold': 0.5, 'margin': 0.05}}
                                       if executor_backend else {})}}}},
        'skills': {'load': {'extraDirs': [str(REPO / 'modules/home/openclaw/skills')]}}
    }


@contextmanager
def temporary_fixture(podman, connection, image, env):
    name = 'wave-browser-bench-' + uuid.uuid4().hex[:12]
    ports = {'camofox': pick_port(), 'fixture': pick_port()}
    if ports['camofox'] == ports['fixture']:
        raise RuntimeError('port collision')
    prefix = [podman, '--connection', connection]
    launched = False
    fixture = None
    try:
        proc = subprocess.run(prefix + ['run', '--detach', '--name', name, '--pull=never',
            '--cap-drop', 'AUDIT_WRITE', '--cap-drop', 'MKNOD', '--cap-drop', 'NET_RAW',
            '--cap-drop', 'NET_BIND_SERVICE', '--security-opt', 'no-new-privileges',
            '--pids-limit', '512', '--shm-size', '2g',
            '--publish', '127.0.0.1:%d:9377' % ports['camofox'],
            '--publish', '127.0.0.1:%d:%d' % (ports['fixture'], PORT_INSIDE),
            '--mount', 'type=bind,src=%s,dst=/fixture,readonly' % HERE,
            '--env', 'CAMOFOX_ACCESS_KEY', '--env', 'CAMOFOX_PORT=9377',
            '--env', 'CAMOFOX_BIND_HOST=0.0.0.0', '--env', 'CAMOFOX_INTERACTIVE=off',
            '--env', 'CAMOFOX_CRASH_REPORT_ENABLED=false',
            '--env', 'CAMOFOX_DISABLE_DEFAULT_ADDONS=true', image],
            env=env, capture_output=True, text=True, timeout=65, check=False)
        if proc.returncode:
            raise RuntimeError('disposable Camofox container failed to start')
        launched = True
        for _ in range(60):
            try:
                if fetch_json('http://127.0.0.1:%d/health' % ports['camofox'])['ok']:
                    break
            except (OSError, KeyError):
                time.sleep(1)
        else:
            raise RuntimeError('disposable Camofox health check timed out')
        fixture = subprocess.Popen(prefix + ['exec', name, 'node', '/fixture/server.js',
                                             '--host', '0.0.0.0', '--port', str(PORT_INSIDE)],
                                   env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, text=True)
        import selectors
        selector = selectors.DefaultSelector()
        selector.register(fixture.stdout, selectors.EVENT_READ)
        if not selector.select(timeout=25):
            raise RuntimeError('disposable fixture did not start')
        first = json.loads(fixture.stdout.readline())
        if not first.get('oracleKey') or not first.get('baseUrl'):
            raise RuntimeError('invalid fixture startup')
        yield ports, first['oracleKey']  # Key stays in orchestrator memory.
    finally:
        if fixture and fixture.poll() is None:
            fixture.terminate()
            try:
                fixture.wait(timeout=8)
            except subprocess.TimeoutExpired:
                fixture.kill()
        if launched:
            subprocess.run(prefix + ['stop', '--time', '3', name], env=env, capture_output=True, timeout=35, check=False)
            subprocess.run(prefix + ['rm', '-f', name], env=env, capture_output=True, timeout=35, check=False)


def sample_rss(pid):
    try:
        result = subprocess.run(['ps', '-o', 'rss=', '-p', str(pid)], capture_output=True, text=True, timeout=2)
        return int(result.stdout.strip() or 0)
    except (ValueError, subprocess.TimeoutExpired):
        return 0


def clean_up_own_tabs(port_number, access_key, session_id):
    if not session_id or not re.fullmatch(r'[a-f0-9-]{36}', session_id):
        return
    for scope in ('agent:main:explicit:' + session_id, session_id):
        identity = hmac.new(access_key.encode(), scope.encode(), hashlib.sha256).hexdigest()
        suffix = '?userId=' + identity
        headers = {'Authorization': 'Bearer ' + access_key}
        try:
            with urllib.request.urlopen(urllib.request.Request(
                    'http://127.0.0.1:%d/tabs%s' % (port_number, suffix), headers=headers), timeout=3) as response:
                payload = json.load(response)
                tabs = payload.get('tabs', []) if isinstance(payload, dict) else []
            for tab in tabs:
                tab_id = tab.get('tabId') if isinstance(tab, dict) else None
                if not isinstance(tab_id, str) or not re.fullmatch(r'[\w-]{1,128}', tab_id):
                    continue
                request = urllib.request.Request('http://127.0.0.1:%d/tabs/%s%s' % (port_number, tab_id, suffix),
                                                 headers=headers, method='DELETE')
                urllib.request.urlopen(request, timeout=3).close()
        except (OSError, ValueError, TypeError):
            pass


def run_one(args, item, ports, oracle_key, base_env, catalog, output):
    task = item['id']
    if not re.fullmatch(r'[a-z]+-\d\d', task) or item['category'] not in ('search', 'booking', 'forms', 'login', 'cart', 'spa', 'long'):
        raise ValueError('invalid synthetic fixture manifest')
    duration = 600 if item['category'] == 'long' else 300
    run_id = uuid.uuid4().hex
    directory = output / (task + '-' + uuid.uuid4().hex[:8])
    directory.mkdir(mode=0o700)
    home, state, cwd = (directory / name for name in ('home', 'state', 'workspace'))
    for path in (home, state, cwd):
        path.mkdir(mode=0o700)
    config_path = directory / 'config.json'
    config_path.write_text(json.dumps(agent_config(catalog, args.model, args.plugin_path,
                             ports['camofox'], args.extra_tool, bool(args.auth_profile_file), args.executor_backend)))
    config_path.chmod(0o600)
    env = dict(base_env, HOME=str(home), OPENCLAW_STATE_DIR=str(state),
               OPENCLAW_CONFIG_PATH=str(config_path), CAMOFOX_ACCESS_KEY=base_env['CAMOFOX_ACCESS_KEY'])
    db = state / 'agents/main/agent/openclaw-agent.sqlite'
    start_url = 'http://127.0.0.1:%d/run/%s/%s/start' % (PORT_INSIDE, run_id, task)
    oracle_url = 'http://127.0.0.1:%d/api/runs/%s' % (ports['fixture'], run_id)
    prompt = args.prompt_template.format(goal=item['goal'], start_url=start_url,
                                         variables=json.dumps(item['variables'], sort_keys=True))
    started = time.monotonic()
    summary = {'task': task, 'category': item['category'], 'split': item['split'], 'status': 'error',
               'success': None, 'oracle_unavailable': True}
    agent = None
    session_id = None
    try:
        if args.auth_profile_file:
            profile = private_access_profile(args.auth_profile_file, duration + 70)
            install_access_profile(args.openclaw, config_path, state, cwd, env, profile, args.model)
        env['WAVE_HYBRID_METRICS_PATH'] = str(directory / 'local-metrics.jsonl')
        agent = subprocess.Popen([args.openclaw, 'agent', 'exec', '--config', str(config_path),
            '--state-dir', str(state), '--cwd', str(cwd), '--model', args.model,
            '--thinking', 'low', '--no-auth-env-only', '--timeout', str(duration), '--json',
            '--message-file', '-'], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True)
        agent.stdin.write(prompt)
        agent.stdin.close()
        agent.stdin = None
        turn_started = time.monotonic()
        rss_peak, browser_rss, steps = 0, [], 0
        while agent.poll() is None:
            rss_peak = max(rss_peak, sample_rss(agent.pid))
            try:
                browser_rss.append(fetch_json('http://127.0.0.1:%d/health' % ports['camofox'])['memory']['rssMb'])
            except (OSError, KeyError):
                pass
            if db.is_file():
                try:
                    conn = sqlite3.connect('file:' + str(db) + '?mode=ro', uri=True, timeout=.5)
                    rows = conn.execute('SELECT event_json FROM transcript_events WHERE event_json LIKE ?', ('%"toolCall"%',)).fetchall()
                    conn.close()
                    steps = sum(sum(1 for block in json.loads(row[0]).get('message', {}).get('content', [])
                                    if isinstance(block, dict) and block.get('type') == 'toolCall' and
                                    (block.get('name') == 'tool_call' or block.get('name', '').startswith('camofox_')))
                                for row in rows)
                except sqlite3.Error:
                    pass
            if steps >= item['max_steps'] or time.monotonic() - turn_started > duration + 20:
                summary['step_budget_hit'] = steps >= item['max_steps']
                summary['timed_out'] = time.monotonic() - turn_started > duration + 20
                agent.terminate()
                break
            time.sleep(1)
        try:
            stdout, _ = agent.communicate(timeout=12)
        except subprocess.TimeoutExpired:
            agent.kill()
            stdout, _ = agent.communicate(timeout=8)
        try:
            envelope = json.loads(stdout)
        except ValueError:
            envelope = {}
        session_id = envelope.get('sessionId')
        summary.update({'status': envelope.get('status', 'error'), 'model_resolved':
                        (envelope.get('provider') or '') + '/' + (envelope.get('model') or ''),
                        'turns': envelope.get('assistantTurns'), 'agent_rss_peak_kib': rss_peak,
                        'camofox_server_rss_peak_mib': max(browser_rss, default=None),
                        'agent_turn_seconds': round(time.monotonic() - turn_started, 3),
                        'steps_budget_hit': summary.get('step_budget_hit', False),
                        'timed_out': summary.get('timed_out', envelope.get('status') == 'timeout')})
        summary.update(transcript_metrics(db, session_id))
        if args.trace_synthetic:
            (directory / 'synthetic-tool-trace.json').write_text(json.dumps(synthetic_trace(db, session_id)))
        if args.hosted_trace:
            (directory / 'hosted-trace.json').write_text(json.dumps(hosted_trace(db, session_id), indent=2))
        metrics_file = directory / 'local-metrics.jsonl'
        if metrics_file.is_file():
            events = [json.loads(line) for line in metrics_file.read_text().splitlines() if line.strip()]
            latencies = [round(float(event['latency_ms']), 3) for event in events
                         if event.get('backend') in ('kev', 'laya') and isinstance(event.get('latency_ms'), (float, int))]
            result_reasons = {}
            for event in events:
                if event.get('event') == 'result' and re.fullmatch('[a-z_]+', str(event.get('reason', ''))):
                    reason = event['reason']
                    result_reasons['reason:' + reason] = result_reasons.get('reason:' + reason, 0) + 1
            summary.update({'local_calls': len(latencies),
                            'local_steps': sum(e.get('event') == 'action' for e in events),
                            'local_snapshots_unexposed': sum(e.get('event') == 'snapshot' and
                                                              e.get('exposed_to_large_model') is False for e in events),
                            'local_latency_ms': latencies, 'executor_results': result_reasons,
                            'loop_detected': result_reasons.get('reason:action_loop', 0)})
            metrics_file.unlink()
    except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as error:
        summary['error_kind'] = type(error).__name__
    finally:
        if agent and agent.poll() is None:
            agent.kill()
            agent.wait(timeout=8)
        try:
            summary.update(oracle_actions(fetch_json(oracle_url, oracle_key), item['variables']['target']))
            summary['oracle_unavailable'] = False
        except (OSError, KeyError, ValueError):
            pass
        try:
            clean_up_own_tabs(ports['camofox'], base_env['CAMOFOX_ACCESS_KEY'], session_id)
        finally:
            erase_db(db)  # Even unexpected tab-cleanup errors must not retain OAuth access.
            summary['wall_seconds'] = round(time.monotonic() - started, 3)
    return summary


def load_prompt(path):
    default = ('Complete this synthetic browser task: {goal} Start at {start_url}. '
               'Use Camofox on this fixture only. Do not request the oracle. '
               'Close only tabs you created and do not claim unverified completion.')
    text = Path(path).read_text() if path else default
    if len(text) > 8000 or '{goal}' not in text or '{start_url}' not in text:
        raise ValueError('prompt template must include {goal} and {start_url} and fit 8 KB')
    if set(re.findall(r'\{([a-z_]+)\}', text)) - {'goal', 'start_url', 'variables'}:
        raise ValueError('unknown prompt placeholder')
    return text


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--openclaw', required=True, help='Absolute path to installed OpenClaw executable')
    parser.add_argument('--config', required=True, type=Path, help='JSON file with public model catalog ONLY')
    parser.add_argument('--model', required=True, help='Explicit provider/model ID')
    parser.add_argument('--plugin-path', required=True, type=Path, help='Pinned plugin directory with manifest')
    parser.add_argument('--output', required=True, type=Path, help='NEW private directory outside repository')
    parser.add_argument('--suite', required=True, help='Non-sensitive evaluation arm label')
    parser.add_argument('--implementation', default='custom', help='Non-sensitive implementation label')
    parser.add_argument('--image', default=IMAGE, help='Preloaded Camofox image; no pull')
    parser.add_argument('--podman', default='podman')
    parser.add_argument('--connection', default='openclaw-sandbox')
    parser.add_argument('--task', action='append', default=[], help='Run only selected frozen task ID; repeatable')
    parser.add_argument('--extra-tool', action='append', default=[], choices=sorted(EXTRA_TOOLS))
    parser.add_argument('--auth-env', action='append', default=[], choices=sorted(AUTH_ENV),
                        help='Read only this provider key from the caller environment')
    parser.add_argument('--auth-profile-file', type=Path, help='Explicit private access-only OAuth JSON (no refresh)')
    parser.add_argument('--model-executable', type=Path, help='Optional plugin-specific executable; see docs')
    parser.add_argument('--executor-backend', choices=('kev', 'laya'),
                        help='Enable configured browser_execute for a plugin variant that declares it')
    parser.add_argument('--hosted-trace', action='store_true', help='Keep value-free tool and usage metrics by turn')
    parser.add_argument('--prompt-template-file', type=Path)
    parser.add_argument('--trace-synthetic', action='store_true',
                        help='Keep compact fixture-only tool names/refs; never raw transcripts or images')
    args = parser.parse_args(argv)
    if not re.fullmatch('[a-z0-9][a-z0-9-]{0,60}', args.suite) or not re.fullmatch('[a-z0-9][a-z0-9-]{0,60}', args.implementation):
        parser.error('suite and implementation must be safe, non-sensitive labels')
    args.openclaw = str(Path(args.openclaw).resolve())
    if not Path(args.openclaw).is_file() or not os.access(args.openclaw, os.X_OK):
        parser.error('OpenClaw executable unavailable')
    with Path(args.openclaw).open('rb') as binary:
        if b'secrets store get OPENCLAW_GATEWAY_TOKEN' in binary.read(8192):
            parser.error('Gateway-token-injecting CLI wrapper is not permitted; use the direct packaged executable')
    args.plugin_path = args.plugin_path.resolve()
    if not (args.plugin_path / 'openclaw.plugin.json').is_file() or not (args.plugin_path / 'plugin.js').is_file():
        parser.error('plugin directory lacks manifest/entry point')
    if set(args.extra_tool) - set(json.loads((args.plugin_path / 'openclaw.plugin.json').read_text()).get('contracts', {}).get('tools', [])):
        parser.error('extra tool not declared by plugin manifest')
    if args.model_executable and (not args.model_executable.is_absolute() or not os.access(args.model_executable, os.X_OK)):
        parser.error('local model executable must be an existing absolute executable')
    if args.model_executable and 'browser_execute' not in args.extra_tool:
        parser.error('--model-executable requires --extra-tool browser_execute')
    if args.executor_backend and 'browser_execute' not in args.extra_tool:
        parser.error('--executor-backend requires --extra-tool browser_execute')
    if args.auth_profile_file and args.auth_env:
        parser.error('choose environment credentials OR an explicit OAuth profile, not both')
    if not args.auth_profile_file and not args.auth_env:
        parser.error('specify --auth-env NAME (default credential mode) or opt in to --auth-profile-file')
    provider = args.model.partition('/')[0]
    if provider not in PROVIDER_ENV:
        parser.error('only explicitly supported provider routes are allowed')
    if args.auth_env and args.auth_env != [PROVIDER_ENV[provider]]:
        parser.error('specify only the credential environment variable matching the selected provider')
    if args.auth_profile_file and provider != 'openai':
        parser.error('access-only OAuth profile is supported only for OpenAI')
    output = args.output.resolve()
    if output == REPO or REPO in output.parents or output.exists():
        parser.error('output must be a new directory outside this public repository')
    args.output = output
    args.prompt_template = load_prompt(args.prompt_template_file)
    return args


def main(argv=None):
    args = parse_args(argv)
    catalog = model_config(args.config, args.model)
    output = args.output
    output.mkdir(mode=0o700, parents=True)
    for env_name in args.auth_env:
        if not os.environ.get(env_name):
            raise ValueError('requested provider auth environment variable is missing')
    env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
           'TMPDIR': str(output), 'CAMOFOX_ACCESS_KEY': secrets.token_hex(32),
           'OPENCLAW_DISABLE_PERSISTED_PLUGIN_REGISTRY': '1'}
    for name in args.auth_env:
        env[name] = os.environ[name]
    if args.model_executable:
        env['BROWSER_DECISION_EXECUTABLE'] = str(args.model_executable)
    def interrupted(*_):
        raise KeyboardInterrupt()
    old = signal.signal(signal.SIGTERM, interrupted)
    try:
        # Podman needs its own connection configuration; agents do not inherit it.
        podman_env = dict(os.environ, CAMOFOX_ACCESS_KEY=env['CAMOFOX_ACCESS_KEY'])
        with temporary_fixture(args.podman, args.connection, args.image, podman_env) as (ports, key):
            tasks = fetch_json('http://127.0.0.1:%d/api/tasks' % ports['fixture'])
            if len(tasks) != 30:
                raise RuntimeError('frozen fixture must have 30 tasks')
            if args.task:
                selected = set(args.task)
                tasks = [task for task in tasks if task['id'] in selected]
                if len(tasks) != len(selected):
                    raise ValueError('requested task not found')
            fingerprint = hashlib.sha256(''.join(digest(path) for path in
                (Path(__file__), HERE / 'server.js', HERE / 'tasks.js', args.config,
                 args.plugin_path / 'plugin.js')).encode()).hexdigest()
            (output / 'manifest.json').write_text(json.dumps({
                'suite': args.suite, 'model': args.model, 'image': args.image,
                'fixture_sha256': {'tasks.js': digest(HERE / 'tasks.js'), 'server.js': digest(HERE / 'server.js')},
                'code_fingerprint_sha256': fingerprint, 'task_count': len(tasks),
                'credential_mode': 'explicit-access-only-oauth' if args.auth_profile_file else 'allowlisted-provider-environment',
                'note': 'Agent exec uses pinned config and isolated HOME/state; --auth-env-only conflicts with --config in OpenClaw 2026.9.4. Never route this to a live Camofox service.'
            }, sort_keys=True, indent=2) + '\n')
            for item in tasks:
                summary = run_one(args, item, ports, key, env, catalog, output)
                row = {'suite': args.suite, 'scenario': 'frozen30', 'implementation': args.implementation,
                       **summary, 'historical_code_sha256': fingerprint,
                       'local_calls': summary.get('local_calls'), 'local_steps': summary.get('local_steps'),
                       'local_latency_ms': summary.get('local_latency_ms', []),
                       'executor_results': summary.get('executor_results', {}),
                       'loop_detected': summary.get('loop_detected')}
                with (output / 'measurements.jsonl').open('a') as stream:
                    stream.write(json.dumps(row, sort_keys=True) + '\n')
                print(json.dumps({'task': item['id'], 'oracle_pass': row['success'],
                                  'status': row['status'], 'wall_seconds': row['wall_seconds']}), flush=True)
    finally:
        signal.signal(signal.SIGTERM, old)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, RuntimeError, OSError) as error:
        print('benchmark failed: ' + type(error).__name__, file=sys.stderr)
        sys.exit(2)
