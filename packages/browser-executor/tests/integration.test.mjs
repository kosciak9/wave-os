import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHmac } from 'node:crypto';

const normalPath = process.env.CAMOFOX_PLUGIN_PATH;
const optionalPath = process.env.CAMOFOX_EXECUTOR_PLUGIN_PATH;
if (!normalPath || !optionalPath) throw Error('Build both plugins and provide CAMOFOX_PLUGIN_PATH and CAMOFOX_EXECUTOR_PLUGIN_PATH');
const normal = await import(`${normalPath}/plugin.js`);
const optional = await import(`${optionalPath}/plugin.js`);
const key = 'integration-only-placeholder';
process.env.CAMOFOX_ACCESS_KEY = key;
const scoped = id => createHmac('sha256', key).update(id).digest('hex');
const ctx = id => ({ sessionKey: id, agentId: 'caller-supplied-not-authoritative' });
const reply = data => new Response(JSON.stringify(data), { headers: { 'content-type': 'application/json' } });
const snapshot = { snapshot: '- textbox "Search" [e1]', structure: { forms: [{ fields: [
  { label: 'Account', type: 'text', value: 'ordinary-value' },
] }] }, customData: { arbitrary: 'preserved-value' }, nextOffset: 600, hasMore: true };

function register(plugin, browserExecutor = { enabled: false }, url = 'http://127.0.0.1:9377') {
  const tools = new Map();
  const api = {
    pluginConfig: { url, autoStart: false, browserExecutor }, log: {},
    registerTool(factory, { name }) {
      assert.ok(!tools.has(name), `duplicate registration: ${name}`);
      tools.set(name, factory);
    },
  };
  plugin.default(api);
  return tools;
}

test('manifests, registration and default-off package never advertise local execution', async () => {
  const expected = ['camofox_create_tab', 'camofox_snapshot', 'camofox_select', 'camofox_click',
    'camofox_type', 'camofox_navigate', 'camofox_scroll', 'camofox_screenshot',
    'camofox_close_tab', 'camofox_list_tabs'];
  for (const [path, plugin, enabled] of [[normalPath, normal, false], [optionalPath, optional, true]]) {
    const manifest = JSON.parse(await readFile(`${path}/openclaw.plugin.json`, 'utf8'));
    const pkg = JSON.parse(await readFile(`${path}/package.json`, 'utf8'));
    const advertised = [...expected, ...(enabled ? ['browser_execute'] : [])];
    assert.deepEqual(manifest.tools, advertised);
    assert.deepEqual(manifest.contracts.tools, advertised);
    assert.deepEqual(pkg.openclaw.tools.map(t => t.name).sort(), advertised.toSorted());
    assert.equal(manifest.configSchema.properties.browserExecutor.properties.enabled.default, false);
    const defaults = manifest.configSchema.properties.browserExecutor.properties;
    assert.deepEqual([defaults.backend.default, defaults.threshold.default, defaults.margin.default,
      defaults.maxSteps.default, defaults.timeoutMs.default], ['laya', 0.5, 0.05, 8, 120000]);
    assert.equal(defaults.threshold.minimum, 0);
    assert.deepEqual([...register(plugin).keys()].sort(), expected.toSorted());
    assert.ok(!register(plugin).has('camofox_evaluate'));
    assert.ok(!register(plugin).has('camofox_import_cookies'));
  }
});

test('snapshot explicitly disables screenshot, preserves pagination and isolates HMAC scopes', async () => {
  const tools = register(normal);
  const calls = [];
  globalThis.fetch = async (url, options) => {
    calls.push({ url: String(url), options });
    return reply({ ...snapshot, screenshot: { data: 'never-forward' } });
  };
  for (const id of ['session-one', 'session-two']) {
    const result = await tools.get('camofox_snapshot')(ctx(id)).execute('call', { tabId: 'tab-1', offset: 600 });
    assert.equal(result.content.length, 1);
    assert.deepEqual(JSON.parse(result.content[0].text), snapshot);
  }
  assert.equal(calls.length, 2);
  for (const [index, id] of ['session-one', 'session-two'].entries()) {
    const url = new URL(calls[index].url);
    assert.equal(url.pathname, '/tabs/tab-1/snapshot');
    assert.equal(url.searchParams.get('userId'), scoped(id));
    assert.equal(url.searchParams.get('includeScreenshot'), 'false');
    assert.equal(url.searchParams.get('offset'), '600');
    assert.equal(calls[index].options.headers.Authorization, `Bearer ${key}`);
    assert.ok(calls[index].options.signal);
  }
  assert.notEqual(scoped('session-one'), scoped('session-two'));
  assert.throws(() => tools.get('camofox_snapshot')({ agentId: 'unscoped' }), /scoped identity/);
});

