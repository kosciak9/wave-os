import { randomUUID } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { executeSemanticBrowser } from '../core.mjs';
import { createCamofoxBrowser } from '../camofox.mjs';

const [specPath, resultPath] = process.argv.slice(2);
const spec = JSON.parse(readFileSync(specPath, 'utf8'));
const userId = randomUUID(), runId = randomUUID();
const browser = createCamofoxBrowser({ baseUrl: spec.camofoxUrl, userId, accessKey: process.env.CAMOFOX_ACCESS_KEY });
const actions = [], boundaries = [];
const observed = { ...browser, ...Object.fromEntries(['click', 'type', 'select', 'scroll'].map(kind => [kind,
  async (...args) => { actions.push(kind); return browser[kind](...args); }])) };
const safeResult = result => ({ status: result.status, reason: result.reason, steps: result.steps,
  problem: result.problem && { kind: result.problem.kind, field: result.problem.field,
    context: result.problem.context, options: result.problem.options?.map(o => ({ label: o.label, value: o.value })),
    evidence: result.problem.evidence }, continuation: !!result.continuation_id });
const policy = async input => {
  const choice = input.choices.find(c => /^CLICK link "Open (?:Harbor Studio|inquiry modal|confirmation)"/.test(c)) ??
    input.choices.find(c => /^CLICK button (?:"Search"|"Continue"|"Confirm|"Send)/.test(c)) ??
    input.choices.find(c => /^STOP /.test(c)) ?? input.choices.find(c => /^ESCALATE /.test(c));
  if (!choice) throw Error('no_local_choice');
  return { choice, probabilities: Object.fromEntries(input.choices.map(c => [c, Number(c === choice)])), latency_ms: 0 };
};
const opts = { browser: observed, decide: policy, maxSteps: 8, timeoutMs: 120000,
  semanticBoundary: 'adaptive', threshold: 0.5, margin: 0.05,
  telemetry: event => { if (event.event === 'boundary') boundaries.push(event.reason); } };
const record = { task: spec.task.id, arm: spec.arm, model: spec.model, repetition: spec.repetition,
  ...(spec.study === 'h12' ? { snapshot_exposed: false } : { controlled_field_manifest_exposed: true }),
  hosted_controller: 'direct-openrouter-http-no-openclaw', local_policy: 'fixed-oracle-navigation' };
