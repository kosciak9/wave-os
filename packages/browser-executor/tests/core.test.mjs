import test from 'node:test';
import assert from 'node:assert/strict';
import { executeBrowser, extractAx, mapFields, recoverBrowserTab, browserTabMutationAllowed,
  reserveBrowserTabMutation } from '../core.mjs';
import { createCamofoxBrowser } from '../camofox.mjs';
import { registerBrowserExecutor, registerHybridBrowserExecutor, registerScopedSelect } from '../plugin.mjs';

const url = 'https://fixture.example/form';
const base = (value = '', extra = {}) => ({ url, snapshot: `- main:\n  - heading "Demo" [level=1]\n  - text: Search\n  - textbox "Search" [e1]${value ? `: ${value}` : ''}\n  - button "Submit" [e2]`,
  structure: { forms: [{ fields: [{ label: 'Search', name: 'q', tag: 'input', type: 'text', role: 'textbox', value, disabled: false }] }] }, ...extra });
const request = { goal: 'Search', tabId: 'tab1', variables: { search: 'found' }, success: { urlPath: '/done' } };
const pick = predicate => async ({ choices }) => {
  const choice = choices.find(predicate);
  return { choice, probabilities: Object.fromEntries(choices.map(c => [c, c === choice ? 1 : 0])), latency_ms: 12 };
};
let testScope = 0;
const run = (browser, decide = pick(c => c.startsWith('TYPE')), req = request, opts = {}) => executeBrowser(req,
  { browser: browser.scopeId ? browser : { ...browser, scopeId: `synthetic-test-${++testScope}` }, decide, ...opts });

test('AX refs retain heading context for duplicate buttons and never invent refs', () => {
  const nodes = extractAx('- main:\n  - heading "First item" [level=2]\n  - button "Add to cart" [e1]\n  - heading "Second item" [level=2]\n  - button "Add to cart" [e2]');
  assert.equal(nodes[0].context, 'First item');
  assert.equal(nodes[1].context, 'Second item');
});

test('structure select labels concatenating options map only to unique AX name', () => {
  const field = { label: 'Service standardexpress', role: 'combobox', tag: 'select', options: [{ label: 'standard' }, { label: 'express' }] };
  assert.equal(mapFields({ forms: [{ fields: [field] }] }, [{ role: 'combobox', name: 'Service', ref: 'e3' }])[0].ref, 'e3');
  assert.equal(mapFields({ forms: [{ fields: [field, { ...field }] }] }, [{ role: 'combobox', name: 'Service', ref: 'e3' }])[0].ref, null);
  assert.equal(mapFields({ forms: [{ fields: [field] }] }, [{ role: 'combobox', name: 'Service', ref: 'e3' }, { role: 'combobox', name: 'Service', ref: 'e4' }])[0].ref, null);
});

test('selected native option is omitted; select sends exact observed option value', async () => {
  const snap = selected => ({ url, snapshot: '- combobox "Service" [e3]', structure: { forms: [{ fields: [{ label: 'Service standardexpress', role: 'combobox', tag: 'select', type: 'select', value: selected ? 'exp' : 'std', options: [
    { label: 'standard', value: 'std', selected: !selected }, { label: 'express', value: 'exp', selected },
  ] }] }] } });
  let selected = false, received;
  const browser = { snapshot: async () => snap(selected), select: async (_, action) => { received = action; selected = true; } };
  const outcome = await run(browser, pick(c => c.startsWith('SELECT')), { ...request, variables: { service: 'express' } }, { maxSteps: 1 });
  assert.equal(received.option, 'exp');
  assert.equal(outcome.reason, 'max_steps');
  assert.equal(outcome.steps, 1);
});

test('sensitive fields and values are withheld from decision and telemetry', async () => {
  const snapshot = base('', { snapshot: '- text: Password\n- textbox "Password" [e5]: supersecret\n- textbox "Search" [e1]\n- button "Submit" [e2]',
    structure: { forms: [{ fields: [
      { label: 'Password', name: 'credential', type: 'password', tag: 'input', role: 'textbox', value: 'supersecret' },
      { label: 'Search', name: 'q', type: 'text', tag: 'input', role: 'textbox', value: '' },
    ] }] } });
  const events = [];
  const result = await run({ snapshot: async () => snapshot }, async input => {
    assert.ok(!JSON.stringify(input).includes('supersecret'));
    assert.ok(!JSON.stringify(input).includes('password'));
    return pick(c => c.startsWith('STOP'))(input);
  }, { ...request, goal: 'Do not show supersecret', variables: { ['pass' + 'word']: 'supersecret', search: 'found' } }, { telemetry: event => events.push(event) });
  assert.equal(result.reason, 'sensitive_fields');
  assert.ok(!JSON.stringify(result).includes('supersecret'));
  assert.deepEqual(events, [{ event: 'snapshot', exposed_to_large_model: false },
    { event: 'result', status: 'escalated', reason: 'sensitive_fields', steps: 0 }]);
});

