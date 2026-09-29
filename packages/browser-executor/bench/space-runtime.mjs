import { createHash, randomUUID } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { createCamofoxBrowser } from '../camofox.mjs';
import { createDecisionBridge } from '../bridge.mjs';

const [inputPath, outputPath] = process.argv.slice(2);
const spec = JSON.parse(readFileSync(inputPath, 'utf8'));
const { task, baseUrl, camofoxUrl, backend, executable, variant, corePath, expectedCoreHash,
  policyMode } = spec;
const hash = path => createHash('sha256').update(readFileSync(path)).digest('hex');
if (hash(corePath) !== expectedCoreHash) throw Error('core_provenance_mismatch');
const { executeSemanticBrowser } = await import(pathToFileURL(corePath).href);
const userId = randomUUID(), runId = randomUUID();
const browser = createCamofoxBrowser({ baseUrl: camofoxUrl, userId, accessKey: process.env.CAMOFOX_ACCESS_KEY });
const route = url => {
  const u = new URL(url);
  if (u.origin !== new URL(baseUrl).origin ||
      !u.pathname.startsWith(`/space/run/${runId}/${task.id}/`)) return 'other_origin_or_route';
  return u.pathname.split('/').at(-1);
};
const trajectory = [], observations = new Map(), choices = [];
let latestRoute = null, latestTitle = null, pendingMutation, tabId, bridge;
const observed = { ...browser, async snapshot(...args) {
  const value = await browser.snapshot(...args);
  const r = route(value.url);
  const title = /^\s*- heading "([^"]+)"/m.exec(value.snapshot)?.[1] ?? '';
  const stage = /stage (\d+) of 12/i.exec(title)?.[1] ??
    /receipt (\d+) of 12/i.exec(title)?.[1] ?? null;
  const phase = /final receipt/i.test(title) ? 'final' : /decision required/i.test(title) ? 'decision' :
    /details receipt/i.test(title) ? 'receipt' : /archive inquiry stage/i.test(title) ? 'form' :
    /choose archive/i.test(title) ? 'branch' : 'other';
  const fingerprint = createHash('sha256').update(JSON.stringify([r, value.snapshot.replace(/\[e\d+\]/g, ''),
    value.structure?.forms?.map(f => f.fields?.map(field => [field.name, field.value]))])).digest('hex').slice(0, 16);
  observations.set(fingerprint, (observations.get(fingerprint) ?? 0) + 1);
  if (pendingMutation) {
    pendingMutation.route_after = r;
    pendingMutation.phase_after = phase;
    pendingMutation = null;
  }
  if (trajectory.length === 0) trajectory.push({ event: 'initial_fields', fields: value.structure?.forms?.flatMap(f =>
    f.fields ?? []).map(f => ({ name: Object.hasOwn(task.variables, f.name) ? f.name : 'other',
      label: Object.hasOwn(task.variables, f.label) ? f.label : 'other', type: f.type })) });
  latestRoute = r; latestTitle = phase;
  trajectory.push({ event: 'observation', route: r, phase, stage: stage && Number(stage),
    digest: fingerprint, repeated: observations.get(fingerprint) > 1 });
  return value;
}, ...Object.fromEntries(['click', 'type', 'select', 'scroll'].map(kind => [kind, async (...args) => {
  const entry = { event: 'mutation', kind, route_before: latestRoute, phase_before: latestTitle };
  // Labels are derived from the observed AX structure, never refs, values or URLs.
  const last = choices.at(-1);
  if (last?.kind === kind.toUpperCase() && kind === 'click') entry.label = last.label;
  trajectory.push(entry);
  pendingMutation = entry;
  return browser[kind](...args);
}])) };
const sanitizeChoice = choice => {
  const m = /^CLICK (?:button|link) "([^"\n]+)"/.exec(choice);
  return m?.[1]?.slice(0, 90) ?? null;
};
const safeChoice = (choice, probability) => ({ kind: choice.split(' ')[0],
  label: sanitizeChoice(choice), probability });
const event = detail => trajectory.push({ event: 'policy', ...detail });
const started = performance.now();
const record = { task: task.id, variant, backend, policy_mode: policyMode ?? null, hosted: false,
  core_sha256: expectedCoreHash, runtime_sha256: hash(new URL(import.meta.url)), trajectory };
