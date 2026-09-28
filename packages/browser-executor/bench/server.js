import http from 'node:http';
import { randomBytes } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { manifest, taskById } from './tasks.js';

const escape = value => String(value ?? '').replace(/[&<>"']/g, c => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
})[c]);
const input = (label, name, value = '', type = 'text', extra = '') =>
  `<label>${escape(label)} <input name="${escape(name)}" type="${type}" value="${escape(value)}" ${extra} required></label>`;
const select = (label, name, values) =>
  `<label>${escape(label)} <select name="${escape(name)}">${values.map(v => `<option value="${escape(v)}">${escape(v)}</option>`).join('')}</select></label>`;
const form = (action, contents, button) =>
  `<form method="post" action="${escape(action)}">${contents}<button type="submit">${escape(button)}</button></form>`;
const link = (href, label) => `<a href="${escape(href)}">${escape(label)}</a>`;
const page = (title, body) => `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>${escape(title)}</title><style>body{font:1rem system-ui;max-width:50rem;margin:2rem auto;padding:0 1rem}label{display:block;margin:.9rem 0}input,select,button{font:inherit;padding:.4rem}li{margin:.9rem 0}.error{color:#a00}nav a{margin-right:1rem}</style></head><body><main><h1>${escape(title)}</h1>${body}</main></body></html>`;
// Progressive enhancement: directory links still work without JS, but clicks
// replace the document's main region and update history like a small SPA.
const spaScript = `<script>function watchMore(){const a=document.getElementById('load-more');if(a)new IntersectionObserver((entries,observer)=>{if(entries[0].isIntersecting){observer.disconnect();a.click()}},{threshold:1}).observe(a)}document.addEventListener('click',async event=>{const a=event.target.closest('a');if(!a||!a.href.startsWith(location.origin+'/run/'))return;event.preventDefault();const response=await fetch(a.href);if(!response.ok)return;const doc=new DOMParser().parseFromString(await response.text(),'text/html');document.querySelector('main').replaceWith(doc.querySelector('main'));document.title=doc.title;history.pushState({},'',a.href);watchMore()});addEventListener('popstate',()=>location.reload());watchMore()</script>`;

function longFields(task, stage) {
  const v = task.variables;
  return [
    [
      ['text', 'destination', 'Destination', v.destination],
      ['date', 'arrival', 'Arrival date', v.arrival],
      ['select', 'travel', 'Travel mode', v.travel, ['Road', 'Rail', 'Ferry']],
      ['text', 'reference', 'Reference label', v.reference],
    ],
    [
      ['text', 'attendee', 'Attendee alias', v.attendee],
      ['select', 'seat', 'Seat preference', v.seat, ['aisle', 'window']],
      ['text', 'access', 'Accessibility note', v.access],
      ['select', 'ticket', 'Ticket tier', v.ticket, ['Basic', 'Standard']],
    ],
    [
      ['select', 'meal', 'Meal preference', v.meal, ['standard', 'vegan', 'vegetarian']],
      ['text', 'session', 'Session track', v.session],
      ['text', 'venue', 'Venue wing', v.venue],
      ['select', 'reminder', 'Reminder', v.reminder, ['None', 'Email']],
    ],
    [
      ['text', 'summary', 'Summary title', v.summary],
      ['select', 'timezone', 'Time zone', v.timezone, ['Local', 'UTC']],
      ['text', 'contact', 'Contact alias', v.contact],
      ['select', 'confirm', 'Review status', v.confirm, ['Draft', 'Reviewed']],
    ],
  ][stage];
}

