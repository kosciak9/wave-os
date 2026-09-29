// Fixture-only comparator. Its task is the public /api/tasks manifest, not
// internal fixture identifiers or the out-of-band /api/runs oracle response.
const valueOf = choice => choice.match(/ <- ([^=]+)=(.*)$/)?.slice(1);
const routeOf = url => new URL(url).pathname.split('/').at(-1);
const normalized = value => String(value).normalize('NFKC').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();

export function matchesClickChoice(choice, label, context) {
  const match = /^CLICK (?:button|link|checkbox|radio) "([^"\n]+)" \(([^()\n]*)\) \[e\d+\]$/.exec(choice);
  if (!match || normalized(match[1]) !== normalized(label)) return false;
  if (!context) return true;
  const path = value => value.split('/').map(part => normalized(part)).filter(Boolean);
  const actual = path(match[2]), wanted = path(context);
  return wanted.length > 0 && actual.length >= wanted.length &&
    wanted.every((part, index) => part === actual[actual.length - wanted.length + index]);
}

export function intendedAction({ state, choices }, task) {
  const route = routeOf(state.url);
  const candidates = (description, predicate) => {
    const matching = choices.filter(predicate);
    return { intended: description, selected: matching.length === 1 ? matching[0] : null,
      reason: matching.length === 1 ? 'available' : matching.length ? 'ambiguous_candidate' : 'missing_candidate' };
  };
  const field = (label, variable, value = task.variables[variable], context) => {
    const desired = String(value);
    const matching = (state.fields ?? []).filter(f =>
      (f.name === label || f.label.toLowerCase().startsWith(label.toLowerCase())) &&
      (!context || f.context?.includes(context)));
    const intended = { operation: 'field', label, variable, value: desired, ...(context && { context }) };
    if (matching.length !== 1) return { intended, selected: null,
      reason: matching.length ? 'ambiguous_field' : 'missing_field' };
    const observed = matching[0];
    if (observed.value === desired) return { intended, selected: null, reason: 'already_satisfied' };
    if (!observed.ref) return { intended, selected: null, reason: 'missing_ref' };
    return candidates(intended, choice => /^(TYPE|SELECT) /.test(choice) &&
      choice.includes(`[${observed.ref}]`) && valueOf(choice)?.[1] === desired &&
      (valueOf(choice)?.[0] === variable || variable === 'location' && valueOf(choice)?.[0] === 'target'));
  };
  const click = (label, context) => candidates({ operation: 'click', label, ...(context && { context }) },
    choice => matchesClickChoice(choice, label, context));
  const fill = (entries, next) => {
    for (const [label, variable, value, context] of entries) {
      const candidate = field(label, variable, value, context);
      if (candidate.reason !== 'already_satisfied') return candidate;
    }
    return next();
  };
  const target = task.variables.target;
  if (task.category === 'challenge') {
    if (task.id === 'challenge-38') return route === 'start' ? fill([['Search catalog', 'target']], () => click('Search')) :
      route === 'results' ? click('Open Harbor Studio') : route === 'detail' ? click('Open inquiry modal') :
      route === 'modal' ? fill([['Location', 'location'], ['Preference', 'preference']], () => click('Send inquiry')) :
      { intended: { operation: 'stop', route }, selected: null, reason: 'unexpected_route' };
    if (task.id === 'challenge-39') return route === 'review' ? click('Confirm demo request') :
      fill([['Location (autocomplete)', 'location'], ['Service', 'service']], () => click('Continue'));
    if (['challenge-40', 'challenge-41', 'challenge-42'].includes(task.id)) return fill([
      ['Party size', 'party', task.variables.party, 'Garden Room'],
      ['Preference', 'preference', task.variables.preference, 'Garden Room'],
    ], () => click('Send inquiry', 'Garden Room'));
    if (task.id === 'challenge-43' || task.id === 'challenge-44') return route === 'review' ? click('Confirm inquiry', 'Garden Room') : fill([
      ['Party size', 'party', task.variables.party, 'Garden Room'],
      ['Preference', 'preference', task.variables.preference, 'Garden Room'],
    ], () => click('Continue', 'Garden Room'));
    if (task.id === 'challenge-45') return fill([
      ['Party size', 'party'], ['Preference', 'preference', 'Quiet'],
    ], () => click('Send inquiry'));
    if (task.id === 'challenge-34' || task.id === 'challenge-35') return fill([
      ['Quantity', 'quantity', task.variables.quantity, 'Coral Workshop'],
    ], () => click('Send inquiry', 'Coral Workshop'));
    if (task.id === 'challenge-36' || task.id === 'challenge-37') return fill([['Location', 'location']], () => click('Send inquiry'));
    if (task.id === 'challenge-31') return route === 'start' || route === 'review' ?
      (route === 'start' ? fill([['Location', 'location'], ['Service', 'service'], ['Requested date', 'date']],
        () => click('Continue')) : fill([['Confirmation label', 'summary']], () => click('Confirm demo request'))) :
      { intended: { operation: 'stop', route }, selected: null, reason: 'unexpected_route' };
    if (task.id === 'challenge-32') return click('Send inquiry', target);
    if (task.id === 'challenge-33') return route === 'detail' ? fill([['Service', 'service']],
      () => click('Submit demo request')) : click('Open Harbor Studio detail');
  }
  if (task.category === 'login') return { intended: { operation: 'stop', reason: 'sensitive_fields' },
    selected: null, reason: 'unsafe_fixture' };
  if (task.category === 'search') {
    if (route === 'start') return fill([['Search catalog', 'target']], () => click('Search'));
    if (route === 'results') return click(target);
    if (route === 'detail') return click('Save to shortlist');
  }
  if (task.category === 'booking') {
    if (route === 'start') return click(target);
    if (route === 'detail') return fill([['Date', 'date'], ['Time', 'time'], ['Party size', 'party']],
      () => click('Send inquiry'));
  }
  if (task.category === 'forms') return fill([
    ['Location (autocomplete)', 'location', target], ['Service', 'service'], ['Requested date', 'date'],
  ], () => click('Submit request'));
  if (task.category === 'cart') {
    if (route === 'start') return fill([['Quantity', 'quantity', task.variables.quantity, target]],
      () => click('Add to cart', `Demo shop / ${target}`));
  }
  if (task.category === 'spa') {
    if (route === 'start' || route === 'list')
      return /Page 2 of 2/.test(state.text) ? click(`Open ${target} detail`) : click('All entries tab');
    if (route === 'modal') return click('Pin this entry');
  }
  if (task.category === 'long') {
    const stage = Number(state.title.match(/^Itinerary stage ([1-4]) of 4$/)?.[1]);
    const stages = [
      [['Destination', 'destination'], ['Arrival date', 'arrival'], ['Travel mode', 'travel'], ['Reference label', 'reference']],
      [['Attendee alias', 'attendee'], ['Seat preference', 'seat'], ['Accessibility note', 'access'], ['Ticket tier', 'ticket']],
      [['Meal preference', 'meal'], ['Session track', 'session'], ['Venue wing', 'venue'], ['Reminder', 'reminder']],
      [['Summary title', 'summary'], ['Time zone', 'timezone'], ['Contact alias', 'contact'], ['Review status', 'confirm']],
    ];
    if (route === 'start' || route === 'work') {
      if (stage >= 1 && stage <= 4) return fill(stages[stage - 1],
        () => click(stage === 4 ? 'Submit itinerary' : 'Continue'));
    }
  }
  return { intended: { operation: 'stop', route }, selected: null, reason: 'unexpected_route' };
}