try {
  const created = await fetch(`${camofoxUrl}/tabs`, { method: 'POST', headers: {
    Authorization: `Bearer ${process.env.CAMOFOX_ACCESS_KEY}`, 'content-type': 'application/json' },
  body: JSON.stringify({ userId, sessionKey: userId, url: `${baseUrl}${task.start_path.replace('{runId}', runId)}` }),
  signal: AbortSignal.timeout(30000) });
  if (!created.ok) throw Error('tab_creation_failed');
  tabId = (await created.json()).tabId;
  if (!/^[\w-]{1,128}$/.test(tabId)) throw Error('invalid_tab');
  bridge = createDecisionBridge({ executable, backend, callMs: 20000,
    onMetric: metric => event({ kind: 'bridge', metric: metric.event, reason: metric.reason ?? null }) });
  let decide = bridge;
  if (['deterministic', 'planner', 'planner-full', 'binary', 'binary-memory'].includes(variant)) {
    const policyFile = variant === 'planner-full' ? 'planner' : variant === 'binary-memory' ? 'binary' : variant;
    const module = await import(`./space-${policyFile}-policy.mjs`);
    decide = module.createPolicy({ bridge, onEvent: event,
      ...(['binary', 'binary-memory'].includes(variant) ?
        { mode: variant === 'binary-memory' ? 'memory' : 'plain' } : policyMode ? { mode: policyMode } : {}) });
    if (typeof decide !== 'function') throw Error('invalid_policy_factory');
  }
  let policyCalls = 0;
  const model = async (input, options) => {
    policyCalls++;
    const answer = await decide(input, options);
    const ranked = Object.values(answer.probabilities ?? {}).filter(Number.isFinite).sort((a, b) => b - a);
    const kind = answer.choice?.split(' ')[0] ?? 'none';
    const row = { event: 'decision', kind, label: sanitizeChoice(answer.choice), route: latestRoute,
      phase: latestTitle, candidates: input.choices.length, confidence: ranked[0] ?? null,
      margin: ranked.length > 1 ? ranked[0] - ranked[1] : null,
      top2: input.choices.filter(choice => Number.isFinite(answer.probabilities?.[choice]))
        .toSorted((a, b) => answer.probabilities[b] - answer.probabilities[a]).slice(0, 2)
        .map(choice => safeChoice(choice, answer.probabilities[choice])) };
    choices.push(row); trajectory.push(row);
    return answer;
  };
  const goal = task.goal.split(' Facts:')[0];
  record.goal_format = 'task_description_without_repeated_manifest_facts';
  if (goal.length > 360) throw Error('goal_too_long');
  const request = { tabId, goal, facts: task.variables,
    constraints: { allowedOrigins: [new URL(baseUrl).origin], forbidActions: [] } };
  const offeredStop = ['aggressive', 'deterministic', 'planner', 'planner-full', 'binary', 'binary-memory'].includes(variant);
  const extended = variant !== 'baseline';
  record.cap = extended ? 128 : 24;
  record.timeout_ms = extended ? 240000 : 120000;
  record.boundary = offeredStop || variant === 'aggressive-continue' ? 'none' : 'adaptive';
  record.semantic_stop_offered = offeredStop;
  record.prepared_fields = variant !== 'planner-full';
  record.fact_policy = variant === 'planner-full' ? 'native_model_each_field' :
    'frozen_core_deterministic_prepared_fields';
  record.navigation_policy = ['planner', 'planner-full'].includes(variant) ? 'two_level_native' :
    variant === 'deterministic' ? `deterministic_${policyMode ?? 'unique'}` :
    ['binary', 'binary-memory'].includes(variant) ? `binary_${variant === 'binary-memory' ? 'memory' : 'stateless'}` : 'native';
  record.result = await executeSemanticBrowser(request, { browser: observed, decide: model,
    maxSteps: record.cap, timeoutMs: record.timeout_ms, semanticBoundary: record.boundary,
    threshold: 0.5, margin: 0.05, telemetry: metric => {
      if (metric.event === 'action' || metric.event === 'boundary' || metric.event === 'result')
        trajectory.push({ event: 'core', kind: metric.event, step: metric.step ?? metric.steps ?? null,
          action: metric.kind ?? null, reason: metric.reason ?? null, deterministic: metric.deterministic ?? null });
    } });
  record.policy_calls = policyCalls;
} catch (error) {
  record.error = /^[a-z_]+$/.test(error.message) ? error.message : 'runner_error';
} finally {
  try { await bridge?.close(); } catch { record.close_error = true; }
  if (tabId) try { await fetch(`${camofoxUrl}/tabs/${tabId}?${new URLSearchParams({ userId })}`, {
    method: 'DELETE', headers: { Authorization: `Bearer ${process.env.CAMOFOX_ACCESS_KEY}` },
    signal: AbortSignal.timeout(8000) }); } catch { record.tab_cleanup_error = true; }
}
record.elapsed_ms = Math.round(performance.now() - started);
record.native_calls = trajectory.filter(row => row.event === 'policy' && row.kind === 'bridge' &&
  row.metric === 'model_call').length;
record.runId = runId; // Private temporary handoff to the orchestrator; never published.
writeFileSync(outputPath, JSON.stringify(record), { mode: 0o600 });