test('success is deterministic only; absent success returns checkpoint, not completed', async () => {
  const b = { snapshot: async () => base() };
  assert.equal((await run(b, pick(c => c.startsWith('STOP')), { ...request, success: undefined, variables: {} })).status, 'checkpoint');
  const entry = await run({ snapshot: async () => ({ ...base(), url: 'https://fixture.example/done' }) });
  assert.equal(entry.status, 'checkpoint');
  assert.equal(entry.reason, 'matched_on_entry');
  assert.deepEqual(entry.matched_conditions, ['urlPath']);
  const done = { url: 'https://fixture.example/done', snapshot: '- heading "Completed" [level=1]', structure: { forms: [] } };
  assert.equal((await run({ snapshot: async () => done }, () => assert.fail('nothing to decide'),
    { ...request, success: undefined })).reason, 'no_actionable_controls');
});

test('invalid distribution, low confidence and incomplete choices escalate', async () => {
  const b = { snapshot: async () => base() };
  assert.equal((await run(b, async () => ({ choice: 'invented', probabilities: {}, latency_ms: 0 }))).reason, 'invalid_model_output');
  assert.equal((await run(b, async ({ choices }) => ({ choice: choices[0], probabilities: Object.fromEntries(choices.map((c, i) => [c, i === 0 ? 0.4 : 0.6 / (choices.length - 1)])), latency_ms: 1 }))).reason, 'uncertain');
  const many = { ...request, variables: Object.fromEntries(Array.from({ length: 32 }, (_, i) => [`v${i}`, `x${i}`])) };
  const bigger = { ...base(), snapshot: `${base().snapshot}\n  - textbox "Second" [e3]`, structure: { forms: [{ fields: [base().structure.forms[0].fields[0], { label: 'Second', name: 'second', tag: 'input', type: 'text', role: 'textbox', value: '' }] }] } };
  assert.equal((await run({ snapshot: async () => bigger }, undefined, many)).reason, 'choice_limit');
  assert.equal((await run(b, undefined, request, { threshold: Number.NaN })).reason, 'invalid_request');
});

test('mutation uses refreshed refs, changed state never mutates stale ref', async () => {
  let n = 0, clicks = 0;
  const b = { snapshot: async () => { n++; return base(n > 1 ? 'changed' : ''); }, type: async () => { clicks++; } };
  const result = await run(b, ({ state, choices }) => pick(c => c.startsWith(state.fields[0].value === 'changed' ? 'ESCALATE' : 'TYPE'))({ choices }), request, { maxSteps: 1 });
  assert.equal(clicks, 0);
  assert.equal(result.status, 'escalated');
});

test('no change, repeated tuple, max steps, origin changes and backend errors escalate', async () => {
  const b = { snapshot: async () => base(), type: async () => {} };
  assert.equal((await run(b)).reason, 'no_state_change');
  assert.equal((await run({ snapshot: async () => { throw Error('offline'); } })).reason, 'backend_or_model_error');
  assert.equal((await run({ snapshot: async () => ({ ...base(), url: 'https://elsewhere.example/' }) }, undefined, { ...request, allowedOrigins: ['https://fixture.example'] }, { maxSteps: 1 })).status, 'escalated');
  let value = '';
  const changing = { snapshot: async () => base(value), type: async (_, action) => { value = action.text; } };
  assert.equal((await run(changing, undefined, request, { maxSteps: 1 })).reason, 'max_steps');
  value = '';
  assert.equal((await run(changing, undefined, { ...request, variables: { a: 'found', b: 'other' } }, { maxSteps: 4 })).reason, 'action_loop');
});

