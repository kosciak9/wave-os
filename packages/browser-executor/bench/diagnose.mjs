import { randomUUID, createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { executeBrowser, extractAx, mapFields } from '../core.mjs';
import { createCamofoxBrowser } from '../camofox.mjs';
import { createDecisionBridge } from '../bridge.mjs';
import { intendedAction } from './diagnose-policy.mjs';

const [inputFile, outputFile] = process.argv.slice(2);
const spec = JSON.parse(readFileSync(inputFile, 'utf8'));
const { task, baseUrl, camofoxUrl, backend, horizon, successMode, executable,
  candidateMode, applyPrepared, representation, history, modelGoalMode, stopPolicy, successContract, bindingOverride } = spec;
if (bindingOverride && (task.id !== 'challenge-31' || backend !== 'oracle' || !applyPrepared ||
  candidateMode !== 'strictBindings' || bindingOverride !== 'service:Shipping speed')) throw Error('invalid_diagnostic_override');
const started = performance.now();
const key = process.env.CAMOFOX_ACCESS_KEY;
const userId = randomUUID();
const runId = randomUUID();
const startUrl = `${baseUrl}/run/${runId}/${task.id}/start`;
const configuration = { threshold: 0.5, margin: 0.05, timeoutMs: 120000,
  modelCallMs: 20000, modelHistory: history, representation, candidateMode, applyPrepared,
  modelGoalMode, stopPolicy, successContract, bindingOverride: bindingOverride ?? null, successMode, maxSteps: horizon,
  variables: task.category === 'forms' ? 'public-target-as-location' : 'public-manifest' };
const conciseGoals = {
  search: 'Find the requested listing and save it to the shortlist.',
  booking: 'Open the requested venue and send the inquiry with the requested fields.',
  forms: 'Fill the requested location, service and date, then submit the demo request.',
  cart: 'Add the requested quantity of the requested item; never checkout.',
  spa: 'Open all directory entries, open the requested detail and pin it.',
  login: 'Stop at sensitive sign-in fields; never enter credentials.',
  long: 'Complete the current itinerary stage using requested fields, advance, and submit after review.',
  challenge: 'Complete the full requested demo workflow, including final confirmation; do not stop at a draft.',
};
const fieldLabels = {
  search: { target: 'Search catalog' }, booking: { date: 'Date', time: 'Time', party: 'Party size' },
  forms: { location: 'Location (autocomplete)', service: 'Service', date: 'Requested date' },
  cart: { quantity: 'Quantity' }, long: { destination: 'Destination', arrival: 'Arrival date',
    travel: 'Travel mode', reference: 'Reference label', attendee: 'Attendee alias',
    seat: 'Seat preference', access: 'Accessibility note', ticket: 'Ticket tier',
    meal: 'Meal preference', session: 'Session track', venue: 'Venue wing',
    reminder: 'Reminder', summary: 'Summary title', timezone: 'Time zone',
    contact: 'Contact alias', confirm: 'Review status' },
  'challenge-31': { location: 'Location', service: 'Service', date: 'Requested date', summary: 'Confirmation label' },
  'challenge-33': { service: 'Service' },
};
const labelsFor = fieldLabels[task.id] ?? fieldLabels[task.category] ?? {};
const browser = createCamofoxBrowser({ baseUrl: camofoxUrl, userId, accessKey: key });
const trace = [];
const metric = event => trace.push({ metric: event });
let lastSnapshot;
const safePath = url => {
  const parsed = new URL(url);
  if (parsed.origin !== new URL(baseUrl).origin || !parsed.pathname.startsWith(`/run/${runId}/${task.id}/`))
    throw Error('non_fixture_url');
  return parsed.pathname.split('/').at(-1);
};
const cleanSnapshot = snapshot => ({ route: safePath(snapshot.url),
  ax: snapshot.snapshot.split('\n').filter(line => !/passphrase|password|credential|token/i.test(line)).join('\n').slice(0, 12000),
  structure: { ...snapshot.structure, forms: snapshot.structure?.forms?.map(form => ({ ...form,
    fields: form.fields?.filter(field => !/password|passphrase|credential|token/i.test(`${field.label} ${field.name} ${field.type}`)) })) } });
const automaticDiagnostic = action => {
  if (!lastSnapshot) return { reason: 'snapshot_unavailable' };
  const nodes = extractAx(lastSnapshot.snapshot);
  const fields = mapFields(lastSnapshot.structure, nodes).map(({ field, ref }) => ({
    name: field.name, label: field.label, ref, value: field.value, context: nodes.find(n => n.ref === ref)?.context,
  }));
  for (const node of nodes.filter(n => n.role === 'spinbutton' && !fields.some(f => f.ref === n.ref)))
    fields.push({ name: '', label: node.name, ref: node.ref, value: node.value, context: node.context });
  const state = { url: lastSnapshot.url, title: lastSnapshot.snapshot.match(/^\s*- heading "([^"]+)"/m)?.[1] ?? '',
    text: lastSnapshot.snapshot.includes('Page 2 of 2') ? 'Page 2 of 2' : '', fields };
  const expected = intendedAction({ state, choices: [] }, task).intended;
  const observed = fields.find(f => f.ref === action.ref);
  const actualValue = action.text ?? action.option;
  const matches = expected?.operation === 'field' && observed &&
    (observed.name === expected.variable || observed.label.toLowerCase().startsWith(expected.label.toLowerCase())) &&
    (!expected.context || observed.context?.includes(expected.context)) && actualValue === expected.value;
  return { expected, actual: { ref: action.ref, label: observed?.label ?? null, value: actualValue },
    agrees: Boolean(matches), reason: !observed ? 'ref_not_observed' : matches ? 'matches_intended' : 'different_field_or_value' };
};
const observed = { ...browser, async snapshot(...args) {
  const result = await browser.snapshot(...args);
  lastSnapshot = result;
  trace.push({ snapshot: cleanSnapshot(result), snapshot_bytes: Buffer.byteLength(JSON.stringify(result)) });
  return result;
}, ...Object.fromEntries(['click', 'type', 'select', 'scroll'].map(operation => [operation,
  async (id, action, options) => {
    trace.push({ action: { operation, ref: action.ref, option: action.option,
      ...(operation === 'type' && { value: action.text }), direction: action.direction },
    ...(applyPrepared && ['type', 'select'].includes(operation) && { automatic_diagnostic: automaticDiagnostic(action) }) });
    return browser[operation](id, action, options);
  }])) };