test('invalid offsets are rejected before network, including bypassed tool schema', async () => {
  let requests = 0;
  globalThis.fetch = async () => { requests++; return reply(snapshot); };
  const tool = register(normal).get('camofox_snapshot')(ctx('scope'));
  for (const offset of [-1, 1.2, '10', Number.NaN, Number.MAX_SAFE_INTEGER + 1])
    await assert.rejects(tool.execute('call', { tabId: 'tab-1', offset }), /Invalid snapshot offset/);
  assert.equal(requests, 0);
});

test('select permits only known ref syntax and sends scoped userId, never a selector', async () => {
  const calls = [];
  globalThis.fetch = async (url, options) => { calls.push({ url: String(url), options }); return reply({ ok: true }); };
  const tool = register(normal).get('camofox_select')(ctx('select-session'));
  await tool.execute('call', { tabId: 'tab-2', ref: 'e5', option: 'Express' });
  assert.equal(calls[0].url, 'http://127.0.0.1:9377/tabs/tab-2/select');
  assert.deepEqual(JSON.parse(calls[0].options.body), { userId: scoped('select-session'), ref: 'e5', option: 'Express' });
  for (const params of [{ tabId: 'tab-2', ref: 'css=#x', option: 'x' },
    { tabId: '../outside', ref: 'e5', option: 'x' }, { tabId: 'tab-2', ref: 'e5', option: '' }])
    await assert.rejects(tool.execute('call', params), /Invalid/);
  assert.equal(calls.length, 1);
});

test('executor lease blocks low-level mutation and native select while busy or poisoned, not reads or other tabs', async () => {
  const wrapper = await readFile(`${optionalPath}/plugin.js`, 'utf8');
  const runtime = /import \{ browserTabMutationAllowed \} from "([^"]+\/core\.mjs)";/.exec(wrapper)?.[1];
  assert.ok(runtime, 'executor wrapper must import the shared in-process lease');
  const { executeBrowser, recoverBrowserTab, browserTabMutationAllowed } = await import(runtime);
  const tools = register(optional, { enabled: true });
  assert.ok(!tools.has('recoverBrowserTab'));
  const identity = scoped('guarded-session');
  const scopeId = `http://127.0.0.1:9377:${identity}`;
  const tabId = 'leased-tab';
  const observation = { url: 'https://fixture.example/form',
    snapshot: '- heading "Demo" [level=1]\n- textbox "Search" [e1]\n- button "Submit" [e2]',
    structure: { forms: [{ fields: [{ label: 'Search', name: 'q', tag: 'input', type: 'text', role: 'textbox', value: '', disabled: false }] }] } };
  let entered;
  const enteredMutation = new Promise(resolve => { entered = resolve; });
  const browser = { scopeId, snapshot: async () => observation,
    type: async () => { entered(); return new Promise(() => {}); } };
  const request = { goal: 'Search', tabId, variables: { search: 'found' }, success: { urlPath: '/done' } };
  const decide = async ({ choices }) => {
    const choice = choices.find(c => c.startsWith('TYPE '));
    return { choice, probabilities: Object.fromEntries(choices.map(c => [c, c === choice ? 1 : 0])), latency_ms: 1 };
  };
  const pending = executeBrowser(request, { browser, decide, timeoutMs: 75 });
  await enteredMutation;
  assert.equal(browserTabMutationAllowed(scopeId, tabId), false);
  let requests = 0;
  globalThis.fetch = async () => { requests++; return reply({ ...snapshot, ok: true }); };
  const actor = ctx('guarded-session');
  for (const toolName of ['camofox_click', 'camofox_type', 'camofox_navigate', 'camofox_scroll']) {
    await assert.rejects(tools.get(toolName)(actor).execute('call', { tabId, ref: 'e1', text: 'found', url: 'https://fixture.example/' }),
      /Browser tab has an unresolved local action; inspect before mutating/);
  }
  await assert.rejects(tools.get('camofox_select')(actor).execute('call', { tabId, ref: 'e1', option: 'found' }),
    /Browser tab has an unresolved local action; inspect before mutating/);
  assert.equal(requests, 0);
  await tools.get('camofox_snapshot')(actor).execute('call', { tabId });
  await tools.get('camofox_click')(actor).execute('call', { tabId: 'other-tab', ref: 'e1' });
  await tools.get('camofox_select')(actor).execute('call', { tabId: 'other-tab', ref: 'e1', option: 'found' });
  await tools.get('camofox_click')(ctx('different-session')).execute('call', { tabId, ref: 'e1' });
  await tools.get('camofox_close_tab')(actor).execute('call', { tabId });
  assert.equal(requests, 5);
  assert.equal((await pending).reason, 'action_outcome_unknown');
  assert.equal(browserTabMutationAllowed(scopeId, tabId), false);
  await assert.rejects(tools.get('camofox_select')(actor).execute('call', { tabId, ref: 'e1', option: 'found' }),
    /Browser tab has an unresolved local action; inspect before mutating/);
  assert.equal(requests, 5);
  // Operator-only cleanup of synthetic poisoned lease; no model recovery tool is registered.
  assert.equal(await recoverBrowserTab(browser, tabId, { confirm: async () => true }), false);
});

