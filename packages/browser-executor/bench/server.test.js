import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { startFixtureServer } from './server.js';
import { manifest, tasks } from './tasks.js';

test('manifest is stable, split is fixed and no answer identifiers are published', () => {
  const listed = manifest();
  assert.equal(listed.length, 30);
  assert.equal(listed.filter(t => t.split === 'calibration').length, 10);
  assert.equal(listed.filter(t => t.split === 'heldout').length, 20);
  assert.equal(new Set(listed.map(t => t.id)).size, 30);
  assert.equal(new Set(listed.map(t => t.category)).size, 7);
  assert.ok(listed.every(t => !('options' in t) && !('decoy' in t)));
  for (const task of listed.filter(t => t.category === 'long')) {
    const fields = ['destination', 'arrival', 'travel', 'reference', 'attendee', 'seat', 'access', 'ticket', 'meal', 'session', 'venue', 'reminder', 'summary', 'timezone', 'contact', 'confirm'];
    assert.ok(fields.every(name => task.variables[name] && task.goal.includes(String(task.variables[name]))));
  }
});

test('run reset, protected oracle, wrong selection, recovery and stop-before-checkout', async () => {
  const fixture = await startFixtureServer();
  const base = `http://127.0.0.1:${fixture.port}`;
  const run = randomUUID();
  const oracle = async () => {
    const response = await fetch(`${base}/api/runs/${run}`, { headers: { 'x-fixture-key': fixture.oracleKey } });
    assert.equal(response.status, 200);
    return response.json();
  };
  const post = (path, body) => fetch(`${base}${path}`, { method: 'POST', body: new URLSearchParams(body), redirect: 'follow' });
  try {
    assert.equal((await fetch(`${base}/api/runs/${run}`)).status, 403);
    const cart = tasks.find(t => t.category === 'cart');
    const path = `/run/${run}/${cart.id}`;
    await fetch(`${base}${path}/start`);
    await post(`${path}/add`, { item: String(cart.options.indexOf(cart.decoy)), quantity: cart.variables.quantity });
    assert.equal((await oracle()).mistakes, 1);
    await post(`${path}/add`, { item: String(cart.options.indexOf(cart.target)), quantity: cart.variables.quantity });
    const cartPage = await fetch(`${base}${path}/cart`);
    assert.match(await cartPage.text(), /Stop here/);
    assert.equal((await oracle()).passed, true);
    await post(`${path}/checkout`, {});
    assert.equal((await oracle()).mistakes, 2);
    assert.equal((await oracle()).passed, false);
    await fetch(`${base}${path}/start`);
    assert.equal((await oracle()).passed, false);
    assert.equal((await oracle()).mistakes, 0);
  } finally { await fixture.close(); }
});

