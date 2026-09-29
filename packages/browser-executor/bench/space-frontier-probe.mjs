import { createHash, randomUUID } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { isDeepStrictEqual } from 'node:util';
import { pathToFileURL } from 'node:url';
import { createCamofoxBrowser } from '../camofox.mjs';
import { createDecisionBridge, nativeRequest } from '../bridge.mjs';

const [mode, inputPath, outputPath] = process.argv.slice(2);
const spec = JSON.parse(readFileSync(inputPath, 'utf8'));
const digest = value => createHash('sha256').update(value).digest('hex');
const hash = path => digest(readFileSync(path));
const write = value => writeFileSync(outputPath, JSON.stringify(value), { mode: 0o600, flag: 'wx' });
const kinds = ['first_form', 'first_receipt', 'intermediate_receipt', 'final_receipt', 'branch_choice'];
const variantChoices = (choices, stop) => choices.filter(c => stop || !c.startsWith('STOP '));
const safeChoice = choice => ({ kind: choice.split(' ')[0], label:
  /^CLICK (?:button|link) "([^"\n]+)"/.exec(choice)?.[1] ?? null });

if (mode === 'capture') {
  const { task, corePath, expectedCoreHash, baseUrl, camofoxUrl } = spec;
  if (hash(corePath) !== expectedCoreHash) throw Error('core_hash_mismatch');
  const { executeSemanticBrowser } = await import(pathToFileURL(corePath).href);
  const userId = randomUUID(), runId = randomUUID();
  const browser = createCamofoxBrowser({ baseUrl: camofoxUrl, userId, accessKey: process.env.CAMOFOX_ACCESS_KEY });
  let tabId;
  const records = [];
  try {
    const created = await fetch(`${camofoxUrl}/tabs`, { method: 'POST', headers: {
      Authorization: `Bearer ${process.env.CAMOFOX_ACCESS_KEY}`, 'content-type': 'application/json' },
    body: JSON.stringify({ userId, sessionKey: userId, url: `${baseUrl}${task.start_path.replace('{runId}', runId)}` }),
    signal: AbortSignal.timeout(30000) });
    if (!created.ok) throw Error('tab_creation_failed');
    tabId = (await created.json()).tabId;
    if (!/^[\w-]{1,128}$/.test(tabId)) throw Error('invalid_tab');
    const goal = task.goal.split(' Facts:')[0];
    const request = { tabId, goal, facts: task.variables,
      constraints: { allowedOrigins: [new URL(baseUrl).origin], forbidActions: [] } };
    const decide = async (input, { signal } = {}) => {
      if (signal?.aborted) throw Error('aborted');
      const { state, choices } = input;
      const clicks = choices.filter(c => c.startsWith('CLICK '));
      const stop = choices.find(c => c.startsWith('STOP '));
      const title = state.title.toLowerCase();
      const stage = Number(/(?:stage|receipt) (\d+) of 12/i.exec(state.title)?.[1]);
      const isForm = title.includes('archive inquiry stage');
      const isReceipt = title.includes('details receipt');
      const isFinal = title.includes('final receipt');
      const isBranch = title.includes('choose archive directory');
      const label = task.id === 'space-01' && isForm && stage === 1 ? 'first_form' :
        task.id === 'space-01' && isReceipt && stage === 1 ? 'first_receipt' :
        isReceipt && stage === 5 && task.id === 'space-01' ? 'intermediate_receipt' :
        isFinal ? 'final_receipt' : isBranch ? 'branch_choice' : null;
      if (label) {
        if (records.some(r => r.label === label)) throw Error('duplicate_probe');
        if (!stop) throw Error('stop_not_offered');
        const exact = structuredClone({ state, choices });
        // Same callback state as the bridge (default history=2, representation=full).
        const requestByStop = Object.fromEntries([true, false].map(offered => {
          const subset = variantChoices(exact.choices, offered);
          return [offered ? 'with_stop' : 'without_stop', nativeRequest({ ...exact.state,
            recent: exact.state.recent.slice(-2) }, subset)];
        }));
        records.push({ label, input: exact, native_requests: requestByStop });
      }
      let choice;
      if (isFinal || isBranch && task.id === 'space-02') choice = stop;
      else if (isForm) choice = clicks.length === 1 ? clicks[0] : null;
      else if (isReceipt) choice = clicks.length === 1 ? clicks[0] : null;
      else throw Error('unexpected_page');
      if (!choice) throw Error('nonunique_navigation');
      return { choice, probabilities: Object.fromEntries(choices.map(c => [c, Number(c === choice)])), latency_ms: 0 };
    };
    const result = await executeSemanticBrowser(request, { browser, decide, maxSteps: 128,
      timeoutMs: 240000, semanticBoundary: 'none', threshold: 0.5, margin: 0.05 });
    const wanted = task.id === 'space-01' ? kinds.slice(0, 4) : ['branch_choice'];
    if (result.reason !== 'model_stop' || JSON.stringify(records.map(r => r.label)) !== JSON.stringify(wanted))
      throw Error(`capture_incomplete_${result.reason ?? 'unknown'}_${records.map(r => r.label).join('_')}`);
    write({ task: task.id, records, result: { status: result.status, reason: result.reason,
      steps: result.steps }, runId });
  } finally {
    if (tabId) try { await fetch(`${camofoxUrl}/tabs/${tabId}?${new URLSearchParams({ userId })}`, {
      method: 'DELETE', headers: { Authorization: `Bearer ${process.env.CAMOFOX_ACCESS_KEY}` },
      signal: AbortSignal.timeout(8000) }); } catch { /* ephemeral tab */ }
  }
} else if (mode === 'local') {
  const { frozen, executable } = spec;
  const bridge = createDecisionBridge({ executable, backend: 'laya', callMs: 20000 });
  const rows = [];
  try {
    for (const record of frozen) for (const stop of [true, false]) {
      const choices = variantChoices(record.input.choices, stop);
      const key = stop ? 'with_stop' : 'without_stop';
      if (!isDeepStrictEqual(nativeRequest({ ...record.input.state,
        recent: record.input.state.recent.slice(-2) }, choices), record.native_requests[key]))
        throw Error('native_request_drift');
      try {
        const answer = await bridge({ ...record.input, choices });
        const ranked = choices.toSorted((a, b) => answer.probabilities[b] - answer.probabilities[a]);
        const ops = record.native_requests[key].questions;
        rows.push({ label: record.label, arm: key, selected: safeChoice(answer.choice),
          selected_index: choices.indexOf(answer.choice), confidence: answer.probabilities[ranked[0]],
          margin: answer.probabilities[ranked[0]] - answer.probabilities[ranked[1]],
          top2: ranked.slice(0, 2).map(choice => ({ index: choices.indexOf(choice),
            ...safeChoice(choice), probability: answer.probabilities[choice] })),
          operation_count: Object.keys(ops.operation.criteria).length,
          target_counts: Object.fromEntries(Object.entries(ops).filter(([k]) => k !== 'operation')
            .map(([k, v]) => [k, Object.keys(v.criteria).length])) });
      } catch (error) {
        rows.push({ label: record.label, arm: key, error: /^[a-z_]+$/.test(error.message) ? error.message : 'local_error' });
      }
    }
  } finally { await bridge.close(); }
  write(rows);
} else throw Error('invalid_mode');