test('timeout, abort and shared scoped-tab lock prevent overlapping mutations', async () => {
  let resolve;
  const pending = new Promise(r => { resolve = r; });
  const b = { scopeId: 'u1', snapshot: () => pending };
  assert.equal(browserTabMutationAllowed(b.scopeId, request.tabId), true);
  const first = run(b, undefined, request, { timeoutMs: 25 });
  assert.equal(browserTabMutationAllowed(b.scopeId, request.tabId), false);
  assert.equal(browserTabMutationAllowed('other-user', request.tabId), true);
  assert.equal((await run(b)).reason, 'tab_busy');
  assert.equal((await first).reason, 'timeout_or_cancelled');
  assert.equal(browserTabMutationAllowed(b.scopeId, request.tabId), true);
  resolve(base());
  const controller = new AbortController(); controller.abort();
  assert.equal((await run(b, undefined, request, { signal: controller.signal })).reason, 'timeout_or_cancelled');
});

test('Camofox adapter bounds HTTP, scope, route, and credential placement', async () => {
  const calls = [];
  const browser = createCamofoxBrowser({ userId: 'scoped', accessKey: 'secret', fetchImpl: async (u, opts) => {
    calls.push([u, opts]); return new Response(JSON.stringify(base()));
  } });
  await browser.snapshot('t1'); await browser.select('t1', { ref: 'e2', option: 'exp' });
  assert.equal(calls[0][0].pathname, '/tabs/t1/snapshot');
  assert.equal(calls[0][0].searchParams.get('includeScreenshot'), 'false');
  assert.deepEqual(JSON.parse(calls[1][1].body), { userId: 'scoped', ref: 'e2', option: 'exp' });
  assert.throws(() => createCamofoxBrowser({ baseUrl: 'http://example.com', userId: 'x', accessKey: 'y' }));
});

test('plugin delegates scope to trusted wrapper, never exposes backend settings as tool parameters', () => {
  let factory;
  registerBrowserExecutor({ registerTool: f => { factory = f; } }, { scope: () => 'hmac-scope', decide: pick(c => c.startsWith('STOP')), accessKey: 'key' });
  const tool = factory({ agentId: 'different-agent' });
  assert.equal(tool.name, 'browser_execute');
  assert.ok(!Object.hasOwn(tool.parameters.properties, 'userId'));
  assert.ok(!Object.hasOwn(tool.parameters.properties, 'baseUrl'));
});

test('hybrid plugin factory accepts trusted packaged executable without exposing it to tool callers', () => {
  let factory;
  const handle = registerHybridBrowserExecutor({ registerTool: f => { factory = f; } }, {
    executable: '/trusted/package/bin/browser-decision',
    scope: () => 'scoped', accessKey: 'key', baseUrl: 'http://127.0.0.1:9377',
  });
  assert.equal(factory({}).name, 'browser_execute');
  assert.ok(!Object.hasOwn(factory({}).parameters.properties, 'executable'));
  handle.close();
});

test('native SELECT tool exposes refs/options but no user identity or backend override', () => {
  let factory;
  registerScopedSelect({ registerTool: f => { factory = f; } }, { scope: () => 'scoped', accessKey: 'key' });
  const tool = factory({});
  assert.equal(tool.name, 'camofox_select');
  assert.deepEqual(Object.keys(tool.parameters.properties), ['tabId', 'ref', 'option']);
});

test('forbidden literal actions and disabled controls cannot be selected', async () => {
  const snap = { ...base(), snapshot: '- button "Checkout" [e1]\n- button "Submit" [e2] [disabled]\n- link "Continue" [e3]' };
  await run({ snapshot: async () => snap }, async ({ choices }) => {
    assert.ok(!choices.some(choice => choice.includes('Checkout') || choice.includes('Submit')));
    assert.ok(choices.some(choice => choice.includes('Continue')));
    return pick(c => c.startsWith('STOP'))({ choices });
  }, { ...request, forbidActions: ['checkout'], variables: {} });
});

test('cross-origin navigation after action escalates without further clicks', async () => {
  let moved = false, clicks = 0;
  const browser = { snapshot: async () => ({ ...base(), snapshot: '- link "Next" [e2]', url: moved ? 'https://other.example/' : url }),
    click: async () => { moved = true; clicks++; } };
  const outcome = await run(browser, pick(c => c.startsWith('CLICK')), { ...request, variables: {} });
  assert.equal(outcome.reason, 'origin_changed');
  assert.equal(clicks, 1);
});

