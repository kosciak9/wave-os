import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { createDecisionBridge, nativeDecision, nativeRequest, compactState } from '../bridge.mjs';

const state = { goal: 'Open Documentation', url: 'https://example.invalid', title: 'Docs navigation',
  text: 'Home | Documentation | Pricing', fields: [], recent: [] };
const choices = ['CLICK link Home [e1]', 'CLICK link Documentation [e2]', 'STOP checkpoint', 'ESCALATE blocked'];
const executable = process.env.BROWSER_DECISION_EXECUTABLE;

test('native Laya operation/target probabilities map to legal joint choices', () => {
  const request = nativeRequest(state, choices);
  assert.deepEqual(Object.keys(request.questions.operation.criteria), ['CLICK', 'DONE', 'BLOCKED']);
  const result = nativeDecision({ answers: {
    operation: { choice: 'CLICK', probabilities: { CLICK: 0.6, DONE: 0.3, BLOCKED: 0.1 } },
    click_target: { choice: '2', probabilities: { '1': 0.2, '2': 0.8 } },
  }, latency_ms: 20 }, request, choices);
  assert.equal(result.choice, choices[1]);
  assert.ok(Math.abs(Object.values(result.probabilities).reduce((a, b) => a + b) - 1) < 1e-9);
  assert.throws(() => nativeDecision({ answers: { operation: { choice: 'CLICK', probabilities: { CLICK: 1 } }, click_target: { choice: '7' } } }, request, choices));
  assert.ok(compactState(state).includes('Documentation'));
});

test('joint Laya argmax may differ from most probable operation', () => {
  const opts = ['CLICK link A [e1]', 'CLICK link B [e2]', 'TYPE field [e3] <- query=x', 'STOP checkpoint', 'ESCALATE blocked'];
  const req = nativeRequest(state, opts);
  const result = nativeDecision({ answers: {
    operation: { choice: 'CLICK', probabilities: { CLICK: 0.42, TYPE_TEXT: 0.35, DONE: 0.13, BLOCKED: 0.1 } },
    click_target: { choice: '1', probabilities: { '1': 0.51, '2': 0.49 } },
    type_text_target: { choice: '1', probabilities: { '1': 1 } },
  }, latency_ms: 30 }, req, opts);
  assert.equal(result.choice, opts[2]);
  assert.ok(Math.abs(Object.values(result.probabilities).reduce((a, b) => a + b, 0) - 1) < 1e-8);
});

test('Laya page text includes unchanged current field values without refs', () => {
  const req = nativeRequest({ ...state, fields: [{ label: 'Requested date', value: '2029-05-06' }] }, choices);
  assert.match(req.state.page.text, /Requested date=2029-05-06/);
  assert.ok(req.state.page.text.length <= 1200);
});

test('native distributions reject missing/spurious keys, ties, nonfinite scores and a false declared winner', () => {
  const request = nativeRequest(state, choices);
  const valid = { latency_ms: 2, answers: {
    operation: { choice: 'CLICK', probabilities: { CLICK: 0.7, DONE: 0.2, BLOCKED: 0.1 } },
    click_target: { choice: '2', probabilities: { '1': 0.2, '2': 0.8 } },
  } };
  const mutations = [
    a => { delete a.answers.operation.probabilities.DONE; },
    a => { a.answers.operation.probabilities.EXTRA = 0; },
    a => { a.answers.operation.probabilities.DONE = Number.NaN; },
    a => { a.answers.operation.choice = 'BLOCKED'; },
    a => { a.answers.operation.probabilities = { CLICK: 0.5, DONE: 0.5, BLOCKED: 0 }; },
    a => { a.answers.click_target.probabilities = { '1': 0.5, '2': 0.5 }; },
    a => { a.answers.click_target.choice = '1'; },
    a => { a.answers.click_target.probabilities['3'] = 0; },
    a => { a.answers.extra = {}; },
  ];
  for (const mutate of mutations) {
    const answer = structuredClone(valid);
    mutate(answer);
    assert.throws(() => nativeDecision(answer, request, choices), /invalid_native_answer/);
  }
});

