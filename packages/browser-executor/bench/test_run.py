"""Offline tests of benchmark isolation, redaction, metrics and cleanup."""

import importlib.util
import io
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from contextlib import redirect_stderr
from unittest.mock import patch


HERE = Path(__file__).resolve().parent


def load(name):
    spec = importlib.util.spec_from_file_location(name, HERE / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


runner = load('run')
analysis = load('analyze')


class RunnerTests(unittest.TestCase):
    def test_oracle_does_not_conflate_invalid_actions_and_failure(self):
        oracle = {'passed': False, 'mistakes': 1, 'events': [
            {'action': 'start'}, {'action': 'view:detail', 'item': 'decoy'},
            {'action': 'submit:save', 'valid': False}, {'action': 'view:work'}]}
        self.assertEqual(runner.oracle_actions(oracle, 'target'), {
            'success': False, 'mistakes': 1, 'wrong_actions': 2, 'oracle_actions': 3})
        self.assertEqual(runner.oracle_actions({'passed': False, 'mistakes': 0,
                                               'events': [{'action': 'start'}]}, 'target')['wrong_actions'], 0)

    def test_redaction_strips_urls_bearer_and_tokens(self):
        value = 'Authorization: Bearer abcsecret https://user:pw@example.com/a?token=abc password="hidden"'
        redacted = runner.redact(value)
        for sensitive in ('abcsecret', 'user:pw', 'example.com', 'token=abc', 'hidden'):
            self.assertNotIn(sensitive, redacted)

    def test_model_catalog_is_allowlisted_and_rejects_embedded_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'config.json'
            path.write_text(json.dumps({'models': {'providers': {'openai': {'models': [
                {'id': 'test', 'api': 'openai-chatgpt-responses', 'contextWindow': 1000}]}}}}))
            self.assertEqual(runner.model_config(path, 'openai/test')['providers']['openai']['models'][0]['id'], 'test')
            path.write_text(json.dumps({'models': {'providers': {'openai': {'models': [
                {'id': 'test', 'apiKey': 'should-not-copy'}]}}}}))
            with self.assertRaises(ValueError):
                runner.model_config(path, 'openai/test')
            path.write_text(json.dumps({'models': {}, 'channels': {'telegram': {}}}))
            with self.assertRaises(ValueError):
                runner.model_config(path, 'openai/test')

    def test_access_profile_refuses_refresh_weak_permissions_and_expiry(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'access.json'
            credential = {'provider': 'openai', 'access': 'not-real',
                          'accountId': 'synthetic', 'expires': int((time.time() + 3600) * 1000)}
            path.write_text(json.dumps(credential))
            path.chmod(0o600)
            self.assertEqual(runner.private_access_profile(path, 300)['refresh'], '')
            path.chmod(0o644)
            with self.assertRaises(ValueError):
                runner.private_access_profile(path, 300)
            path.chmod(0o600)
            path.write_text(json.dumps(dict(credential, refresh='not-allowed')))
            with self.assertRaises(ValueError):
                runner.private_access_profile(path, 300)
            credential['expires'] = int((time.time() + 10) * 1000)
            path.write_text(json.dumps(credential))
            with self.assertRaises(ValueError):
                runner.private_access_profile(path, 300)

    def test_transcript_counts_nested_image_and_input_plus_cache_without_raw_text(self):
        with tempfile.TemporaryDirectory() as directory:
            db = Path(directory) / 'test.sqlite'
            conn = sqlite3.connect(db)
            conn.execute('CREATE TABLE transcript_events(session_id TEXT, seq INTEGER, event_json TEXT)')
            entries = [
                {'type': 'message', 'message': {'role': 'assistant', 'usage': {
                    'input': 8, 'cacheRead': 13, 'contextUsage': {'promptTokens': 24}},
                    'content': [{'type': 'toolCall', 'name': 'tool_call', 'id': 'one',
                                 'arguments': {'id': 'openclaw:camofox-browser:camofox_snapshot', 'args': {'tabId': 'synthetic'}}}]}},
                {'type': 'message', 'message': {'role': 'toolResult', 'toolCallId': 'one', 'content': [
                    {'type': 'text', 'text': json.dumps({'result': {'content': [
                        {'type': 'text', 'text': 'fixture'}, {'type': 'image', 'data': 'ABCDEF'}]}})}]}},
            ]
            conn.executemany('INSERT INTO transcript_events VALUES (?,?,?)',
                             [('session', index, json.dumps(entry)) for index, entry in enumerate(entries)])
            conn.commit()
            conn.close()
            self.assertEqual(runner.transcript_metrics(db, 'session'), {
                'turns_observed': 1, 'model_input_plus_cache': 21, 'prompt_peak_tokens': 24,
                'camofox_actions': 1, 'snapshots_exposed': 1, 'image_blocks': 1,
                'image_encoded_chars': 6})

    def test_podman_cleanup_on_failed_health_only_own_container(self):
        def proc(argv, **_):
            return subprocess.CompletedProcess(argv, 0, stdout='fake-container-id', stderr='')
        with patch.object(runner.subprocess, 'run', side_effect=proc) as calls, \
                patch.object(runner, 'fetch_json', side_effect=OSError('unreachable')), \
                patch.object(runner.time, 'sleep'):
            with self.assertRaises(RuntimeError):
                with runner.temporary_fixture('podman', 'isolated', 'fixture:1', {'CAMOFOX_ACCESS_KEY': 'synthetic'}):
                    self.fail('health was unavailable')
        commands = [call.args[0] for call in calls.call_args_list]
        name = commands[0][commands[0].index('--name') + 1]
        self.assertTrue(name.startswith('wave-browser-bench-'))
        self.assertEqual(commands[-2][-1], name)
        self.assertEqual(commands[-1][-1], name)
        self.assertEqual([command[3] for command in commands], ['run', 'stop', 'rm'])

    def test_tab_cleanup_queries_only_session_scoped_identities(self):
        requests = []
        class Response:
            def __init__(self, value): self.value = value
            def __enter__(self): return self
            def __exit__(self, *_): pass
            def close(self): pass
            def read(self): return json.dumps(self.value).encode()
        def opener(request, timeout):
            requests.append(request)
            if request.get_method() == 'GET':
                return Response({'running': True, 'tabs': [{'tabId': 'own-synthetic-tab'}]})
            return Response({'ok': True})
        with patch.object(runner.urllib.request, 'urlopen', side_effect=opener):
            runner.clean_up_own_tabs(3977, 'synthetic-only', '00000000-0000-0000-0000-000000000001')
        self.assertEqual([request.get_method() for request in requests], ['GET', 'DELETE', 'GET', 'DELETE'])
        self.assertTrue(all('userId=' in request.full_url for request in requests))
        self.assertTrue(all('own-synthetic-tab' in request.full_url for request in requests if request.get_method() == 'DELETE'))

    def test_optional_trace_never_retains_typed_values_urls_or_image_data(self):
        with tempfile.TemporaryDirectory() as directory:
            db = Path(directory) / 'test.sqlite'
            conn = sqlite3.connect(db)
            conn.execute('CREATE TABLE transcript_events(session_id TEXT, seq INTEGER, event_json TEXT)')
            entries = [
                {'type': 'message', 'message': {'role': 'assistant', 'content': [{
                    'type': 'toolCall', 'name': 'tool_call', 'arguments': {
                        'id': 'openclaw:camofox-browser:camofox_type',
                        'args': {'tabId': 'private', 'ref': 'e1', 'text': 'do-not-retain'}}}]}},
                {'type': 'message', 'message': {'role': 'toolResult', 'toolName': 'camofox_snapshot',
                    'content': [{'type': 'text', 'text': json.dumps({'result': {'content': [{
                        'type': 'text', 'text': json.dumps({'url': 'http://127.0.0.1:38891/run/abcd1234/search-01/start',
                                                           'snapshot': 'fixture heading https://secret.invalid/path?token=redacted'})},
                        {'type': 'image', 'data': 'do-not-retain-image'}]}})}]}}
            ]
            conn.executemany('INSERT INTO transcript_events VALUES (?,?,?)',
                             [('session', i, json.dumps(event)) for i, event in enumerate(entries)])
            conn.commit()
            conn.close()
            trace = json.dumps(runner.synthetic_trace(db, 'session'))
            self.assertIn('fixture heading', trace)
            self.assertNotIn('do-not-retain', trace)
            self.assertNotIn('secret.invalid', trace)
            self.assertNotIn('tabId', trace)

    def test_cli_rejects_repo_output_and_mismatched_provider_key(self):
        with tempfile.TemporaryDirectory() as directory:
            plugin = Path(directory) / 'plugin'
            plugin.mkdir()
            (plugin / 'plugin.js').write_text('export default () => {};')
            (plugin / 'openclaw.plugin.json').write_text('{"contracts":{"tools":[]}}')
            args = ['--openclaw', sys.executable, '--config', str(Path(directory) / 'catalog.json'),
                    '--model', 'openai/example', '--plugin-path', str(plugin),
                    '--output', str(Path(directory) / 'output'), '--suite', 'synthetic',
                    '--auth-env', 'OPENROUTER_API_KEY']
            with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                runner.parse_args(args)
            args[args.index('OPENROUTER_API_KEY')] = 'OPENAI_API_KEY'
            args[args.index(str(Path(directory) / 'output'))] = str(runner.REPO / 'never-write-benchmark-here')
            with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                runner.parse_args(args)

    def test_cli_refuses_gateway_token_injecting_wrapper(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'openclaw'
            binary.write_text('#!/bin/sh\nsecrets store get OPENCLAW_GATEWAY_TOKEN\n')
            binary.chmod(0o700)
            plugin = Path(directory) / 'plugin'
            plugin.mkdir()
            (plugin / 'plugin.js').write_text('export default () => {};')
            (plugin / 'openclaw.plugin.json').write_text('{"contracts":{"tools":[]}}')
            with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                runner.parse_args(['--openclaw', str(binary), '--config', str(Path(directory) / 'catalog.json'),
                                   '--model', 'openai/example', '--plugin-path', str(plugin),
                                   '--output', str(Path(directory) / 'output'), '--suite', 'synthetic',
                                   '--auth-env', 'OPENAI_API_KEY'])


class AnalysisTests(unittest.TestCase):
    def test_wilson_and_nearest_rank_are_observation_only(self):
        self.assertEqual(analysis.percentile([100, 4, 8, 10], .95), 100)
        self.assertEqual(analysis.wilson(0, 0), None)
        self.assertEqual(analysis.wilson(3, 3)[1], 1)

    def test_pair_separates_unknown_oracle_and_ties(self):
        left = [{'task': 'a', 'success': True, 'wall_seconds': 10},
                {'task': 'b', 'success': False, 'wall_seconds': 12},
                {'task': 'c', 'success': False, 'wall_seconds': 9}]
        right = [{'task': 'a', 'success': False, 'wall_seconds': 11},
                 {'task': 'b', 'success': True, 'wall_seconds': 8},
                 {'task': 'c', 'success': None, 'wall_seconds': 20}]
        compared = analysis.paired(left, right)
        self.assertEqual(compared['verified_pairs'], 2)
        self.assertEqual(compared['right_minus_left_passes'], 0)
        self.assertEqual(compared['oracle_unavailable_in_pair'], ['c'])
        self.assertEqual(compared['changes']['left_only'], ['a'])
        self.assertEqual(compared['changes']['right_only'], ['b'])

    def test_missing_loop_telemetry_is_unknown_not_zero(self):
        summary = analysis.summarize([{'success': True, 'wall_seconds': 1, 'local_calls': 0}])
        self.assertIsNone(summary['observed_action_loops'])
        self.assertEqual(summary['loop_telemetry_tasks'], 0)
        observed = analysis.summarize([{'success': True, 'wall_seconds': 2, 'local_calls': 2,
                                      'loop_detected': 1,
                                      'executor_results': {'status:escalated': 1}}])
        self.assertEqual(observed['observed_action_loops'], 1)
        self.assertEqual(observed['executor_recovery_task_rate_observed'], 1)


if __name__ == '__main__':
    unittest.main()
