import { randomUUID, createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { executeBrowser, executeSemanticBrowser, extractAx } from '../core.mjs';
import { createCamofoxBrowser } from '../camofox.mjs';
import { createDecisionBridge } from '../bridge.mjs';

const [input, output] = process.argv.slice(2);
const { task, baseUrl, camofoxUrl, backend, executable, mode, boundary, variant } = JSON.parse(readFileSync(input, 'utf8'));
const userId = randomUUID(), runId = randomUUID();
const browser = createCamofoxBrowser({ baseUrl: camofoxUrl, userId, accessKey: process.env.CAMOFOX_ACCESS_KEY });
const actions = [], decisions = [], boundaries = [], stages = [];
const observed = { ...browser, async snapshot(...args) {
  const snapshot = await browser.snapshot(...args);
  if (variant === 'entry38' && !stages.some(stage => stage.route === new URL(snapshot.url).pathname.split('/').at(-1)))
    stages.push({ route: new URL(snapshot.url).pathname.split('/').at(-1),
      title: /- heading "([^"]+)"/.exec(snapshot.snapshot)?.[1] ?? null,
      controls: extractAx(snapshot.snapshot).filter(n => ['button', 'link'].includes(n.role)).slice(0, 8)
        .map(n => ({ role: n.role, label: n.name.slice(0, 100) })),
      fields: snapshot.structure?.forms?.flatMap(f => f.fields ?? []).slice(0, 8)
        .map(f => f.label?.slice(0, 100)) ?? [] });
  return snapshot;
}, ...Object.fromEntries(['click', 'type', 'select', 'scroll'].map(kind => [kind,
  async (...args) => { actions.push(kind); return browser[kind](...args); }])) };
let tabId, model;
const facts = { ...task.variables, ...(variant === 'receipt-remaining' && { future_review_label: 'Future label' }) };
const bindings = Object.fromEntries(Object.keys(facts).map(key => [key, ({ location: 'Location', service: 'Service',
  date: 'Requested date', summary: 'Confirmation label', party: 'Guests' })[key] ?? key]));