test('retirement blocks admission until close and malformed input leaves existing worker reusable', async () => {
  const processes = [];
  const spawnImpl = () => {
    const proc = new EventEmitter();
    proc.stdin = new EventEmitter(); proc.stdout = new EventEmitter();
    proc.kill = signal => { if (signal === 'SIGTERM') setTimeout(() => proc.emit('close'), 30); return true; };
    proc.stdin.write = (line, callback) => {
      const input = JSON.parse(line);
      const probabilities = Object.fromEntries(input.choices.map((choice, index) => [choice, index ? 0 : 1]));
      queueMicrotask(() => { callback(); proc.stdout.emit('data', Buffer.from(JSON.stringify({
        choice: input.choices[0], probabilities, latency_ms: 1,
      }) + '\n')); });
    };
    processes.push(proc);
    return proc;
  };
  const bridge = createDecisionBridge({ executable: '/trusted/test-worker', spawnImpl });
  try {
    assert.equal((await bridge({ state, choices })).choice, choices[0]);
    await assert.rejects(bridge({ state: { ...state, goal: 'x'.repeat(400) }, choices }), /model_input_limit/);
    assert.equal((await bridge({ state, choices })).choice, choices[0]);
    assert.equal(processes.length, 1);
    const retiring = bridge.close();
    await assert.rejects(bridge({ state, choices }), /local_worker_retiring/);
    assert.equal(processes.length, 1);
    await retiring;
    assert.equal((await bridge({ state, choices })).choice, choices[0]);
    assert.equal(processes.length, 2);
  } finally { await bridge.close(); }
});

test('ignored SIGTERM escalates to SIGKILL and no second resident starts before close', async () => {
  const signals = [];
  let spawns = 0;
  const bridge = createDecisionBridge({ executable: '/trusted/stubborn-worker', shutdownGraceMs: 25,
    spawnImpl: () => {
      spawns++;
      const proc = new EventEmitter();
      proc.stdin = new EventEmitter(); proc.stdout = new EventEmitter();
      proc.stdin.write = (line, callback) => {
        const { choices: offered } = JSON.parse(line);
        queueMicrotask(() => { callback(); proc.stdout.emit('data', Buffer.from(JSON.stringify({
          choice: offered[0], probabilities: Object.fromEntries(offered.map((choice, i) => [choice, Number(i === 0)])),
          latency_ms: 1,
        }) + '\n')); });
      };
      proc.kill = signal => { signals.push(signal); if (signal === 'SIGKILL') setTimeout(() => proc.emit('close'), 10); return true; };
      return proc;
    } });
  try {
    await bridge({ state, choices });
    const closing = bridge.close();
    await assert.rejects(bridge({ state, choices }), /local_worker_retiring/);
    await new Promise(resolve => setTimeout(resolve, 45));
    await closing;
    assert.deepEqual(signals, ['SIGTERM', 'SIGKILL']);
    assert.equal(spawns, 1);
    await bridge({ state, choices });
    assert.equal(spawns, 2);
  } finally { await Promise.all([bridge.close(), new Promise(resolve => setTimeout(resolve, 60))]); }
});

test('persistent packaged subprocess answers sequential requests; bridge closes process', { skip: !executable }, async () => {
  const pids = [];
  const bridge = createDecisionBridge({ executable, backend: 'laya', callMs: 60_000, onMetric: metric => pids.push(metric.pid) });
  try {
    const first = await bridge({ state, choices });
    const second = await bridge({ state, choices });
    assert.ok(choices.includes(first.choice));
    assert.equal(first.choice, second.choice);
    assert.equal(pids[0], pids[1]);
  } finally { await bridge.close(); }
});

test('bridge admits one waiting call and rejects a third before spawning another worker', { skip: !executable }, async () => {
  const bridge = createDecisionBridge({ executable,
    backend: 'kev', callMs: 60_000 });
  try {
    const first = bridge({ state, choices });
    const second = bridge({ state, choices });
    await assert.rejects(bridge({ state, choices }), /queue_full/);
    assert.ok(choices.includes((await first).choice));
    assert.ok(choices.includes((await second).choice));
  } finally { await bridge.close(); }
});