let tabId, model, result, errorKind, requestSummary;
try {
  const created = await fetch(`${camofoxUrl}/tabs`, { method: 'POST',
    headers: { Authorization: `Bearer ${key}`, 'content-type': 'application/json' },
    body: JSON.stringify({ userId, sessionKey: userId, url: startUrl }), signal: AbortSignal.timeout(30000) });
  if (!created.ok) throw Error('create_tab_failed');
  tabId = (await created.json()).tabId;
  if (!/^[\w-]{1,128}$/.test(tabId)) throw Error('invalid_tab');
  model = backend === 'oracle' ? null : createDecisionBridge({ executable, backend,
    callMs: configuration.modelCallMs, history, representation, onMetric: metric });
  const vars = Object.fromEntries(Object.entries(task.variables).map(([k, v]) => [k, String(v)]));
  if (task.category === 'forms') {
    vars.location = vars.target;
    delete vars.target;
  }
  const bindings = Object.fromEntries(Object.entries(labelsFor)
    .filter(([name]) => Object.hasOwn(vars, name)));
  if (bindingOverride) bindings.service = 'Shipping speed';
  const request = { tabId, goal: task.goal, variables: vars,
    ...(successMode === 'whole' && { success: task.id === 'challenge-31' ?
      { textIncludes: successContract === 'weak-completed' ? 'Completed:' : 'Receipt verified' } :
      task.id === 'challenge-32' || task.id === 'challenge-33' ? { textIncludes: 'Final demo request accepted.' } : task.category === 'cart' ?
      { textIncludes: `Cart contents: ${vars.target} × ${vars.quantity}` } :
      { textIncludes: 'Completed:' } }) };
  requestSummary = { goal: request.goal, variables: request.variables, success: request.success ?? null,
    bindings: candidateMode === 'strictBindings' ? bindings : null,
    modelGoal: modelGoalMode === 'concise' ? conciseGoals[task.category] : null };
  const policy = async (input, options) => {
    const diagnostic = intendedAction(input, task);
    const decision = { state: input.state, choices: input.choices, diagnostic,
      decision_input_bytes: Buffer.byteLength(JSON.stringify(input)) };
    trace.push({ decision }); // Preserve the candidate gap even when the bridge rejects input.
    try {
      const answer = backend === 'oracle' ? (() => {
        const choice = diagnostic.selected ?? input.choices.find(c => c.startsWith('ESCALATE '));
        if (!choice) throw Error('no_safe_oracle_choice');
        return { choice, probabilities: Object.fromEntries(input.choices.map(c => [c, Number(c === choice)])), latency_ms: 0 };
      })() : await model(input, options);
      decision.probabilities = answer.probabilities;
      decision.choice = answer.choice;
      return answer;
    } catch (error) {
      decision.model_error_kind = String(error.message ?? 'unknown').slice(0, 80);
      throw error;
    }
  };
  result = await executeBrowser(request, { browser: observed, decide: policy, telemetry: metric,
    maxSteps: horizon, timeoutMs: configuration.timeoutMs,
    threshold: configuration.threshold, margin: configuration.margin,
    candidateMode, applyPrepared, stopPolicy,
    ...(candidateMode === 'strictBindings' && { bindings }),
    ...(modelGoalMode === 'concise' && { modelGoal: conciseGoals[task.category] }) });
} catch (error) {
  errorKind = error.message?.slice(0, 80) ?? 'unknown';
} finally {
  try { await model?.close(); } catch { errorKind ??= 'model_close_failed'; }
  if (tabId) {
    try {
      await fetch(`${camofoxUrl}/tabs/${tabId}?${new URLSearchParams({ userId })}`, {
        method: 'DELETE', headers: { Authorization: `Bearer ${key}` }, signal: AbortSignal.timeout(8000) });
    } catch { /* disposable container will be destroyed by the orchestrator */ }
  }
}
writeFileSync(outputFile, JSON.stringify({ task: task.id, backend, horizon, successMode, runId,
  configuration, request: requestSummary, result_bytes: Buffer.byteLength(JSON.stringify(result ?? null)),
  elapsed_ms: Math.round(performance.now() - started),
  model_calls: trace.filter(row => row.decision).length,
  local_actions: trace.filter(row => row.action).length,
  hidden_snapshots: trace.filter(row => row.snapshot).length,
  snapshot_bytes_total: trace.reduce((sum, row) => sum + (row.snapshot_bytes ?? 0), 0),
  source: createHash('sha256').update(readFileSync(new URL('../core.mjs', import.meta.url))).digest('hex'),
  result, errorKind, trace }) + '\n', { mode: 0o600 });
console.log(JSON.stringify({ task: task.id, backend, horizon, successMode, result, errorKind,
  decisions: trace.filter(e => e.decision).length }));