test('long itinerary requires four validated stages and records recovery', async () => {
  const fixture = await startFixtureServer();
  const base = `http://127.0.0.1:${fixture.port}`;
  const run = randomUUID();
  const task = tasks.find(t => t.category === 'long');
  const path = `/run/${run}/${task.id}`;
  const submit = values => fetch(`${base}${path}/stage`, { method: 'POST', body: new URLSearchParams(values), redirect: 'follow' });
  const oracle = async () => (await fetch(`${base}/api/runs/${run}`, { headers: { 'x-fixture-key': fixture.oracleKey } })).json();
  try {
    await fetch(`${base}${path}/start`);
    const firstPage = await (await fetch(`${base}${path}/work`)).text();
    assert.match(firstPage, /<label>Destination <input/);
    assert.doesNotMatch(firstPage, /\(use /);
    await submit({ destination: task.target, arrival: '2028-04-12', travel: 'Rail', reference: 'Conference' });
    let result = await submit({ attendee: 'Guest Delegate', seat: task.variables.seat === 'window' ? 'aisle' : 'window', access: 'None', ticket: 'Standard' });
    assert.match(await result.text(), /Check the selection/);
    assert.equal((await oracle()).passed, false);
    await submit({ attendee: 'Guest Delegate', seat: task.variables.seat, access: 'None', ticket: 'Standard' });
    await submit({ meal: task.variables.meal, session: 'Strategy', venue: 'North', reminder: 'Email' });
    await submit({ summary: 'Conference visit', timezone: 'UTC', contact: 'Office Desk', confirm: 'Reviewed' });
    assert.deepEqual([(await oracle()).passed, (await oracle()).mistakes], [true, 1]);
    assert.equal((await oracle()).events.filter(e => e.action === 'submit:stage').length, 5);
  } finally { await fixture.close(); }
});

test('booking validation rejects incorrect requests and malformed run URLs', async () => {
  const fixture = await startFixtureServer();
  const base = `http://127.0.0.1:${fixture.port}`;
  const run = randomUUID();
  const task = tasks.find(t => t.category === 'booking');
  const path = `/run/${run}/${task.id}`;
  try {
    await fetch(`${base}${path}/start`);
    const item = task.options.indexOf(task.target);
    await fetch(`${base}${path}/detail?item=${item}`);
    await fetch(`${base}${path}/request`, { method: 'POST', body: new URLSearchParams({ date: task.variables.date, time: task.variables.time, party: '99' }) });
    const oracle = async () => (await fetch(`${base}/api/runs/${run}`, { headers: { 'x-fixture-key': fixture.oracleKey } })).json();
    assert.equal((await oracle()).passed, false);
    await fetch(`${base}${path}/request`, { method: 'POST', body: new URLSearchParams({ date: task.variables.date, time: task.variables.time, party: String(task.variables.party) }) });
    assert.equal((await oracle()).passed, true);
    assert.equal((await fetch(`${base}/api/tasks`)).status, 200);
    assert.equal((await fetch(`${base}/run/short/${task.id}/start`)).status, 404);
  } finally { await fixture.close(); }
});

test('search, autocomplete form, synthetic dashboard and directory assert actual actions', async () => {
  const fixture = await startFixtureServer();
  const base = `http://127.0.0.1:${fixture.port}`;
  try {
    for (const category of ['search', 'forms', 'login', 'spa']) {
      const task = tasks.find(t => t.category === category && t.split === 'heldout');
      const run = randomUUID();
      const path = `/run/${run}/${task.id}`;
      const get = route => fetch(`${base}${path}/${route}`);
      const post = (route, values) => fetch(`${base}${path}/${route}`, {
        method: 'POST', body: new URLSearchParams(values), redirect: 'follow',
      });
      const oracle = async () => (await fetch(`${base}/api/runs/${run}`, { headers: { 'x-fixture-key': fixture.oracleKey } })).json();
      await get('start');
      if (category === 'search') {
        await post('results', { q: task.target });
        const results = await (await get('results')).text();
        assert.match(results, /Search results/);
        await get(`detail?item=${task.options.indexOf(task.target)}`);
        await post('save', {});
      } else if (category === 'forms') {
        await post('submit', { location: task.target, service: task.variables.service, date: task.variables.date, label: 'Office delivery' });
      } else if (category === 'login') {
        await post('login', { username: 'demo', passphrase: 'fixture' });
        const logged = await oracle();
        assert.deepEqual(logged.events.find(e => e.action === 'submit:login').values, { username: 'demo', passphrase: '[REDACTED]' });
        assert.doesNotMatch(JSON.stringify(logged.events), /"passphrase":"fixture"/);
        await get(`tab?name=${task.target}`);
        await post('filter', { period: task.variables.filter });
      } else {
        await get('list?page=2');
        await get(`modal?item=${task.options.indexOf(task.target)}`);
        await post('pin', {});
      }
      assert.equal((await oracle()).passed, true, category);
      assert.equal((await oracle()).mistakes, 0, category);
    }
  } finally { await fixture.close(); }
});

test('heldout draft starts with visibly wrong location and requires correction', async () => {
  const fixture = await startFixtureServer();
  const base = `http://127.0.0.1:${fixture.port}`;
  const task = tasks.find(t => t.id === 'forms-18');
  const run = randomUUID();
  const path = `/run/${run}/${task.id}`;
  const oracle = async () => (await fetch(`${base}/api/runs/${run}`, { headers: { 'x-fixture-key': fixture.oracleKey } })).json();
  const submit = location => fetch(`${base}${path}/submit`, { method: 'POST', body: new URLSearchParams({
    location, service: task.variables.service, date: task.variables.date, label: 'Office delivery',
  }), redirect: 'follow' });
  try {
    const start = await (await fetch(`${base}${path}/start`)).text();
    assert.match(start, /prefilled from a previous draft/);
    assert.match(start, new RegExp(`name="location"[^>]+value="${task.decoy}"`));
    await submit(task.decoy);
    assert.deepEqual([(await oracle()).passed, (await oracle()).mistakes], [false, 1]);
    await submit(task.target);
    assert.deepEqual([(await oracle()).passed, (await oracle()).mistakes], [true, 1]);
  } finally { await fixture.close(); }
});
