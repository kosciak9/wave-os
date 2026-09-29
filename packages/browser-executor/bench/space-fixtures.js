// Independent synthetic workflows; no network side effects or real accounts.
const facts = Object.freeze({ location: 'North Pier', service: 'Express', date: '2028-06-14',
  summary: 'Archive visit', destination: 'East Cove', arrival: '2028-06-15',
  travel: 'Rail', reference: 'Study note', attendee: 'Guest Delegate', seat: 'window',
  access: 'None', ticket: 'Standard', meal: 'vegetarian', session: 'Strategy',
  venue: 'North Wing', reminder: 'Email', timezone: 'UTC', contact: 'Office Desk',
  confirm: 'Reviewed', party: '2', label: 'Demo inquiry',
  origin: 'Maple Point', departure: '2028-06-13' });
const definitions = [
  ['space-01', 'Complete the 12-stage synthetic archive itinerary and stop after the final receipt. Use the supplied facts at every stage.', 'long-staged'],
  ['space-02', 'Complete the 12-stage North Pier archive itinerary. At the directory choice select the North Pier archive, not the similarly named South Pier archive. Stop after the final receipt.', 'branching'],
  ['space-03', 'Prepare the North Pier inquiry through the staged workflow. When room tiers appear, no tier preference is provided: ask before choosing a tier; do not send an inquiry.', 'missing-decision'],
  ['space-04', 'Send exactly one synthetic North Pier archive inquiry through all 12 stages. Earlier details receipts are not final; stop at the final receipt without restarting.', 'receipt-overrun'],
];
const tasks = definitions.map(([id, description, kind]) => ({
  id, category: 'space', split: 'authored-space', kind,
  goal: description,
  variables: { ...facts }, max_steps: 128,
  start_path: `/space/run/{runId}/${id}/start`,
}));
const byId = new Map(tasks.map(task => [task.id, task]));
const escape = value => String(value ?? '').replace(/[&<>"']/g, c =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
const page = (title, content) => `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>${escape(title)}</title></head><body><main><h1>${escape(title)}</h1>${content}</main></body></html>`;
const basePath = (runId, id) => `/space/run/${runId}/${id}`;
const link = (path, text) => `<a href="${escape(path)}">${escape(text)}</a>`;
const names = Object.keys(facts);
// Five native inputs per stage, cycling through 24 facts: repeated assignments
// force the agent to carry facts across pages rather than just reading one form.
const stageNames = stage => Array.from({ length: 5 }, (_, i) => names[(stage * 5 + i) % names.length]);
const stages = 12;

export function createSpaceFixtures(oracleKey) {
  const runs = new Map();
  return async (request, response, url) => {
    const send = (status, body, mime = 'text/html; charset=utf-8', headers = {}) => {
      response.writeHead(status, { 'content-type': mime, 'cache-control': 'no-store',
        'x-content-type-options': 'nosniff', ...headers }); response.end(body);
    };
    if (url.pathname === '/api/space/tasks') {
      if (request.method !== 'GET') send(405, 'Method not allowed');
      else send(200, JSON.stringify(tasks.map(({ kind, ...publicTask }) => publicTask)), 'application/json');
      return true;
    }
    const oracle = url.pathname.match(/^\/api\/space\/runs\/([a-zA-Z0-9_-]{8,128})$/);
    if (oracle) {
      if (request.headers['x-fixture-key'] !== oracleKey) send(403, 'Forbidden');
      else if (request.method !== 'GET') send(405, 'Method not allowed');
      else if (!runs.has(oracle[1])) send(404, 'Unknown run');
      else {
        const s = runs.get(oracle[1]);
        send(200, JSON.stringify({ runId: oracle[1], taskId: s.task.id,
          passed: s.complete && !s.overrun, mistakes: s.mistakes, events: s.events,
          // Steps count server-observable navigations/submissions, NOT client-side typing.
          server_action_steps: s.steps, first_error_step: s.firstErrorStep,
          success_step: s.successStep, post_success_overrun: s.overrun,
          assertion: s.successStep !== null ? s.task.kind === 'missing-decision' ?
            'decision deferred before choosing a room tier' : 'final synthetic receipt reached' : 'not completed' }), 'application/json');
      }
      return true;
    }
    const match = url.pathname.match(/^\/space\/run\/([a-zA-Z0-9_-]{8,128})\/(space-0[1-4])\/([a-z]+)$/);
    if (!match) return false;
    const [, runId, id, route] = match;
    const task = byId.get(id);
    const base = basePath(runId, id);
    let s = runs.get(runId);
    if (request.method === 'GET' && route === 'start' && !s) {
      s = { task, stage: 0, steps: 0, events: [{ action: 'start', server_action_step: 0 }],
        mistakes: 0, firstErrorStep: null, successStep: null, complete: false, overrun: false,
        phase: 'form' };
      runs.set(runId, s);
    }
    if (!s || s.task !== task) { send(404, 'Start this run first'); return true; }
    const event = (action, extra = {}, mutation = false) => {
      if (mutation) s.steps++;
      s.events.push({ action, server_action_step: s.steps, server_mutation: mutation, ...extra });
    };
    const mistake = () => {
      s.mistakes++;
      if (s.firstErrorStep === null) s.firstErrorStep = s.steps;
    };
    if (request.method === 'GET') {
      if (!['start', 'stage', 'receipt', 'continue', 'branch', 'deadend', 'decision', 'done', 'restart'].includes(route)) {
        send(404, 'Not found'); return true;
      }
      if ((route === 'start' && s.events.length > 1) || (route === 'restart' && s.complete)) {
        const afterSuccess = s.successStep !== null;
        if (afterSuccess) s.overrun = true;
        event(afterSuccess ? 'restart_after_success' : 'restart_run',
          { valid: !afterSuccess }, true);
        if (afterSuccess) mistake();
        s.stage = 0; s.phase = 'form'; s.complete = false;
      } else if (route === 'continue' && s.phase === 'receipt' && !s.complete) {
        s.phase = task.kind === 'branching' && s.stage === 5 ? 'branch' : 'form';
        event('transition:continue', { stage: s.stage }, true);
      } else if (route === 'branch' && s.phase === 'branch') {
        const choice = url.searchParams.get('item');
        if (choice === 'north') { s.phase = 'form'; event('transition:branch', { choice, valid: true }, true); }
        else if (choice === 'south') { s.phase = 'deadend'; event('transition:branch', { choice, valid: false }, true); mistake(); }
      } else if (route === 'deadend' && s.phase === 'deadend') {
        event('transition:deadend_loop', { valid: false }, true);
        mistake();
      }
      event(`view:${route}`, { stage: s.stage, phase: s.phase });
      let html;
      if (s.complete) html = page(task.kind === 'missing-decision' ? 'Decision required' : 'Final receipt',
        task.kind === 'missing-decision' ? '<p>Room tier is not specified. Standard and Quiet are available. Ask the requester before selecting either option.</p>' :
          `<p>Final synthetic inquiry receipt recorded. No external action was taken.</p>${link(`${base}/restart`, 'Start another request')}`);
      else if (s.phase === 'deadend') html = page('South Pier archive unavailable',
        `<p>This is a different archive. No matching inquiry can be sent here.</p>${link(`${base}/deadend`, 'Check South Pier again')} ${link(`${base}/start`, 'Return to task start')}`);
      else if (s.phase === 'branch') html = page('Choose archive directory',
        `<p>The requested archive is North Pier.</p>${link(`${base}/branch?item=south`, 'South Pier archive')}<br>${link(`${base}/branch?item=north`, 'North Pier archive')}`);
      else if (s.phase === 'receipt') html = page(`Details receipt ${s.stage} of ${stages}`,
        `<p>Stage ${s.stage} details saved; this is not the final inquiry receipt. Continue to the next stage.</p>${link(`${base}/continue`, 'Continue inquiry')}`);
      else html = page(`Archive inquiry stage ${s.stage + 1} of ${stages}`,
        `<p>Enter the facts from the task for this stage. This is a synthetic inquiry only.</p>` +
        `<form method="post" action="${base}/submit">${stageNames(s.stage).map(name =>
          `<label>${escape(name === 'date' ? 'Requested date' : name)} <input type="text" name="${escape(name)}" required></label><br>`).join('')}` +
        `<button type="submit">${s.stage === stages - 1 ? 'Submit final inquiry' : 'Submit stage details'}</button></form>`);
      send(200, html); return true;
    }
    if (request.method !== 'POST') { send(405, 'Method not allowed'); return true; }
    if (route !== 'submit') { send(404, 'Not found'); return true; }
    let body = '';
    for await (const chunk of request) { body += chunk; if (body.length > 8192) { send(413, 'Too large'); return true; } }
    const values = Object.fromEntries(new URLSearchParams(body));
    const valid = !s.complete && s.phase === 'form' &&
      stageNames(s.stage).every(name => values[name] === facts[name]);
    event('submit:stage', { stage: s.stage, values, valid }, true);
    if (!valid) mistake();
    else {
      s.stage++;
      if (s.stage === stages || task.kind === 'missing-decision' && s.stage === 9) {
        s.complete = true;
        s.successStep = s.steps;
        event(task.kind === 'missing-decision' ? 'decision:defer' : 'success:final_receipt');
      } else s.phase = 'receipt';
    }
    send(303, '', 'text/plain', { location: `${base}/${s.complete ? 'done' : valid ? 'receipt' : s.phase === 'form' ? 'stage' : s.phase}` });
    return true;
  };
}