let tabId;
try {
  const response = await fetch(`${spec.camofoxUrl}/tabs`, { method: 'POST', headers: {
    Authorization: `Bearer ${process.env.CAMOFOX_ACCESS_KEY}`, 'content-type': 'application/json' },
  body: JSON.stringify({ userId, sessionKey: userId, url: `${spec.baseUrl}/run/${runId}/${spec.task.id}/start` }) });
  if (!response.ok) throw Error('tab_creation_failed');
  tabId = (await response.json()).tabId;
  if (!/^[\w-]{1,128}$/.test(tabId)) throw Error('invalid_tab');
  if (spec.study === 'h12') {
    const paused = await executeSemanticBrowser({ tabId, goal: spec.task.goal, facts: spec.task.variables }, opts);
    record.pause = safeResult(paused);
    if (spec.arm === 'mapping_diagnostic') {
      record.hosted_calls = 0;
    } else {
    if (paused.status !== 'needs_decision' || !paused.continuation_id || !paused.problem?.options?.length)
      throw Error('initial_needs_decision_not_observed');
    // Only bounded, selected synthetic evidence crosses the hosted boundary. The native snapshot stays local.
    const problem = { kind: paused.status, field: paused.problem.field, context: paused.problem.context,
      expected_fact_key: paused.problem.expected_fact_key,
      options: paused.problem.options.map(({ label, value }) => ({ label, value })) };
    if (spec.arm === 'compact') {
      delete problem.context;
      delete problem.field;
      delete problem.expected_fact_key;
    }
    if (spec.arm === 'original') problem.evidence = paused.problem.evidence ?? null;
    if (spec.arm === 'selected' || spec.arm === 'stale') {
      const snapshot = (await browser.snapshot(tabId)).snapshot;
      const price = /Standard: (\d+) per guest\. Quiet: (\d+) per guest plus a (\d+) booking fee\./.exec(snapshot);
      if (spec.task.id === 'challenge-55' && !price) throw Error('price_evidence_not_observed');
      problem.observed_evidence = price ? [`Standard ${price[1]} per guest`, `Quiet ${price[2]} per guest plus ${price[3]} booking fee`] :
        spec.task.id === 'challenge-63' && snapshot.includes('Sidebar policy: Quiet is listed, but no user preference was supplied.') ?
          ['Sidebar policy: Quiet is listed, but no user preference was supplied.'] :
          spec.task.id === 'challenge-62' ? ['Garden Room and Side Hall both show Room tier options; only Garden Room is the requested context.'] : [];
    }
    if (spec.arm === 'structured') {
      const snapshot = (await browser.snapshot(tabId)).snapshot;
      const price = /Standard: (\d+) per guest\. Quiet: (\d+) per guest plus a (\d+) booking fee\./.exec(snapshot);
      if (spec.task.id === 'challenge-55' && !price) throw Error('price_evidence_not_observed');
      problem.observed_evidence = price ? { prices: { Standard: { per_guest: Number(price[1]), fee: 0 },
        Quiet: { per_guest: Number(price[2]), fee: Number(price[3]) } }, guests: Number(spec.task.variables.party) } :
        { preference_supplied: false, sidebar_mentions_quiet: spec.task.id === 'challenge-63' &&
          snapshot.includes('Sidebar policy: Quiet is listed, but no user preference was supplied.') };
    }
    process.stdout.write(JSON.stringify({ goal: spec.task.goal, facts: spec.task.variables, problem }) + '\n');
    const reader = createInterface({ input: process.stdin, crlfDelay: Infinity });
    let timer;
    let line;
    try {
      line = await Promise.race([new Promise(resolve => reader.once('line', resolve)),
        new Promise((_, reject) => { timer = setTimeout(() => reject(Error('hosted_reply_timeout')), 100000); })]);
    } finally { clearTimeout(timer); reader.close(); }
    const reply = JSON.parse(line);
    if (!reply || typeof reply !== 'object' || Array.isArray(reply) ||
        !(Object.keys(reply).length === 1 && reply.action === 'ask' ||
          Object.keys(reply).length === 2 && reply.action === 'choose' &&
          problem.options.some(o => o.value === reply.option))) throw Error('invalid_hosted_answer');
    record.answer = reply.action === 'ask' ? { action: 'ask' } : { action: 'choose', option: reply.option };
    if (reply.action === 'choose' && problem.options.some(o => o.value === reply.option)) {
      if (spec.arm === 'stale') {
        const snapshot = (await browser.snapshot(tabId)).snapshot;
        const ref = /- link "Refresh prices" \[(e\d+)\]/.exec(snapshot)?.[1];
        if (!ref) throw Error('refresh_link_not_observed');
        await browser.click(tabId, { ref });
        record.external_fixture_change = 'refresh_prices_after_hosted_choice';
      }
      const before = actions.length;
      record.resume = safeResult(await executeSemanticBrowser({ continuation_id: paused.continuation_id,
        new_facts: { [paused.problem.field]: reply.option } }, opts));
      record.resume_actions = actions.length - before;
    }
    }
  } else {
    const { contract } = spec;
    const request = { tabId, goal: spec.task.goal,
      facts: spec.arm === 'procedural' ? contract.variables : contract.facts,
      ...(contract.bindings && { bindings: contract.bindings }) };
    record.adapter = spec.arm === 'procedural' ? 'lossless_variables_to_facts' : 'identity_facts';
    record.held_constant = { executor: 'semantic', boundary: 'adaptive', max_steps: 8,
      decision_policy: 'fixed-oracle-navigation', success: 'fixture_oracle_not_caller_success' };
    record.contract = contract;
    record.result = safeResult(await executeSemanticBrowser(request, opts));
  }
} catch (error) { record.error = /^[a-z_]+$/.test(error.message) ? error.message : 'local_execution_error'; }
finally {
  if (tabId) try { await fetch(`${spec.camofoxUrl}/tabs/${tabId}?${new URLSearchParams({ userId })}`, {
    method: 'DELETE', headers: { Authorization: `Bearer ${process.env.CAMOFOX_ACCESS_KEY}` } }); } catch { /* disposable tab */ }
}
record.runId = runId;
record.actions = actions;
record.boundaries = boundaries;
writeFileSync(resultPath, JSON.stringify(record), { mode: 0o600 });