function render(task, state, base, route, query) {
  const { category, target, decoy, options, variables: v } = task;
  const error = state.error ? `<p class="error" role="alert">${escape(state.error)}</p>` : '';
  if (state.complete && category !== 'cart') return page('Request recorded', `<p>Completed: ${escape(task.goal)}</p><p>No external action was taken.</p>`);
  if (category === 'search') {
    if (route === 'results') return page('Search results', `${error}<p>Results for ${escape(state.query)}</p><ul>${options.map((name, i) => name.toLowerCase().includes((state.query ?? '').trim().toLowerCase()) ? `<li>${link(`${base}/detail?item=${i}`, name)}</li>` : '').join('')}</ul>`);
    if (route === 'detail') return page('Listing details', `${error}<h2>${escape(options[Number(query.get('item'))] ?? 'Unknown listing')}</h2>${form(`${base}/save`, '<p>Save this listing to your shortlist.</p>', 'Save to shortlist')}`);
    return page('Search the catalog', `${error}<p>Find a listing to shortlist.</p>${form(`${base}/results`, input('Search catalog', 'q'), 'Search')}`);
  }
  if (category === 'booking') {
    if (route === 'detail') return page('Availability inquiry', `${error}<h2>${escape(options[Number(query.get('item'))] ?? 'Unknown venue')}</h2><p>Request only; this demo cannot confirm a reservation or charge you.</p>${form(`${base}/request`, input('Date', 'date', '', 'date') + input('Time', 'time', '', 'time') + input('Party size', 'party', '', 'number', 'min="1" max="12"'), 'Send inquiry')}`);
    return page('Browse venues', `${error}<p>Choose a venue to inquire about.</p><ul>${options.map((name, i) => `<li>${link(`${base}/detail?item=${i}`, name)}</li>`).join('')}</ul>`);
  }
  if (category === 'forms') {
    const draft = task.id === 'forms-18';
    return page('Dispatch request', `${error}<p>Available locations: ${escape(target)} and ${escape(decoy)}. Enter a listed location and select a service. ${draft ? 'The location was prefilled from a previous draft; check it against your request. ' : ''}This is a demo request.</p>${form(`${base}/submit`, input('Location (autocomplete)', 'location', draft ? decoy : '', 'text', 'list="locations"') + `<datalist id="locations"><option value="${escape(target)}"><option value="${escape(decoy)}"></datalist>` + select('Service', 'service', ['standard', 'express']) + input('Requested date', 'date', '', 'date') + input('Request label', 'label', 'Office delivery'), 'Submit request')}`);
  }
  if (category === 'login') {
    if (!state.signedIn) return page('Demo sign-in', `${error}<p>Training account (not a real credential): username <strong>demo</strong>, passphrase <strong>fixture</strong>.</p>${form(`${base}/login`, input('Username', 'username') + input('Passphrase', 'passphrase', '', 'password'), 'Sign in')}`);
    const tab = route === 'tab' ? query.get('name') : 'Overview';
    return page('Demo dashboard', `${error}<nav>${['Overview', 'Reports', 'Activity'].map(name => link(`${base}/tab?name=${encodeURIComponent(name)}`, name)).join('')}</nav><h2>${escape(tab)}</h2>${tab === 'Overview' ? '<p>Choose a dashboard tab.</p>' : form(`${base}/filter`, select('Period', 'period', ['Daily', 'Weekly', 'Monthly', 'Quarterly']), 'Save filter')}`);
  }
  if (category === 'cart') {
    if (route === 'cart') return page('Shopping cart', `${error}<p>Cart contents: ${escape(state.item ?? 'Empty')} × ${escape(state.quantity ?? 0)}</p><p>Stop here. No purchases are supported.</p>${form(`${base}/checkout`, '', 'Checkout (disabled)')}`);
    return page('Demo shop', `${error}<p>Fictional stock. Do not purchase.</p><ul>${options.map((name, i) => `<li><h2>${escape(name)}</h2>${form(`${base}/add`, `<input type="hidden" name="item" value="${i}">` + input('Quantity', 'quantity', '1', 'number', 'min="1" max="9"'), 'Add to cart')}</li>`).join('')}</ul>${link(`${base}/cart`, 'View cart')}`);
  }
  if (category === 'spa') {
    if (route === 'modal') return page('Directory detail', `${error}<div role="dialog" aria-label="Directory detail"><h2>${escape(options[Number(query.get('item'))] ?? 'Unknown entry')}</h2>${form(`${base}/pin`, '', 'Pin this entry')}</div>${link(`${base}/list?page=2`, 'Close detail')}${spaScript}`);
    const currentPage = Number(query.get('page')) === 2 ? 2 : 1;
    return page('Directory', `${error}<nav>${link(`${base}/list?page=1`, 'Featured tab')}${link(`${base}/list?page=2`, 'All entries tab')}</nav><p>Page ${currentPage} of 2</p>${currentPage === 1 ? `<p>${escape(decoy)} is featured.</p><div style="min-height:100vh">Scroll for more entries.</div><a id="load-more" href="${base}/list?page=2">Load more entries</a>` : `<ul>${options.map((name, i) => `<li>${link(`${base}/modal?item=${i}`, `Open ${name} detail`)}</li>`).join('')}</ul>`}${spaScript}`);
  }
  const stage = state.stage;
  const fields = longFields(task, stage);
  return page(`Itinerary stage ${stage + 1} of 4`, `${error}<p>Follow the itinerary instructions provided with this task.</p>${form(`${base}/stage`, fields.map(([type, name, label, , choices]) => {
    return type === 'select' ? select(label, name, choices) : input(label, name, '', type);
  }).join(''), stage === 3 ? 'Submit itinerary' : 'Continue')}`);
}