test('truncated fields and ambiguous refs escalate without typing', async () => {
  let types = 0;
  const snap = base();
  snap.structure.forms[0].fieldsTruncated = true;
  assert.equal((await run({ snapshot: async () => snap, type: async () => { types++; } })).reason, 'incomplete_snapshot');
  delete snap.structure.forms[0].fieldsTruncated;
  snap.snapshot += '\n  - textbox "Search" [e3]';
  const result = await run({ snapshot: async () => snap, type: async () => { types++; } }, async ({ choices }) => {
    assert.ok(!choices.some(c => c.startsWith('TYPE')));
    return pick(c => c.startsWith('STOP'))({ choices });
  });
  assert.equal(result.reason, 'unmapped_fields');
  assert.equal(types, 0);
});

test('unmappable editable fields suppress submit buttons, including repeated cart forms', async () => {
  const snap = { url, snapshot: '- heading "First" [level=2]\n- textbox "Quantity" [e1]: 1\n- button "Add to cart" [e2]\n- heading "Second" [level=2]\n- textbox "Quantity" [e3]: 1\n- button "Add to cart" [e4]', structure: { forms: [
    { fields: [{ label: 'Quantity', name: 'quantity', type: 'number', tag: 'input', role: 'textbox', value: '1' }] },
    { fields: [{ label: 'Quantity', name: 'quantity', type: 'number', tag: 'input', role: 'textbox', value: '1' }] },
  ] } };
  const outcome = await run({ snapshot: async () => snap, click: async () => assert.fail('unsafe click') }, async ({ choices }) => {
    assert.ok(!choices.some(c => c.includes('Add to cart')));
    return pick(c => c.startsWith('STOP'))({ choices });
  }, { ...request, variables: { quantity: '2' } });
  assert.equal(outcome.reason, 'unmapped_fields');
});

test('spinbuttons use AX refs and heading context without order-mapping repeated DOM fields', async () => {
  const quantity = value => ({ url, snapshot: `- heading "Demo shop" [level=1]\n  - heading "Stone Notebook" [level=2]\n  - spinbutton "Quantity" [e2]: "1"\n  - button "Add to cart" [e3]\n  - heading "Moss Notebook" [level=2]\n  - spinbutton "Quantity" [e5]: "${value}"\n  - button "Add to cart" [e6]`,
    structure: { forms: [1, 2].map(() => ({ fields: [{ label: 'Quantity', role: 'textbox', tag: 'input', type: 'number', name: 'quantity', value: '1' }] })) } });
  let value = '1', clicks = 0, typed;
  const browser = { snapshot: async () => quantity(value), type: async (_tab, action) => { typed = action; value = action.text; },
    click: async (_tab, action) => { assert.equal(action.ref, 'e6'); clicks++; } };
  const req = { ...request, variables: { target: 'Moss Notebook', quantity: '2' } };
  const answer = async ({ choices }) => {
    assert.ok(!choices.some(c => c.includes('Stone Notebook') && c.startsWith('TYPE')));
    assert.ok(!choices.some(c => c.includes('Stone Notebook') && c.startsWith('CLICK')));
    return pick(c => c.startsWith(value === '1' ? 'TYPE' : 'CLICK'))({ choices });
  };
  const outcome = await run(browser, answer, req, { maxSteps: 2 });
  assert.equal(typed.ref, 'e5'); assert.equal(typed.text, '2');
  assert.equal(clicks, 1); assert.equal(outcome.steps, 2);
});

test('numeric entry that appends instead of replacing escalates after one mutation', async () => {
  let value = '1', attempts = 0;
  const observed = () => ({ url, snapshot: `- spinbutton "Quantity" [e1]: "${value}"`,
    structure: { forms: [{ fields: [{ label: 'Quantity', name: 'quantity', type: 'number', tag: 'input', value, role: 'textbox' }] }] } });
  const outcome = await run({ snapshot: async () => observed(), type: async () => { attempts++; value += '2'; } },
    pick(c => c.startsWith('TYPE')), { ...request, variables: { quantity: '2' } });
  assert.equal(attempts, 1);
  assert.equal(outcome.reason, 'value_not_applied');
});

