import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHmac } from 'node:crypto';

const path = process.env.CAMOFOX_PLUGIN_PATH;
if (!path) throw Error('Build the default plugin and provide CAMOFOX_PLUGIN_PATH');
const plugin = await import(`${path}/plugin.js`);
const key = 'integration-only-placeholder';
process.env.CAMOFOX_ACCESS_KEY = key;
const scoped = id => createHmac('sha256', key).update(id).digest('hex');
const ctx = id => ({ sessionKey: id, agentId: 'caller-supplied-not-authoritative' });
const reply = data => new Response(JSON.stringify(data), { headers: { 'content-type': 'application/json' } });
const snapshot = { snapshot: '- textbox "Search" [e1]', structure: { forms: [{ fields: [
  { label: 'Account', type: 'text', value: 'ordinary-value' },
] }] }, customData: { arbitrary: 'preserved-value' }, nextOffset: 600, hasMore: true };

function register(url = 'http://127.0.0.1:9377') {
  const tools = new Map();
  plugin.default({
    pluginConfig: { url, autoStart: false }, log: {},
    registerTool(factory, { name }) {
      assert.ok(!tools.has(name), `duplicate registration: ${name}`);
      tools.set(name, factory);
    },
  });
  return tools;
}

test('default manifests and registration expose only the approved tools', async () => {
  const expected = ['camofox_create_tab', 'camofox_snapshot', 'camofox_select', 'camofox_click',
    'camofox_type', 'camofox_navigate', 'camofox_scroll', 'camofox_screenshot',
    'camofox_close_tab', 'camofox_list_tabs'];
  const manifest = JSON.parse(await readFile(`${path}/openclaw.plugin.json`, 'utf8'));
  const pkg = JSON.parse(await readFile(`${path}/package.json`, 'utf8'));
  assert.deepEqual(manifest.tools, expected);
  assert.deepEqual(manifest.contracts.tools, expected);
  assert.deepEqual(pkg.openclaw.tools.map(t => t.name).sort(), expected.toSorted());
  assert.ok(!Object.hasOwn(manifest.configSchema.properties, 'browserExecutor'));
  assert.deepEqual([...register().keys()].sort(), expected.toSorted());
  assert.ok(!register().has('camofox_evaluate'));
  assert.ok(!register().has('camofox_import_cookies'));
});

test('snapshot disables screenshot, preserves pagination and isolates HMAC scopes', async () => {
  const tools = register();
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
  const saved = process.env.CAMOFOX_ACCESS_KEY;
  try {
    delete process.env.CAMOFOX_ACCESS_KEY;
    assert.throws(() => tools.get('camofox_select')(ctx('scope')), /access key/);
  } finally {
    process.env.CAMOFOX_ACCESS_KEY = saved;
  }
});

test('invalid offsets are rejected before network, including bypassed schema', async () => {
  let requests = 0;
  globalThis.fetch = async () => { requests++; return reply(snapshot); };
  const tool = register().get('camofox_snapshot')(ctx('scope'));
  for (const offset of [-1, 1.2, '10', Number.NaN, Number.MAX_SAFE_INTEGER + 1])
    await assert.rejects(tool.execute('call', { tabId: 'tab-1', offset }), /Invalid snapshot offset/);
  assert.equal(requests, 0);
});

test('select validates tab, ref and option and sends scoped userId', async () => {
  const calls = [];
  globalThis.fetch = async (url, options) => { calls.push({ url: String(url), options }); return reply({ ok: true }); };
  const tool = register().get('camofox_select')(ctx('select-session'));
  await tool.execute('call', { tabId: 'tab-2', ref: 'e5', option: 'Express' });
  assert.equal(calls[0].url, 'http://127.0.0.1:9377/tabs/tab-2/select');
  assert.deepEqual(JSON.parse(calls[0].options.body), { userId: scoped('select-session'), ref: 'e5', option: 'Express' });
  for (const params of [{ tabId: 'tab-2', ref: 'css=#x', option: 'x' },
    { tabId: '../outside', ref: 'e5', option: 'x' }, { tabId: 'tab-2', ref: 'e5', option: '' }])
    await assert.rejects(tool.execute('call', params), /Invalid/);
  assert.equal(calls.length, 1);
});

test('large, failed and timed-out backend responses never leak contents or bearer', async () => {
  const tool = register().get('camofox_snapshot')(ctx('errors'));
  const body = 'private-backend-body';
  let cancelled = false;
  globalThis.fetch = async () => new Response(new ReadableStream({ cancel() { cancelled = true; } }),
    { headers: { 'content-length': '250001' } });
  await assert.rejects(tool.execute('call', { tabId: 'tab-1' }), error =>
    error.message === 'Camofox local request failed' && !error.message.includes(body) && !error.message.includes(key));
  assert.equal(cancelled, true);
  globalThis.fetch = async () => new Response('x'.repeat(250001));
  await assert.rejects(tool.execute('call', { tabId: 'tab-1' }), /Camofox local request failed/);
  globalThis.fetch = async () => new Response(body, { status: 403 });
  await assert.rejects(tool.execute('call', { tabId: 'tab-1' }), /Camofox local request failed/);
  const originalTimeout = AbortSignal.timeout;
  try {
    AbortSignal.timeout = () => AbortSignal.abort(new Error('fixture timeout'));
    globalThis.fetch = (_, { signal }) => Promise.reject(signal.reason);
    await assert.rejects(tool.execute('call', { tabId: 'tab-1' }), /Camofox local request failed/);
  } finally {
    AbortSignal.timeout = originalTimeout;
  }
  await assert.rejects(register('https://elsewhere.example').get('camofox_snapshot')(ctx('scope'))
    .execute('call', { tabId: 'tab-1' }), /Camofox local request failed/);
});