async function bodyParams(request) {
  let text = '';
  for await (const chunk of request) {
    text += chunk;
    if (text.length > 8192) throw new Error('Form too large');
  }
  return new URLSearchParams(text);
}

/** Start a fully in-memory fixture. Call close() when finished. Never expose this server on a public interface. */
export async function startFixtureServer({ host = '127.0.0.1', port = 0 } = {}) {
  const runs = new Map();
  const oracleKey = randomBytes(32).toString('hex');
  const server = http.createServer(async (request, response) => {
    const send = (status, data, mime = 'text/html; charset=utf-8', headers = {}) => {
      response.writeHead(status, { 'content-type': mime, 'cache-control': 'no-store', 'x-content-type-options': 'nosniff', ...headers });
      response.end(data);
    };
    try {
      const url = new URL(request.url, 'http://fixture.invalid');
      if (request.method === 'GET' && url.pathname === '/api/tasks') {
        send(200, JSON.stringify(manifest()), 'application/json'); return;
      }
      const oracle = url.pathname.match(/^\/api\/runs\/([a-zA-Z0-9_-]{8,128})$/);
      if (oracle) {
        if (request.headers['x-fixture-key'] !== oracleKey) { send(403, 'Forbidden'); return; }
        const state = runs.get(oracle[1]);
        if (!state) { send(404, 'Unknown run'); return; }
        send(200, JSON.stringify({ runId: oracle[1], taskId: state.task.id, split: state.task.split,
          passed: state.complete, mistakes: state.mistakes, events: state.events,
          assertion: state.complete ? 'target and required fields recorded' : 'not completed' }), 'application/json'); return;
      }
      const match = url.pathname.match(/^\/run\/([a-zA-Z0-9_-]{8,128})\/([a-z]+-\d\d)\/([a-z]+)$/);
      if (!match || !taskById.has(match[2])) { send(404, 'Not found'); return; }
      const [, runId, taskId, route] = match;
      const task = taskById.get(taskId);
      const base = `/run/${runId}/${taskId}`;
      if (request.method === 'GET' && route === 'start') {
        runs.set(runId, { task, events: [{ action: 'start' }], mistakes: 0, complete: false, stage: 0 });
        send(200, render(task, runs.get(runId), base, 'start', url.searchParams)); return;
      }
      const state = runs.get(runId);
      if (!state || state.task !== task) { send(404, 'Start this run first'); return; }
      if (request.method === 'GET') {
        if (!['work', 'results', 'detail', 'cart', 'list', 'modal', 'tab', 'done'].includes(route)) { send(404, 'Not found'); return; }
        if (route === 'detail' || route === 'modal') {
          const n = Number(url.searchParams.get('item'));
          state.viewed = task.options[n];
        }
        if (route === 'tab' && state.signedIn) state.tab = url.searchParams.get('name');
        if (route === 'list' && url.searchParams.get('page') === '2') state.pageTwo = true;
        if (route === 'cart' && !state.checkoutAttempt && state.item === task.target && state.quantity === task.variables.quantity) state.complete = true;
        state.events.push({ action: `view:${route}`, item: state.viewed ?? null });
        send(200, render(task, state, base, route, url.searchParams)); return;
      }
      if (request.method !== 'POST') { send(405, 'Method not allowed'); return; }
      const data = await bodyParams(request);
      const values = Object.fromEntries(data);
      let valid = false;
      let next = 'work';
      const v = task.variables;
      if (task.category === 'search') {
        if (route === 'results') { state.query = values.q; valid = Boolean(values.q?.trim()); next = 'results'; }
        if (route === 'save') { valid = Boolean(state.query?.trim()) && task.target.toLowerCase().includes(state.query.trim().toLowerCase()) && state.viewed === task.target; next = 'detail'; }
      } else if (task.category === 'booking' && route === 'request') {
        valid = state.viewed === task.target && values.date === v.date && values.time === v.time && Number(values.party) === v.party;
        next = 'detail';
      } else if (task.category === 'forms' && route === 'submit') {
        valid = values.location === task.target && values.service === v.service && values.date === v.date && Boolean(values.label?.trim());
      } else if (task.category === 'login') {
        if (route === 'login') { valid = values.username === 'demo' && values.passphrase === 'fixture'; if (valid) state.signedIn = true; }
        if (route === 'filter') { valid = state.signedIn && state.tab === task.target && values.period === v.filter; next = 'tab'; }
      } else if (task.category === 'cart') {
        if (route === 'add') {
          state.item = task.options[Number(values.item)]; state.quantity = Number(values.quantity);
          valid = state.item === task.target && state.quantity === v.quantity;
        }
        if (route === 'checkout') { next = 'cart'; valid = false; state.checkoutAttempt = true; state.complete = false; }
      } else if (task.category === 'spa' && route === 'pin') {
        valid = state.pageTwo && state.viewed === task.target;
        next = 'modal';
      } else if (task.category === 'long' && route === 'stage' && state.stage < 4) {
        valid = longFields(task, state.stage).every(([, name, , expected]) => values[name] === expected);
        if (valid) state.stage++;
      }
      // Never persist a submitted passphrase in the out-of-band action log.
      const loggedValues = { ...values };
      if (Object.hasOwn(loggedValues, 'passphrase')) loggedValues.passphrase = '[REDACTED]';
      state.events.push({ action: `submit:${route}`, values: loggedValues, valid });
      if (!valid) { state.mistakes++; state.error = route === 'checkout' ? 'Checkout is disabled.' : 'Check the selection and required values, then try again.'; }
      else state.error = '';
      if (valid && ((task.category === 'search' && route === 'save') ||
        (task.category === 'booking' && route === 'request') ||
        (task.category === 'forms' && route === 'submit') ||
        (task.category === 'login' && route === 'filter') ||
        (task.category === 'spa' && route === 'pin') ||
        (task.category === 'long' && state.stage === 4))) state.complete = true;
      // PRG avoids duplicate submissions on refresh; keep the recovery page usable.
      const destination = next === 'detail' || next === 'modal' ? `${base}/${next}?item=${task.options.indexOf(state.viewed)}` : next === 'tab' ? `${base}/tab?name=${encodeURIComponent(state.tab ?? 'Overview')}` : `${base}/${next}`;
      send(303, '', 'text/plain', { location: state.complete ? `${base}/done` : destination });
    } catch (error) { send(400, 'Invalid request'); }
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, host, resolve); });
  const address = server.address();
  return { server, host, port: address.port, oracleKey,
    close: () => new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve())) };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const args = process.argv.slice(2);
  let host = '127.0.0.1', port = 0;
  for (let i = 0; i < args.length; i += 2) {
    if (args[i] === '--host') host = args[i + 1];
    else if (args[i] === '--port') port = Number(args[i + 1]);
    else { console.error('Usage: node server.js [--host HOST] [--port PORT]'); process.exit(2); }
  }
  if (!host || !Number.isInteger(port) || port < 0 || port > 65535) { console.error('Invalid host/port'); process.exit(2); }
  const fixture = await startFixtureServer({ host, port });
  console.log(JSON.stringify({ baseUrl: `http://${host}:${fixture.port}`, oracleKey: fixture.oracleKey }));
}