test('segment without completion criterion checkpoints at page transition before old variables can act', async () => {
  let nextPage = false;
  const browser = { snapshot: async () => nextPage ? { url: 'https://fixture.example/next', snapshot: '- heading "Stage two" [level=1]\n- textbox "Different field" [e1]',
    structure: { forms: [{ fields: [{ label: 'Different field', name: 'different', tag: 'input', type: 'text', role: 'textbox', value: '' }] }] } } :
    { url, snapshot: '- heading "Stage one" [level=1]\n- button "Continue" [e1]', structure: { forms: [] } },
  click: async () => { nextPage = true; } };
  const result = await run(browser, pick(c => c.startsWith('CLICK')),
    { ...request, variables: { oldStageValue: 'wrong' }, success: undefined });
  assert.equal(result.reason, 'page_changed_checkpoint');
  assert.equal(result.steps, 1);
});

test('unmapped date requires human recovery, then already verified value permits submit', async () => {
  const snap = date => ({ url, snapshot: '- textbox "Date"\n- textbox "Time" [e1]: 19:00\n- button "Send inquiry" [e2]',
    structure: { forms: [{ fields: [
      { label: 'Date', type: 'date', tag: 'input', role: 'textbox', name: 'date', value: date },
      { label: 'Time', type: 'time', tag: 'input', role: 'textbox', name: 'time', value: '19:00', ref: 'e1' },
    ] }] } });
  const req = { ...request, variables: { date: '2027-04-12', time: '19:00' } };
  assert.equal((await run({ snapshot: async () => snap('') }, () => assert.fail('no action'), req)).reason, 'unmapped_fields');
  let sent = false;
  const result = await run({ snapshot: async () => sent ? { ...snap('2027-04-12'), url: 'https://fixture.example/done' } : snap('2027-04-12'),
    click: async (_tab, action) => { assert.equal(action.ref, 'e2'); sent = true; } }, pick(c => c.startsWith('CLICK')), req);
  assert.equal(result.status, 'completed');
});

test('exact requested target link dominates adjacent decoy links without inventing a URL', async () => {
  const snap = { url, snapshot: '- link "Onyx Entry 15" [e1]\n- link "Quartz Entry 15" [e2]', structure: { forms: [] } };
  const result = await run({ snapshot: async () => snap }, async ({ choices }) => {
    assert.ok(choices.some(c => c.includes('Quartz Entry 15')));
    assert.ok(!choices.some(c => c.includes('Onyx Entry 15')));
    return pick(c => c.startsWith('ESCALATE'))({ choices });
  }, { ...request, variables: { target: 'Quartz Entry 15' } });
  assert.equal(result.reason, 'model_escalation');
});

test('destructive checkout and payment are not legal while search, save and inquiry remain legal', async () => {
  const snap = { url, snapshot: '- button "Pay now" [e1]\n- button "Place order" [e2]\n- button "Delete account" [e3]\n- button "Search" [e4]\n- button "Save to shortlist" [e5]\n- button "Send inquiry" [e6]',
    structure: { forms: [] } };
  const result = await run({ snapshot: async () => snap }, async ({ choices }) => {
    assert.ok(choices.some(c => c.includes('Search')));
    assert.ok(choices.some(c => c.includes('Save to shortlist')));
    assert.ok(choices.some(c => c.includes('Send inquiry')));
    assert.ok(!choices.some(c => /Pay now|Place order|Delete account/.test(c)));
    return pick(c => c.startsWith('ESCALATE'))({ choices });
  }, { ...request, variables: {} });
  assert.equal(result.reason, 'model_escalation');
  const onlyUnsafe = { ...snap, snapshot: '- button "Checkout" [e1]\n- button "Delete account" [e2]' };
  assert.equal((await run({ snapshot: async () => onlyUnsafe }, () => assert.fail('no model call'))).reason, 'unsafe_controls');
});

test('payment submission controls in payment context are withheld while ordinary controls remain available', async () => {
  const snap = { url, snapshot: '- button "Search" [e6]\n- button "Save" [e7]\n- button "Send inquiry" [e8]\n- link "Browse results" [e9]\n- button "Submit payment" [e1]\n- button "Complete payment" [e2]\n- button "Finalize purchase" [e3]\n- button "Pay now" [e4]\n- heading "Payment" [level=2]\n  - button "Continue" [e5]\n  - link "Continue" [e10]', structure: { forms: [] } };
  const result = await run({ snapshot: async () => snap }, async ({ choices }) => {
    for (const label of ['Submit payment', 'Complete payment', 'Finalize purchase', 'Pay now', 'Continue'])
      assert.ok(!choices.some(choice => choice.includes(label)), `${label} must not be offered`);
    for (const label of ['Search', 'Save', 'Send inquiry'])
      assert.ok(choices.some(choice => choice.includes(label)), `${label} should remain available`);
    assert.ok(choices.some(choice => choice.includes('Browse results')), 'harmless link outside payment context should remain available');
    return pick(c => c.startsWith('ESCALATE'))({ choices });
  }, { ...request, variables: {} });
  assert.equal(result.reason, 'model_escalation');
});