test('low-level reservation blocks executor before dispatch and releases after a clean response', async () => {
  const wrapper = await readFile(`${optionalPath}/plugin.js`, 'utf8');
  const runtime = /import \{ browserTabMutationAllowed \} from "([^"]+\/core\.mjs)";/.exec(wrapper)?.[1];
  assert.ok(runtime);
  const { browserTabMutationAllowed } = await import(runtime);
  const tools = register(optional, { enabled: true });
  const actor = ctx('lowlevel-first');
  const scopeId = `http://127.0.0.1:9377:${scoped('lowlevel-first')}`;
  const tabId = 'lowlevel-first-tab';
  let settle;
  const pendingResponse = new Promise(resolve => { settle = resolve; });
  let dispatched = 0;
  globalThis.fetch = async (url, options) => {
    if (options.method === 'POST' && new URL(url).pathname.endsWith(`/${tabId}/select`)) {
      dispatched++;
      return pendingResponse;
    }
    return reply({ ...snapshot, ok: true });
  };
  const selecting = tools.get('camofox_select')(actor).execute('call', { tabId, ref: 'e1', option: 'found' });
  assert.equal(browserTabMutationAllowed(scopeId, tabId), false);
  assert.equal(dispatched, 1);
  const executor = tools.get('browser_execute')(actor);
  const outcome = JSON.parse((await executor.execute('call', {
    goal: 'Find a listing', tabId, variables: { search: 'found' },
  })).content[0].text);
  assert.equal(outcome.reason, 'tab_busy');
  await assert.rejects(tools.get('camofox_click')(actor).execute('call', { tabId, ref: 'e1' }),
    /Browser tab has an unresolved local action; inspect before mutating/);
  await tools.get('camofox_select')(actor).execute('call', { tabId: 'another-tab', ref: 'e1', option: 'found' });
  assert.equal(browserTabMutationAllowed(scopeId, 'another-tab'), true);
  settle(reply({ ok: true }));
  await selecting;
  assert.equal(browserTabMutationAllowed(scopeId, tabId), true);
});