if (task.id === 'challenge-55') bindings.party = 'Guests';
const selectLocal = choices => choices.find(c => /^CLICK link "Open (?:Harbor Studio|inquiry modal|confirmation)"/.test(c)) ??
  choices.find(c => /^CLICK button "(?:Search|Send|Confirm|Finish|Continue)/.test(c)) ??
  choices.find(c => /^STOP /.test(c)) ?? choices.find(c => /^ESCALATE /.test(c));
const policy = async (input, options) => {
  const answer = backend === 'local-oracle-policy' ? (() => {
    const choice = selectLocal(input.choices);
    if (!choice) throw Error('local_policy_no_choice');
    return { choice, probabilities: Object.fromEntries(input.choices.map(c => [c, Number(c === choice)])), latency_ms: 0 };
  })() : await model(input, options);
  decisions.push({ kind: answer.choice?.split(' ')[0] ?? 'error', candidates: input.choices.length });
  return answer;
};
const opts = { browser: observed, decide: policy, maxSteps: 8, timeoutMs: 120000, semanticBoundary: boundary,
  threshold: 0.5, margin: 0.05, telemetry: event => { if (event.event === 'boundary') boundaries.push(event.reason); } };
const compact = result => ({ status: result.status, reason: result.reason, steps: result.steps,
  problem: result.problem && { kind: result.problem.kind, field: result.problem.field,
    context: result.problem.context ?? null, candidates: result.problem.candidates?.length ?? 0,
    options: result.problem.options?.map(o => o.label) ?? [] },
  progress: result.progress && { assignments_verified: result.progress.assignments_verified,
    pages_seen: result.progress.pages_seen, remaining_facts: result.progress.remaining_facts ??
      result.progress.remaining_fact_keys?.length } });
const execute = (request, config = opts) => mode === 'procedural' ? executeBrowser(request, {
  ...config, candidateMode: 'strictBindings', applyPrepared: true }) : executeSemanticBrowser(request, config);
const record = { task: task.id, backend, mode, boundary, variant, policy: backend === 'local-oracle-policy' ?
  'local-control-not-hosted' : 'native-executable-not-hosted', hosted: false };
try {
  const response = await fetch(`${camofoxUrl}/tabs`, { method: 'POST', headers: {
    Authorization: `Bearer ${process.env.CAMOFOX_ACCESS_KEY}`, 'content-type': 'application/json' },
  body: JSON.stringify({ userId, sessionKey: userId, url: `${baseUrl}/run/${runId}/${task.id}/start` }) });
  if (!response.ok) throw Error('tab_creation_failed');
  tabId = (await response.json()).tabId;
  if (!/^[\w-]{1,128}$/.test(tabId)) throw Error('invalid_tab');
  if (backend !== 'local-oracle-policy') model = createDecisionBridge({ executable, backend, callMs: 20000 });
  if (variant === 'entry38') {
    const first = await browser.snapshot(tabId);
    const controls = extractAx(first.snapshot).filter(n => ['button', 'link'].includes(n.role));
    record.entry = { route: new URL(first.url).pathname.split('/').at(-1),
      title: /<title>([^<]*)<\/title>/.exec(first.snapshot)?.[1] ??
        /- heading "([^"]+)"/.exec(first.snapshot)?.[1] ?? null,
      controls: controls.slice(0, 8).map(n => ({ role: n.role, label: n.name.slice(0, 100) })),
      fields: first.structure?.forms?.flatMap(f => f.fields ?? []).slice(0, 8).map(f => f.label?.slice(0, 100)) ?? [] };
  }
  const request = { tabId, goal: task.goal, ...(mode === 'procedural' ? {
    variables: facts, bindings, success: { textIncludes: 'Final demo request accepted.' } } : {
    facts, ...(mode === 'semantic-bound' && { bindings }) }) };
  if (variant === 'reprice-recover') {
    if (task.id !== 'challenge-55' || backend !== 'local-oracle-policy' || mode !== 'semantic' || boundary !== 'adaptive')
      throw Error('invalid_recovery_case');
    const first = await execute(request);
    record.pause = compact(first);
    if (first.status !== 'needs_decision' || !first.continuation_id || first.problem?.options?.length !== 2)
      throw Error('initial_pause_missing');
    const before = await browser.snapshot(tabId);
    if (!before.snapshot.includes('Standard: 45 per guest. Quiet: 35 per guest plus a 5 booking fee.'))
      throw Error('initial_prices_missing');
    const refresh = extractAx(before.snapshot).find(n => n.role === 'link' && n.name === 'Refresh prices');
    if (!refresh) throw Error('refresh_link_not_observed');
    await browser.click(tabId, { ref: refresh.ref });
    record.external_fixture_change = 'refresh_prices';
    const repriced = await browser.snapshot(tabId);
    if (!repriced.snapshot.includes('Standard: 30 per guest. Quiet: 35 per guest plus a 5 booking fee.'))
      throw Error('new_prices_missing');
    record.price_labels = { first: 'Standard 45; Quiet 35 + 5 fee', current: 'Standard 30; Quiet 35 + 5 fee' };
    const original = { continuation_id: first.continuation_id, new_facts: { [first.problem.field]: 'Quiet' } };
    const staleActions = actions.length;
    record.stale = compact(await execute(original));
    record.stale_actions = actions.length - staleActions;
    if (record.stale.reason !== 'continuation_stale' || record.stale_actions !== 0)
      throw Error('old_token_not_rejected');
    const second = await execute(request);
    record.reobserve = compact(second);
    record.fresh_handoff = second.status === 'needs_decision' && !!second.continuation_id &&
      second.continuation_id !== first.continuation_id && second.problem?.field === first.problem.field;
    if (!record.fresh_handoff) throw Error('fresh_pause_missing');
    const freshActions = actions.length;
    record.fresh_resume = compact(await execute({ continuation_id: second.continuation_id,
      new_facts: { [second.problem.field]: 'Standard' } }));
    record.fresh_resume_actions = actions.length - freshActions;
    record.local_choice = 'Standard';
  } else if (variant === 'no-preference' || variant === 'resume' || variant.startsWith('resume-')) {
    // The user's price decision is intentionally not in the initial facts.
    const paused = await execute(request);
    record.pause = compact(paused);
    if (variant !== 'no-preference' && paused.continuation_id) {
      const followup = { continuation_id: paused.continuation_id, new_facts: { [paused.problem.field]: 'Quiet' } };
      record.frozen_payload_sha256 = createHash('sha256').update(JSON.stringify(followup)).digest('hex');
      if (variant === 'resume-stale') {
        const snapshot = await browser.snapshot(tabId);
        const ref = /- link "Refresh prices" \[(e\d+)\]/.exec(snapshot.snapshot)?.[1];
        if (!ref) throw Error('refresh_link_not_observed');
        await browser.click(tabId, { ref });
        record.external_fixture_change = 'refresh_prices';
      }
      if (variant === 'resume-refchurn') {
        const before = await browser.snapshot(tabId);
        const button = extractAx(before.snapshot).find(n => n.role === 'button' && n.name === 'Renew controls');
        const selected = extractAx(before.snapshot).find(n => n.role === 'combobox' && n.name.startsWith('Room tier'));
        if (!button || !selected) throw Error('refchurn_control_not_observed');
        await browser.click(tabId, { ref: button.ref });
        const after = await browser.snapshot(tabId);
        const replacement = extractAx(after.snapshot).find(n => n.role === 'combobox' && n.name.startsWith('Room tier'));
        record.external_fixture_change = 'replace_identical_select_dom';
        record.ref_changed = !!replacement && selected.ref !== replacement.ref;
        record.url_changed = before.url !== after.url;
      }
      if (variant === 'resume-wrong-fact') followup.new_facts = { 'Other field': 'Quiet' };
      const beforeResume = actions.length;
      if (variant === 'resume-wrong-scope') {
        const other = { ...observed, scopeId: `${observed.scopeId}:other-tenant` };
        record.resume = compact(await execute(followup, { ...opts, browser: other }));
      } else record.resume = compact(await execute(followup));
      record.resume_actions = actions.length - beforeResume;
      if (variant === 'resume-replay') record.replay = compact(await execute(followup));
    }
  } else record.result = compact(await execute(request));
} catch (error) { record.error = String(error.message).replace(/[^a-zA-Z0-9_-]/g, '_').slice(0, 80); }
finally {
  try { await model?.close(); } catch { /* transport teardown */ }
  if (tabId) try { await fetch(`${camofoxUrl}/tabs/${tabId}?${new URLSearchParams({ userId })}`, {
    method: 'DELETE', headers: { Authorization: `Bearer ${process.env.CAMOFOX_ACCESS_KEY}` } }); } catch { /* disposable tab */ }
}
record.runId = runId; // Only the orchestrator reads this temporary file to query the hidden oracle.
record.actions = actions.length;
record.actionKinds = actions;
record.decisions = decisions.length;
record.decisionKinds = decisions.map(d => d.kind);
record.boundaries = boundaries;
if (variant === 'entry38') record.stages = stages;
writeFileSync(output, JSON.stringify(record), { mode: 0o600 });