test('order submission is withheld outside payment context without blocking ordinary submissions', async () => {
  const snap = { url, snapshot: '- button "Submit order" [e1]\n- button "Complete order" [e2]\n- button "Submit request" [e3]\n- button "Send inquiry" [e4]', structure: { forms: [] } };
  const result = await run({ snapshot: async () => snap }, async ({ choices }) => {
    assert.ok(!choices.some(choice => /Submit order|Complete order/.test(choice)));
    assert.ok(choices.some(choice => choice.includes('Submit request')));
    assert.ok(choices.some(choice => choice.includes('Send inquiry')));
    return pick(c => c.startsWith('ESCALATE'))({ choices });
  }, { ...request, variables: {} });
  assert.equal(result.reason, 'model_escalation');
});

test('SSN and account-number controls escalate before decision; postcard stays ordinary', async () => {
  for (const label of ['Social security number', 'SSN', 'Account number', 'Password']) {
    const sensitive = { ...base(), snapshot: `- textbox "${label}" [e1]: 123-45-6789`,
      structure: { forms: [{ fields: [{ label, name: label, type: 'text', tag: 'input', value: '123-45-6789' }] }] } };
    const result = await run({ snapshot: async () => sensitive }, () => assert.fail('no model call'));
    assert.equal(result.reason, 'sensitive_fields');
    assert.ok(!JSON.stringify(result).includes('123-45-6789'));
  }
  const postcard = { ...base(), snapshot: '- textbox "Postcard title" [e1]', structure: { forms: [{ fields: [
    { label: 'Postcard title', name: 'postcard', type: 'text', tag: 'input', value: '' },
  ] }] } };
  assert.notEqual((await run({ snapshot: async () => postcard }, pick(c => c.startsWith('ESCALATE')),
    { ...request, variables: { postcard: 'Thank you' } })).reason, 'sensitive_fields');
});

test('rejects unknown request keys and malformed structure before a model call', async () => {
  const decide = () => assert.fail('no model call');
  assert.equal((await run({ snapshot: async () => base() }, decide, { ...request, backendUrl: 'http://unsafe' })).reason, 'invalid_request');
  assert.equal((await run({ snapshot: async () => base() }, decide, { ...request, variables: { gift: '123-45-6789' } })).reason, 'invalid_request');
  assert.equal((await run({ snapshot: async () => ({ ...base(), structure: { forms: [{ fields: [null] }] } }) }, decide)).reason, 'incomplete_snapshot');
  assert.equal((await run({ snapshot: async () => ({ ...base(), structure: { forms: [{ fields: [{ label: 'Size', tag: 'select', type: 'select', options: [{}] }] }] } }) }, decide)).reason, 'incomplete_snapshot');
});

test('post-action verification rejects reused ref for another semantic field', async () => {
  let typed = false;
  const browser = { snapshot: async () => typed ? { ...base('found'), snapshot: '- textbox "Different field" [e1]: found' } : base(),
    type: async () => { typed = true; } };
  assert.equal((await run(browser)).reason, 'field_unverifiable');
});

