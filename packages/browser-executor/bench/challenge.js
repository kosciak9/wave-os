// Additional synthetic diagnostic layouts. The frozen 30-task manifest and
// its oracle state are independent of these namespaced routes.
const tasks = [
  { id: 'challenge-31', category: 'challenge', split: 'authored-challenge',
    goal: 'Submit a two-stage demo delivery request for Pine Archive, express, on 2028-03-04; review and confirm with label Parcel note.',
    variables: { location: 'Pine Archive', service: 'express', date: '2028-03-04', summary: 'Parcel note' }, max_steps: 24 },
  { id: 'challenge-32', category: 'challenge', split: 'authored-challenge',
    goal: 'In the demo directory, select the Coral Workshop card and submit its inquiry; do not select the adjacent card.',
    variables: { target: 'Coral Workshop' }, max_steps: 24 },
  { id: 'challenge-33', category: 'challenge', split: 'authored-challenge',
    goal: 'Open Harbor Studio detail from the catalog, select Express service in the modal, then submit the demo request.',
    variables: { target: 'Harbor Studio', service: 'Express' }, max_steps: 24 },
];
const escape = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const page = (heading, contents) => `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>${escape(heading)}</title></head><body><main><h1>${escape(heading)}</h1>${contents}</main></body></html>`;
const field = (label, name, value = '') => `<label>${escape(label)} <input name="${name}" value="${escape(value)}" required></label>`;
const form = (url, body, button) => `<form method="post" action="${url}">${body}<button>${escape(button)}</button></form>`;
const link = (url, label) => `<a href="${url}">${escape(label)}</a>`;

export function createChallenge(oracleKey) {
  const runs = new Map();
  return async (request, response, url) => {
    const send = (status, body, type = 'text/html; charset=utf-8', headers = {}) => {
      response.writeHead(status, { 'content-type': type, 'cache-control': 'no-store', ...headers }); response.end(body);
    };
    if (request.method === 'GET' && url.pathname === '/api/challenge/tasks') {
      send(200, JSON.stringify(tasks), 'application/json'); return true;
    }
    const oracle = url.pathname.match(/^\/api\/challenge\/runs\/([\w-]{8,128})$/);
    if (oracle) {
      if (request.headers['x-fixture-key'] !== oracleKey) send(403, 'Forbidden');
      else if (!runs.has(oracle[1])) send(404, 'Unknown run');
      else { const s = runs.get(oracle[1]); send(200, JSON.stringify({ passed: s.complete, mistakes: s.mistakes, events: s.events }), 'application/json'); }
      return true;
    }
    const match = url.pathname.match(/^\/run\/([\w-]{8,128})\/(challenge-3[123])\/([a-z]+)$/);
    if (!match) return false;
    const [, runId, id, route] = match;
    const task = tasks.find(t => t.id === id);
    const base = `/run/${runId}/${id}`;
    if (request.method === 'GET' && route === 'start' && !runs.has(runId))
      runs.set(runId, { task, stage: 0, complete: false, mistakes: 0, events: [{ action: 'start' }] });
    const s = runs.get(runId);
    if (!s || s.task !== task) { send(404, 'Start this run first'); return true; }
    if (request.method === 'GET') {
      let html;
      if (route === 'done' && s.complete) html = page('Receipt verified', '<p>Final demo request accepted.</p>');
      else if (id === 'challenge-31') {
        html = s.stage === 0 ? page('Dispatch stage 1 of 2', form(`${base}/advance`,
          field('Location', 'location') + '<label>Service <select name="service"><option>standard</option><option>express</option></select></label>' +
          '<label>Requested date <input type="date" name="date" required></label>', 'Continue')) :
          page('Dispatch review stage 2 of 2', `<p>Completed: draft details entered. Final confirmation is still required.</p>` +
          form(`${base}/finish`, field('Confirmation label', 'summary'), 'Confirm demo request'));
      } else if (id === 'challenge-32') html = page('Directory cards',
        ['Quartz Workshop', 'Coral Workshop'].map((name, n) => `<section><h2>${name}</h2>${form(`${base}/choose`,
          `<input type="hidden" name="item" value="${n}">` + field('Request label', 'label', 'Demo inquiry'), 'Send inquiry')}</section>`).join(''));
      else html = route === 'detail' ? page('Studio request modal', `<div role="dialog" aria-label="Studio request"><h2>Harbor Studio</h2>` +
        form(`${base}/finish`, '<label>Service <select name="service"><option>Standard</option><option>Express</option></select></label>', 'Submit demo request') + '</div>') :
        page('Studio catalog', `<h2>Haven Studio</h2>${link(`${base}/other`, 'Open Haven Studio detail')}<h2>Harbor Studio</h2>${link(`${base}/detail`, 'Open Harbor Studio detail')}`);
      if (id === 'challenge-33' && route === 'detail') s.stage = 1;
      s.events.push({ action: `view:${route}` }); send(200, html); return true;
    }
    if (request.method !== 'POST') { send(405, 'Method not allowed'); return true; }
    let body = '';
    for await (const chunk of request) { body += chunk; if (body.length > 8192) { send(413, 'Too large'); return true; } }
    const values = Object.fromEntries(new URLSearchParams(body));
    const valid = id === 'challenge-31' ? route === 'advance' && s.stage === 0 &&
      values.location === task.variables.location && values.service === task.variables.service && values.date === task.variables.date ||
      route === 'finish' && s.stage === 1 && values.summary === task.variables.summary :
      id === 'challenge-32' ? route === 'choose' && values.item === '1' && Boolean(values.label?.trim()) :
      route === 'finish' && s.stage === 1 && values.service === task.variables.service;
    s.events.push({ action: `submit:${route}`, values, valid });
    if (valid && id === 'challenge-31' && route === 'advance') s.stage = 1;
    else if (valid) s.complete = true;
    else s.mistakes++;
    send(303, '', 'text/plain', { location: s.complete ? `${base}/done` : `${base}/${id === 'challenge-31' ? 'review' : id === 'challenge-32' ? 'start' : 'detail'}` });
    return true;
  };
}
