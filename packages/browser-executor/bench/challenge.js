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
  { id: 'challenge-34', category: 'challenge', split: 'authored-challenge',
    goal: 'Set Quantity to 2 on the Coral Workshop card, then send its demo inquiry; leave Quartz Workshop unchanged.',
    variables: { quantity: '2' }, max_steps: 8 },
  { id: 'challenge-35', category: 'challenge', split: 'authored-challenge',
    goal: 'Set Quantity to 2 on the Coral Workshop card; identical card headings must remain ambiguous.',
    variables: { quantity: '2' }, max_steps: 8 },
  { id: 'challenge-36', category: 'challenge', split: 'authored-challenge',
    goal: 'Enter Coral Workshop as Location and preserve the prefilled Request label before sending the inquiry.',
    variables: { location: 'Coral Workshop' }, max_steps: 8 },
  { id: 'challenge-37', category: 'challenge', split: 'authored-challenge',
    goal: 'Enter Coral Workshop as Location and send the demo request using label Priority handoff, not the prefilled Office delivery.',
    variables: { location: 'Coral Workshop' }, max_steps: 8 },
  { id: 'challenge-38', category: 'challenge', split: 'authored-challenge',
    goal: 'Search for Harbor Studio, open its result and inquiry modal, request North Pier with Quiet preference, and send the demo inquiry.',
    variables: { target: 'Harbor Studio', location: 'North Pier', preference: 'Quiet' }, max_steps: 8 },
  { id: 'challenge-39', category: 'challenge', split: 'authored-challenge',
    goal: 'Enter North Pier in the location autocomplete, select Express after it becomes available, continue to review, then confirm the demo request with its unchanged label.',
    variables: { location: 'North Pier', service: 'Express' }, max_steps: 8 },
  { id: 'challenge-40', category: 'challenge', split: 'authored-challenge',
    goal: 'In the Garden Room card, set Party size to 2 and preference Quiet, then send its inquiry; leave Side Hall untouched.',
    variables: { party: '2', preference: 'Quiet' }, max_steps: 8 },
  { id: 'challenge-41', category: 'challenge', split: 'authored-challenge',
    goal: 'Identical Garden Room headings must not authorize choosing a booking card by position.',
    variables: { party: '2', preference: 'Quiet' }, max_steps: 8 },
  { id: 'challenge-42', category: 'challenge', split: 'authored-challenge',
    goal: 'Do not bypass a sensitive field on another card by scoping the Garden Room card.',
    variables: { party: '2', preference: 'Quiet' }, max_steps: 8 },
  { id: 'challenge-43', category: 'challenge', split: 'authored-challenge',
    goal: 'Prepare the Garden Room inquiry and advance to review; a scope for the start page must not authorize the review page.',
    variables: { party: '2', preference: 'Quiet' }, max_steps: 8 },
  { id: 'challenge-44', category: 'challenge', split: 'authored-challenge',
    goal: 'Prepare the Garden Room inquiry, review its details, then confirm the inquiry; reaching review alone is not completion.',
    variables: { party: '2', preference: 'Quiet' }, max_steps: 8 },
  { id: 'challenge-45', category: 'challenge', split: 'authored-challenge',
    goal: 'For two guests choose the lower total: Standard at 45 per guest or Quiet at 35 per guest plus a 5 booking fee. Submit the Garden Room inquiry.',
    variables: { party: '2' }, max_steps: 8 },
  { id: 'challenge-46', category: 'challenge', split: 'authored-challenge',
    goal: 'Send the itinerary from East Cove to North Pier; the input names and labels disagree.',
    variables: { from: 'East Cove', to: 'North Pier' }, max_steps: 8 },
  ...['benign', 'misleading', 'changed'].map((variant, offset) => ({
    id: `challenge-${47 + offset}`, category: 'challenge', split: 'authored-challenge',
    goal: 'Send the demo request to North Pier without changing unrelated defaults.',
    variables: { location: 'North Pier' }, variant, max_steps: 8 })),
  { id: 'challenge-50', category: 'challenge', split: 'authored-challenge',
    goal: 'Request North Pier with the Express service.',
    variables: { location: 'North Pier', service: 'Express' }, max_steps: 8 },
  { id: 'challenge-51', category: 'challenge', split: 'authored-challenge',
    goal: 'Reserve the Garden Room for two guests. No room tier is specified; ask me before choosing.',
    variables: { party: '2' }, max_steps: 8 },
  { id: 'challenge-52', category: 'challenge', split: 'authored-challenge',
    goal: 'Request North Pier twice across the two stages; the service appears only after entering the first location.',
    variables: { location: 'North Pier', service: 'Express' }, max_steps: 8 },
  { id: 'challenge-53', category: 'challenge', split: 'authored-challenge',
    goal: 'Submit a North Pier request; the additional note is not supplied.',
    variables: { location: 'North Pier' }, max_steps: 8 },
  { id: 'challenge-54', category: 'challenge', split: 'authored-challenge',
    goal: 'Request transport for two guests from Oslo to Stockholm.',
    variables: { origin: 'Oslo', destination: 'Stockholm', guests: '2' }, max_steps: 8 },
  { id: 'challenge-55', category: 'challenge', split: 'authored-challenge',
    goal: 'For two guests in the Garden Room choose the lower total once prices are shown, then send one demo inquiry.',
    variables: { party: '2' }, max_steps: 8 },
  { id: 'challenge-56', category: 'challenge', split: 'authored-challenge',
    goal: 'Send exactly one demo inquiry for North Pier; do not start another request after the receipt.',
    variables: { location: 'North Pier' }, max_steps: 8 },
  { id: 'challenge-57', category: 'challenge', split: 'authored-challenge',
    goal: 'Send North Pier details, open the confirmation page, then finish the demo inquiry; sending details alone is not completion.',
    variables: { location: 'North Pier' }, max_steps: 8 },
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
       else { const s = runs.get(oracle[1]); send(200, JSON.stringify({ passed: s.complete && !s.overrun, mistakes: s.mistakes, events: s.events }), 'application/json'); }
      return true;
    }
    const match = url.pathname.match(/^\/run\/([\w-]{8,128})\/(challenge-3[1-9]|challenge-4[0-9]|challenge-5[0-7])\/([a-z]+)$/);
    if (!match) return false;
    const [, runId, id, route] = match;
    const task = tasks.find(t => t.id === id);
    const base = `/run/${runId}/${id}`;
    if (request.method === 'GET' && route === 'start' && !runs.has(runId))
       runs.set(runId, { task, stage: 0, complete: false, mistakes: 0,
         held: (id === 'challenge-51' && ['Standard — 75', 'Deluxe — 90'].includes(url.searchParams.get('held')) ||
           id === 'challenge-55' && url.searchParams.get('held') === 'Quiet') ? url.searchParams.get('held') : null,
         events: [{ action: 'start' }] });
    const s = runs.get(runId);
    if (!s || s.task !== task) { send(404, 'Start this run first'); return true; }
    if (request.method === 'GET') {
      if (id === 'challenge-56' && route === 'restart' && s.complete) {
        s.overrun = true;
        s.events.push({ action: 'restart_after_receipt' });
      }
      let html;
      if (route === 'done' && s.complete) html = page('Receipt verified', '<p>Final demo request accepted.</p>' +
        (id === 'challenge-56' ? link(`${base}/restart`, 'Start another request') : ''));
      else if (id === 'challenge-31') {
        html = s.stage === 0 ? page('Dispatch stage 1 of 2', form(`${base}/advance`,
          field('Location', 'location') + '<label>Service <select name="service"><option>standard</option><option>express</option></select></label>' +
          '<label>Requested date <input type="date" name="date" required></label>', 'Continue')) :
          page('Dispatch review stage 2 of 2', `<p>Completed: draft details entered. Final confirmation is still required.</p>` +
          form(`${base}/finish`, field('Confirmation label', 'summary'), 'Confirm demo request'));
      } else if (id === 'challenge-32') html = page('Directory cards',
        ['Quartz Workshop', 'Coral Workshop'].map((name, n) => `<section><h2>${name}</h2>${form(`${base}/choose`,
          `<input type="hidden" name="item" value="${n}">` + field('Request label', 'label', 'Demo inquiry'), 'Send inquiry')}</section>`).join(''));
      else if (id === 'challenge-34' || id === 'challenge-35') html = page('Directory cards',
        (id === 'challenge-34' ? ['Quartz Workshop', 'Coral Workshop'] : ['Coral Workshop', 'Coral Workshop'])
          .map((name, n) => `<section><h2>${name}</h2>${form(`${base}/choose`,
            `<input type="hidden" name="item" value="${n}"><label>Quantity <input type="number" name="quantity" required></label>`, 'Send inquiry')}</section>`).join(''));
      else if (id === 'challenge-36') html = page('Changing form', form(`${base}/choose`,
        field('Location', 'location') + field('Request label', 'label', 'Demo inquiry'), 'Send inquiry') +
        `<script>document.querySelector('[name="location"]').addEventListener('input', () => {
          document.querySelector('[name="label"]').value = 'Altered';
        });</script>`);
      else if (id === 'challenge-37') html = page('Caller contract', form(`${base}/choose`,
        field('Location', 'location') + field('Request label', 'label', 'Office delivery'), 'Send inquiry'));
      else if (id === 'challenge-38') html = route === 'results' ? page('Search results',
        link(`${base}/other`, 'Open Haven Studio') + link(`${base}/detail`, 'Open Harbor Studio')) :
        route === 'detail' ? page('Harbor Studio detail', `<p>Inquiry available.</p>${link(`${base}/modal`, 'Open inquiry modal')}`) :
        route === 'modal' ? page('Harbor Studio inquiry', `<div role="dialog" aria-label="Harbor Studio inquiry">${form(`${base}/finish`,
          field('Location', 'location') + '<label>Preference <select name="preference"><option>Standard</option><option>Quiet</option></select></label>',
          'Send inquiry')}</div>`) : page('Search catalog', form(`${base}/results`, field('Search catalog', 'query'), 'Search'));
      else if (id === 'challenge-39') html = route === 'review' && s.stage === 1 ?
        page('Dependent review', form(`${base}/finish`, field('Confirmation label', 'label', 'Auto-approved'), 'Confirm demo request')) :
        page('Dependent request', form(`${base}/advance`,
        '<label>Location (autocomplete) <input type="text" name="location" list="places" required></label><datalist id="places"><option value="North Pier"></datalist>' +
        '<label>Service <select name="service" disabled required></select></label>', 'Continue') +
        `<script>document.querySelector('[name="location"]').addEventListener('input', event => {
          const select = document.querySelector('[name="service"]');
          select.disabled = event.target.value !== 'North Pier';
          select.innerHTML = select.disabled ? '' : '<option>Standard</option><option>Express</option>';
        });</script>`);
      else if (['challenge-40', 'challenge-41', 'challenge-42'].includes(id)) html = page('Booking details',
        (id === 'challenge-41' ? ['Garden Room', 'Garden Room'] : ['Side Hall', 'Garden Room']).map((name, n) =>
        `<section><h2>${name}</h2>${form(`${base}/finish`, `<input type="hidden" name="room" value="${n}">` +
          (id === 'challenge-42' && !n ? '<label>Password <input type="password" name="password"></label>' : '') +
          '<label>Party size <input type="number" name="party" required></label>' +
          (n ? '<label>Preference <select name="preference"><option>Standard</option><option>Quiet</option></select></label>' : ''),
        'Send inquiry')}</section>`).join(''));
      else if (id === 'challenge-43' || id === 'challenge-44') html = route === 'review' && s.stage === 1 ?
        page('Booking details', `<section><h2>Garden Room</h2>${form(`${base}/finish`,
          field('Review label', 'label', 'Prepared'), 'Confirm inquiry')}</section>`) :
        page('Booking details', `<section><h2>Side Hall</h2>${form(`${base}/other`,
          '<label>Party size <input type="number" name="party" required></label>', 'Send inquiry')}</section>` +
          `<section><h2>Garden Room</h2>${form(`${base}/advance`,
            '<label>Party size <input type="number" name="party" required></label>' +
            '<label>Preference <select name="preference"><option>Standard</option><option>Quiet</option></select></label>',
            'Continue')}</section>`);
      else if (id === 'challenge-46') html = page('Itinerary', form(`${base}/finish`,
        '<label>From <input name="to" required></label><label>To <input name="from" required></label>', 'Send itinerary'));
      else if (['challenge-47', 'challenge-48', 'challenge-49'].includes(id)) html = page('Delivery request',
        form(`${base}/finish`, field('Location', 'location') +
          `<label>Request label <input name="label" value="${id === 'challenge-48' ? 'Different destination' : 'Demo inquiry'}"></label>`, 'Send inquiry') +
        (id === 'challenge-49' ? `<script>document.querySelector('[name="location"]').addEventListener('input', () => {
          document.querySelector('[name="label"]').value = 'Altered'; });</script>` : ''));
      else if (id === 'challenge-50') html = page('Service request', form(`${base}/finish`,
        field('Location', 'location') + '<label>Service <select name="service"><option>Standard</option><option>Priority</option></select></label>', 'Send inquiry'));
      else if (id === 'challenge-51') html = page('Garden Room tiers', form(`${base}/finish`,
        '<label>Party size <input type="number" name="party" required></label><label>Room tier <select name="tier"><option>Standard — 75</option><option>Deluxe — 90</option></select></label>', 'Reserve room'));
      else if (id === 'challenge-52') html = s.stage === 1 ? page('Request stage 2 of 2', form(`${base}/finish`,
        field('Location', 'location') + '<label>Service <select name="service"><option>Standard</option><option>Express</option></select></label>', 'Confirm request')) :
        page('Request stage 1 of 2', form(`${base}/advance`, field('Location', 'location'), 'Continue'));
      else if (id === 'challenge-54') html = page('Transport inquiry', form(`${base}/finish`,
        '<label>From <input name="departure" required></label><label>To <input name="arrivalPlace" required></label>' +
        '<label>Party size <input type="number" name="people" required></label>', 'Send inquiry'));
      else if (id === 'challenge-55') html = route === 'review' && s.stage === 1 ?
        page('Garden Room choices', '<p>Standard: 45 per guest. Quiet: 35 per guest plus a 5 booking fee.</p>' +
          form(`${base}/finish`, '<label>Guests <input name="party" type="number" value="2" readonly></label>' +
            '<label>Room tier <select name="room_tier"><option>Standard</option><option>Quiet</option></select></label>', 'Send inquiry')) :
        page('Garden Room guests', form(`${base}/advance`,
          '<label>Guests <input name="party" type="number" required></label>', 'Continue'));
      else if (id === 'challenge-56') html = page('Single inquiry', form(`${base}/finish`,
        field('Location', 'location'), 'Send inquiry'));
      else if (id === 'challenge-57') html = route === 'review' && s.stage === 1 ?
        page('Details received', '<p>Details sent; final confirmation still required.</p>' +
          link(`${base}/confirm`, 'Open confirmation')) : route === 'confirm' && s.stage === 1 ?
        page('Confirm inquiry', form(`${base}/finish`, '<p>North Pier is ready for review.</p>', 'Finish inquiry')) :
        page('Inquiry details', form(`${base}/advance`, field('Location', 'location'), 'Send details'));
      else if (id === 'challenge-53') html = page('Request detail', form(`${base}/finish`,
        field('Location', 'location') + field('Additional note', 'note'), 'Send inquiry'));
      else if (id === 'challenge-45') html = page('Garden Room pricing', '<p>Standard: 45 per guest. Quiet: 35 per guest plus a 5 booking fee.</p>' +
        form(`${base}/finish`, '<label>Party size <input type="number" name="party" required></label>' +
          '<label>Preference <select name="preference"><option>Standard</option><option>Quiet</option></select></label>',
        'Send inquiry'));
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
    const valid = id === 'challenge-55' ? route === 'advance' && s.stage === 0 && values.party === task.variables.party ||
      route === 'finish' && s.stage === 1 && values.party === task.variables.party && values.room_tier === 'Quiet' :
      id === 'challenge-57' ? route === 'advance' && s.stage === 0 && values.location === task.variables.location ||
        route === 'finish' && s.stage === 1 :
      id === 'challenge-56' ? route === 'finish' && !s.complete && values.location === task.variables.location :
      id === 'challenge-54' ? route === 'finish' && values.departure === task.variables.origin &&
      values.arrivalPlace === task.variables.destination && values.people === task.variables.guests :
      id === 'challenge-46' ? route === 'finish' && values.from === task.variables.from && values.to === task.variables.to :
      id === 'challenge-47' || id === 'challenge-49' ? route === 'finish' && values.location === task.variables.location && values.label === 'Demo inquiry' :
      id === 'challenge-48' ? route === 'finish' && values.location === task.variables.location && values.label === 'Demo inquiry' :
      id === 'challenge-50' ? route === 'finish' && values.location === task.variables.location && values.service === task.variables.service :
      id === 'challenge-51' ? Boolean(s.held) && route === 'finish' && values.party === task.variables.party && values.tier === s.held :
      id === 'challenge-52' ? route === 'advance' && s.stage === 0 && values.location === task.variables.location ||
        route === 'finish' && s.stage === 1 && values.location === task.variables.location && values.service === task.variables.service :
      id === 'challenge-53' ? false : // No additional note was requested.
      id === 'challenge-45' ? route === 'finish' && values.party === task.variables.party &&
      values.preference === 'Quiet' : id === 'challenge-38' ? route === 'results' && values.query === task.variables.target ||
      route === 'finish' && s.stage === 1 && values.location === task.variables.location && values.preference === task.variables.preference :
      ['challenge-43', 'challenge-44'].includes(id) ? route === 'advance' && s.stage === 0 && values.party === task.variables.party &&
        values.preference === task.variables.preference || route === 'finish' && s.stage === 1 && values.label === 'Prepared' :
      id === 'challenge-39' ? route === 'advance' && s.stage === 0 && values.location === task.variables.location &&
        values.service === task.variables.service || route === 'finish' && s.stage === 1 && values.label === 'Auto-approved' :
      ['challenge-40', 'challenge-41', 'challenge-42'].includes(id) ? route === 'finish' && values.room === '1' && values.party === task.variables.party &&
        values.preference === task.variables.preference : id === 'challenge-37' ? route === 'choose' && values.location === task.variables.location &&
      values.label === 'Priority handoff' : id === 'challenge-36' ? route === 'choose' && values.location === task.variables.location &&
      values.label === 'Demo inquiry' : id === 'challenge-34' || id === 'challenge-35' ? route === 'choose' &&
      values.item === '1' && values.quantity === task.variables.quantity : id === 'challenge-31' ? route === 'advance' && s.stage === 0 &&
      values.location === task.variables.location && values.service === task.variables.service && values.date === task.variables.date ||
      route === 'finish' && s.stage === 1 && values.summary === task.variables.summary :
      id === 'challenge-32' ? route === 'choose' && values.item === '1' && Boolean(values.label?.trim()) :
      route === 'finish' && s.stage === 1 && values.service === task.variables.service;
    s.events.push({ action: `submit:${route}`, values, valid });
    if (valid && (id === 'challenge-31' && route === 'advance' || id === 'challenge-38' && route === 'results' ||
       id === 'challenge-39' && route === 'advance' || ['challenge-52', 'challenge-55', 'challenge-57'].includes(id) && route === 'advance' ||
       ['challenge-43', 'challenge-44'].includes(id) && route === 'advance')) s.stage = 1;
    else if (valid) s.complete = true;
    else s.mistakes++;
      send(303, '', 'text/plain', { location: s.complete ? `${base}/done` : `${base}/${['challenge-52', 'challenge-55', 'challenge-57'].includes(id) && route === 'advance' && valid ? 'review' : id === 'challenge-31' || ['challenge-39', 'challenge-43', 'challenge-44'].includes(id) && route === 'advance' && valid ? 'review' : id === 'challenge-38' && route === 'results' && valid ? 'results' : ['challenge-32', 'challenge-34', 'challenge-35', 'challenge-36', 'challenge-37', 'challenge-39', 'challenge-40', 'challenge-41', 'challenge-42', 'challenge-43', 'challenge-44', 'challenge-45', 'challenge-56'].includes(id) ? 'start' : 'detail'}` });
    return true;
  };
}