test('failed low-level request poisons both tool surfaces until trusted recovery; default plugin is unchanged', async () => {
  const wrapper = await readFile(`${optionalPath}/plugin.js`, 'utf8');
  const runtime = /import \{ browserTabMutationAllowed \} from "([^"]+\/core\.mjs)";/.exec(wrapper)?.[1];
  assert.ok(runtime);
  const { browserTabMutationAllowed, recoverBrowserTab, reserveBrowserTabMutation } = await import(runtime);
  const tools = register(optional, { enabled: true });
  const actor = ctx('failed-lowlevel');
  const scopeId = `http://127.0.0.1:9377:${scoped('failed-lowlevel')}`;
  const tabId = 'failed-lowlevel-tab';
  globalThis.fetch = async (url, options) => {
    if (options.method === 'POST' && new URL(url).pathname.endsWith(`/${tabId}/select`))
      throw Error(`Bearer ${key}: private backend failure`);
    return reply({ ok: true });
  };
  await assert.rejects(tools.get('camofox_select')(actor).execute('call', { tabId, ref: 'e1', option: 'x' }),
    error => error.message === 'Browser mutation outcome uncertain; inspect before mutating' && !error.message.includes(key));
  assert.equal(browserTabMutationAllowed(scopeId, tabId), false);
  const outcome = JSON.parse((await tools.get('browser_execute')(actor).execute('call', {
    goal: 'Search', tabId, variables: { search: 'found' },
  })).content[0].text);
  assert.equal(outcome.reason, 'tab_quarantined');
  await assert.rejects(tools.get('camofox_click')(actor).execute('call', { tabId, ref: 'e1' }),
    /Browser tab has an unresolved local action; inspect before mutating/);
  await tools.get('camofox_click')(actor).execute('call', { tabId: 'unrelated-tab', ref: 'e1' });
  assert.equal(browserTabMutationAllowed(scopeId, tabId), false);
  assert.ok(!tools.has('recoverBrowserTab'));
  const browser = { scopeId, snapshot: async () => ({ url: 'https://fixture.example/review', snapshot: '- heading "Reviewed"' }) };
  assert.equal(await recoverBrowserTab(browser, tabId, { confirm: () => false }), false);
  assert.equal(browserTabMutationAllowed(scopeId, tabId), false);
  assert.equal(await recoverBrowserTab(browser, tabId, { confirm: () => true }), true);
  assert.equal(browserTabMutationAllowed(scopeId, tabId), true);

  // The separate default-off package must not depend on an executor lease.
  const normalTools = register(normal);
  const defaultActor = ctx('default-off-lease-check');
  const defaultScope = `http://127.0.0.1:9377:${scoped('default-off-lease-check')}`;
  const release = reserveBrowserTabMutation(defaultScope, 'default-tab');
  try {
    assert.equal(browserTabMutationAllowed(defaultScope, 'default-tab'), false);
    await normalTools.get('camofox_click')(defaultActor).execute('call', { tabId: 'default-tab', ref: 'e1' });
  } finally { release({ ok: true }); }
  assert.equal(browserTabMutationAllowed(defaultScope, 'default-tab'), true);
});

test('large, failed and timed-out backend responses never leak contents or bearer', async () => {
  const tool = register(normal).get('camofox_snapshot')(ctx('errors'));
  const body = 'private-backend-body';
  let cancelled = false;
  const oversized = new Response(new ReadableStream({ cancel() { cancelled = true; } }),
    { headers: { 'content-length': '250001' } });
  globalThis.fetch = async () => oversized;
  await assert.rejects(tool.execute('call', { tabId: 'tab-1' }), error =>
    error.message === 'Camofox local request failed' && !error.message.includes(body));
  assert.equal(cancelled, true);
  globalThis.fetch = async () => new Response('x'.repeat(250001));
  await assert.rejects(tool.execute('call', { tabId: 'tab-1' }), /Camofox local request failed/);
  globalThis.fetch = async () => new Response(body, { status: 403 });
  await assert.rejects(tool.execute('call', { tabId: 'tab-1' }), /Camofox local request failed/);
  globalThis.fetch = (_, { signal }) => new Promise((_, reject) =>
    signal.addEventListener('abort', () => reject(signal.reason), { once: true }));
  await assert.rejects(tool.execute('call', { tabId: 'tab-1' }), /Camofox local request failed/);
});

test('enabled optional local tool escalates on unavailable backend without mutation', async () => {
  assert.ok(!register(optional).has('browser_execute'));
  const tools = register(optional, { enabled: true });
  assert.ok(tools.has('browser_execute'));
  const calls = [];
  globalThis.fetch = async (url, options) => { calls.push({ url: String(url), options }); throw Error('offline fixture'); };
  const tool = tools.get('browser_execute')(ctx('execution-scope'));
  const result = await tool.execute('call', {
    goal: 'Find the heading', tabId: 'tab-1', variables: { searchTerm: 'example' },
    success: { textIncludes: 'Complete' },
  });
  const outcome = JSON.parse(result.content[0].text);
  assert.equal(outcome.status, 'escalated');
  assert.equal(outcome.reason, 'backend_or_model_error');
  assert.ok(calls.every(call => call.options.method === 'GET'));
  assert.ok(calls.every(call => new URL(call.url).searchParams.get('userId') === scoped('execution-scope')));
  assert.throws(() => register(optional, { enabled: true, backend: 'shell' }), /Invalid browser executor configuration/);
  assert.ok(register(optional, { enabled: true, backend: 'kev', threshold: 0.2, margin: 0.01 }).has('browser_execute'));
  assert.throws(() => register(optional, { enabled: true }, 'https://elsewhere.example'), /local backend URL/);
});