test('timed-out mutation quarantines tab until settled and explicitly inspected', async () => {
  let finish;
  let mutationStarted;
  const mutation = new Promise(resolve => { finish = resolve; });
  const started = new Promise(resolve => { mutationStarted = resolve; });
  const browser = { scopeId: 'poisoned-tab-test', snapshot: async () => base(), type: async () => {
    mutationStarted();
    return mutation;
  } };
  assert.equal(browserTabMutationAllowed(browser.scopeId, request.tabId), true);
  const executing = run(browser, undefined, request, { timeoutMs: 100 });
  await started;
  assert.equal(browserTabMutationAllowed(browser.scopeId, request.tabId), false);
  const timed = await executing;
  assert.equal(timed.reason, 'action_outcome_unknown');
  assert.match(timed.recovery_hint, /Remote mutation may complete later/);
  assert.equal(browserTabMutationAllowed(browser.scopeId, request.tabId), false);
  assert.equal(browserTabMutationAllowed(browser.scopeId, request.tabId), false); // pure; never clears quarantine
  assert.equal(browserTabMutationAllowed('another-scoped-user', request.tabId), true);
  assert.equal((await run(browser)).reason, 'tab_quarantined');
  assert.equal(await recoverBrowserTab(browser, request.tabId, { confirm: () => true }), false);
  finish();
  await mutation;
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(browserTabMutationAllowed(browser.scopeId, request.tabId), false);
  assert.equal((await run(browser)).reason, 'tab_quarantined');
  assert.equal(await recoverBrowserTab(browser, request.tabId, { confirm: () => false }), false);
  assert.equal(browserTabMutationAllowed(browser.scopeId, request.tabId), false);
  assert.equal(await recoverBrowserTab(browser, request.tabId, { confirm: observation => observation.url === url }), true);
  assert.equal(browserTabMutationAllowed(browser.scopeId, request.tabId), true);
  assert.notEqual((await run(browser, pick(c => c.startsWith('ESCALATE')))).reason, 'tab_quarantined');
});

test('read-only mutation gate rejects invalid scopes and tabs without affecting leases', () => {
  for (const args of [[null, 'tab1'], ['', 'tab1'], [' ', 'tab1'], [' scope ', 'tab1'], ['scope\nleak', 'tab1'], ['scope', '../tab'],
    ['scope', ''], ['scope', 123], ['s'.repeat(513), 'tab1']]) {
    assert.throws(() => browserTabMutationAllowed(...args), /invalid_tab_scope/);
  }
  assert.equal(browserTabMutationAllowed('http://127.0.0.1:9377:scoped-user', 'tab-1'), true);
});

test('synchronous low-level reservation blocks executor, releases exactly once on success', async () => {
  const scopeId = 'http://127.0.0.1:9377:low-level-first';
  const tabId = 'low-level-tab';
  const release = reserveBrowserTabMutation(scopeId, tabId);
  assert.equal(browserTabMutationAllowed(scopeId, tabId), false);
  assert.throws(() => reserveBrowserTabMutation(scopeId, tabId), /tab_mutation_unavailable/);
  const blocked = await run({ scopeId, snapshot: async () => base() }, undefined, { ...request, tabId });
  assert.equal(blocked.reason, 'tab_busy');
  assert.equal(browserTabMutationAllowed(`${scopeId}-other`, tabId), true);
  assert.equal(release({ ok: true }), true);
  assert.equal(release({ ok: false }), false);
  assert.equal(browserTabMutationAllowed(scopeId, tabId), true);
});

test('unacknowledged low-level release fails closed until trusted snapshot recovery', async () => {
  const scopeId = 'http://127.0.0.1:9377:low-level-failure';
  const tabId = 'failed-tab';
  const browser = { scopeId, snapshot: async () => base() };
  const release = reserveBrowserTabMutation(scopeId, tabId);
  assert.equal(await recoverBrowserTab(browser, tabId, { confirm: () => true }), false);
  assert.equal(release(), true);
  assert.equal(browserTabMutationAllowed(scopeId, tabId), false);
  assert.equal((await run(browser, undefined, { ...request, tabId })).reason, 'tab_quarantined');
  assert.equal(await recoverBrowserTab(browser, tabId, { confirm: () => false }), false);
  assert.equal(browserTabMutationAllowed(scopeId, tabId), false);
  assert.equal(await recoverBrowserTab(browser, tabId, { confirm: observed => observed.url === url }), true);
  assert.equal(browserTabMutationAllowed(scopeId, tabId), true);
});

test('timeout of verification snapshot after acknowledged mutation still quarantines the tab', async () => {
  let n = 0;
  const browser = { scopeId: 'post-mutation-snapshot-timeout', snapshot: async () => {
    if (++n === 3) return new Promise(() => {});
    return base();
  }, type: async () => {} };
  assert.equal((await run(browser, undefined, request, { timeoutMs: 25 })).reason, 'action_outcome_unknown');
  assert.equal((await run(browser)).reason, 'tab_quarantined');
  assert.equal(await recoverBrowserTab(browser, request.tabId, { confirm: () => true }), true);
});
