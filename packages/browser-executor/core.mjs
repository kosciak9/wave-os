import { createHash } from 'node:crypto';

const MAX_CHOICES = 40;
const SENSITIVE = /\b(?:pass(?:word|phrase)?|secret|token|api[_ -]?key|auth(?:entication|orization)?|credential|card(?:[_ -]?number)?|cvv|cvc|pin[_ -]?(?:code|number)|otp|one[_ -]?time|security[_ -]?code|ssn|social[_ -]?security|account[_ -]?(?:number|no|id)|routing[_ -]?number)\b/i;
const SENSITIVE_ACTION = /\b(?:pass(?:word|phrase)?|secret|token|api[_ -]?key|auth(?:entication|orization)?|credential|card(?:[_ -]?number)?|cvv|cvc|otp|one[_ -]?time|security[_ -]?code|ssn|social[_ -]?security|account[_ -]?(?:number|no|id))\b/i;
const SENSITIVE_VALUE = /\b\d{3}-\d{2}-\d{4}\b|\b(?:\d[ -]?){13,19}\b/g;
const SENSITIVE_VALUE_TEST = new RegExp(SENSITIVE_VALUE.source);
const DANGEROUS_ACTION = /\b(?:pay(?:ment)?(?:\s+(?:now|online))?|submit\s+payment|complete\s+payment|payment\s+submission|finalize\s+purchase|(?:submit|complete|place)\s+order|confirm\s+(?:order|purchase|payment|reservation)|buy\s+now|checkout|purchase|delete\s+(?:account|profile|data)|remove\s+all|transfer\s+(?:money|funds))\b/i;
const EDITABLE = new Set(['text', 'search', 'email', 'tel', 'url', 'number', 'date', 'time', 'datetime-local', 'month', 'week']);
const locks = new Map();
const tabKey = (browser, tabId) => `${browser.scopeId ?? ''}:${tabId}`;
const scopedTabKey = (scopeId, tabId) => {
  if (typeof scopeId !== 'string' || !scopeId.trim() || scopeId !== scopeId.trim() || scopeId.length > 512 ||
      /[\x00-\x1f\x7f]/.test(scopeId) ||
      typeof tabId !== 'string' || !/^[\w-]{1,128}$/.test(tabId)) throw Error('invalid_tab_scope');
  return `${scopeId}:${tabId}`;
};

/** Read-only gate for the trusted wrapper's low-level mutating tools. Pass the
 * exact browser.scopeId used by executeBrowser (Camofox: base origin + scoped
 * userId) and the tabId. False covers both an active call and an indefinitely
 * quarantined tab. Do not expose this as a model tool. Callers that mutate
 * must use reserveBrowserTabMutation rather than check then dispatch.
 */
export function browserTabMutationAllowed(scopeId, tabId) {
  return !locks.has(scopedTabKey(scopeId, tabId));
}

/** Synchronously claim a scoped tab before a trusted low-level tool dispatch.
 * Releasing after a failed/uncertain response quarantines it indefinitely;
 * a successful backend response removes the lease. The returned closure is
 * single-use and fails closed unless passed exactly {ok: true}. No model tool
 * can recover a quarantined tab. Process restarts lose this in-memory lease.
 */
export function reserveBrowserTabMutation(scopeId, tabId) {
  const key = scopedTabKey(scopeId, tabId);
  if (locks.has(key)) throw Error('tab_mutation_unavailable');
  const lease = { busy: true, poisoned: false, mutationSettled: false };
  locks.set(key, lease);
  let released = false;
  return ({ ok } = {}) => {
    if (released || locks.get(key) !== lease) return false;
    released = true;
    lease.busy = false;
    lease.mutationSettled = true;
    if (ok === true) locks.delete(key);
    else lease.poisoned = true;
    return true;
  };
}
const clean = (s, n = 160) => String(s ?? '').replace(/[\x00-\x1f\x7f]/g, ' ').trim().slice(0, n);
const normalize = s => clean(s, 300).toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
const record = value => value !== null && typeof value === 'object' && !Array.isArray(value) &&
  (Object.getPrototypeOf(value) === Object.prototype || Object.getPrototypeOf(value) === null);
const digest = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
const safeUrl = url => { const u = new URL(url); if (!['http:', 'https:'].includes(u.protocol) || u.username || u.password) throw Error('unsafe_url'); return u; };
const displayUrl = url => { const u = safeUrl(url); return `${u.origin}${u.pathname.slice(0, 300)}`; };
const isSensitive = f => f.type === 'password' || /^(?:pin|security code)$/i.test(String(f.name ?? f.label ?? '')) || SENSITIVE.test([f.label, f.name, f.id, f.type, f.autocomplete].join(' '));

/** Only AX refs are actionable; indented headings provide context for repeated controls. */
export function extractAx(snapshot) {
  const lines = snapshot.split('\n');
  const nodes = [], headings = [];
  for (const line of lines) {
    const m = /^(\s*)- ([\w-]+)(?: "((?:[^"\\]|\\.)*)")?(?: \[(e\d+)\])?(.*)$/.exec(line);
    if (!m) continue;
    const [, indent, role, raw = '', ref, suffix] = m;
    const name = clean(raw.replace(/\\"/g, '"'), 200);
    const depth = indent.length;
    if (role === 'heading') {
      while (headings.length && headings.at(-1).depth >= depth) headings.pop();
      headings.push({ depth, name });
    }
    if (ref) nodes.push({ ref, role, name, disabled: /\[disabled\]/i.test(suffix),
      value: /^:\s*"?([^"\n]{0,120})"?/.exec(suffix)?.[1]?.trim() ?? '',
      context: headings.map(h => h.name).join(' / ').slice(0, 200) });
  }
  return nodes;
}

/** No positional mapping: duplicate role/name matches are intentionally not assigned. */
export function mapFields(structure, nodes) {
  const fields = (structure?.forms ?? []).flatMap(form => form.fields ?? []);
  const mapped = fields.map(field => {
    if (isSensitive(field) || field.disabled) return { field, ref: null };
    const roles = field.tag === 'select' ? ['combobox'] : field.type === 'number' ? ['spinbutton'] :
      field.type === 'search' ? ['searchbox', 'textbox'] :
      field.tag === 'input' && field.type === 'text' ? ['textbox', 'combobox'] : ['textbox'];
    const label = normalize(field.label);
    const options = (field.options ?? []).map(o => normalize(o.label)).filter(Boolean);
    const matches = nodes.filter(n => roles.includes(n.role) && !n.disabled && (
      (label && normalize(n.name) === label) ||
      // DOM wrapping labels contain concatenated option text; AX name is shorter.
      (field.tag === 'select' && options.length && normalize(field.label).startsWith(normalize(n.name)) && normalize(n.name) &&
        [options.join(' '), options.join('')].includes(normalize(field.label).slice(normalize(n.name).length).trim()))
    ));
    const ref = matches.length === 1 && (!field.ref || field.ref === matches[0].ref) ? matches[0].ref : null;
    return { field, ref };
  });
  return mapped.map(entry => ({ ...entry, ref: entry.ref && mapped.filter(e => e.ref === entry.ref).length === 1 ? entry.ref : null }));
}

function validateRequest(request) {
  if (!record(request) || Object.keys(request).some(k => !['goal', 'tabId', 'variables', 'success', 'allowedOrigins', 'forbidActions'].includes(k)) ||
      typeof request.goal !== 'string' || !request.goal.trim() || request.goal.length > 2000 ||
      typeof request.tabId !== 'string' || !/^[\w-]{1,128}$/.test(request.tabId) ||
      !record(request.variables)) throw Error('invalid_request');
  const variables = Object.entries(request.variables);
  if (variables.length > 32 || variables.some(([k, v]) => !k || k.length > 100 || typeof v !== 'string' || v.length > 100 ||
      SENSITIVE_VALUE_TEST.test(v))) throw Error('invalid_request');
  if (request.success != null && (!record(request.success) ||
      Object.keys(request.success).some(k => !['textIncludes', 'urlPath'].includes(k)) ||
      Object.values(request.success).some(v => typeof v !== 'string' || !v.trim() || v.length > 300))) throw Error('invalid_request');
  if (request.allowedOrigins != null && (!Array.isArray(request.allowedOrigins) || request.allowedOrigins.length > 8 ||
      request.allowedOrigins.some(origin => safeUrl(origin).origin !== origin))) throw Error('invalid_request');
  if (request.forbidActions != null && (!Array.isArray(request.forbidActions) || request.forbidActions.length > 24 ||
      request.forbidActions.some(s => typeof s !== 'string' || !s || s.length > 100))) throw Error('invalid_request');
  if (request.forbidActions?.some(s => !normalize(s))) throw Error('invalid_request');
}

function view(snapshot, request, origins) {
  if (!record(snapshot) || typeof snapshot.url !== 'string' || typeof snapshot.snapshot !== 'string' ||
      snapshot.snapshot.length > 200_000 || snapshot.hasMore || snapshot.truncated ||
      !record(snapshot.structure) || !Array.isArray(snapshot.structure.forms) || snapshot.structure.formsTruncated ||
      snapshot.structure.forms.some(form => !record(form) || !Array.isArray(form.fields) || form.fieldsTruncated ||
        form.fields.some(field => !record(field) || typeof field.label !== 'string' ||
          typeof field.tag !== 'string' || typeof field.type !== 'string' ||
          field.options != null && (!Array.isArray(field.options) || field.options.some(option => !record(option) ||
            typeof option.label !== 'string' || typeof option.value !== 'string' || typeof option.selected !== 'boolean')))))
    throw Error('incomplete_snapshot');
  const url = safeUrl(snapshot.url);
  if (!origins.has(url.origin)) throw Error('origin_changed');
  const nodes = extractAx(snapshot.snapshot);
  if (new Set(nodes.map(n => n.ref)).size !== nodes.length) throw Error('duplicate_refs');
  const fields = mapFields(snapshot.structure, nodes);
  if (fields.some(({ field }) => isSensitive(field)) || nodes.some(n =>
    ['textbox', 'searchbox', 'combobox', 'spinbutton'].includes(n.role) && SENSITIVE.test(n.name))) throw Error('sensitive_fields');
  const redactions = Object.entries(request.variables).filter(([key]) => SENSITIVE.test(key)).map(([, value]) => value).filter(Boolean);
  const redact = value => redactions.reduce((s, secret) => s.replaceAll(secret, '[REDACTED]'),
    String(value).replace(SENSITIVE_VALUE, '[REDACTED]'));
  const visible = snapshot.snapshot.split('\n').filter(line => !SENSITIVE.test(line) && !/\[(?:e\d+)\].*:\s*\S/.test(line)).map(redact).join('\n');
  const semantic = visible.split('\n').filter(line => /^\s*- (?:heading|paragraph|alert|text|listitem)\b/.test(line))
    .map(line => clean(line.replace(/^\s*- (?:heading|paragraph|alert|text|listitem)\b:?\s*/, ''), 220))
    .filter(Boolean).join(' | ');
  const state = {
    goal: redact(clean(request.goal, 1200)), url: redact(displayUrl(snapshot.url)),
    variables: Object.fromEntries(Object.entries(request.variables).filter(([key]) => !SENSITIVE.test(key)).map(([key, value]) => [key, redact(clean(value, 100))])),
    title: redact(clean(snapshot.snapshot.match(/^\s*- heading "([^"]+)"/m)?.[1] ?? '', 140)),
    text: semantic.length > 950 ? `${semantic.slice(0, 920)} [observation abbreviated]` : semantic,
    fields: fields.filter(({ field }) => !isSensitive(field)).map(({ field, ref }) => ({
      label: redact(clean(field.label, 120)), name: clean(field.name, 80), ref,
      value: redact(clean(field.value, 120)), type: field.type,
    })).concat(nodes.filter(n => ['spinbutton', 'searchbox'].includes(n.role) && !fields.some(f => f.ref === n.ref) && !SENSITIVE.test(n.name))
      .map(n => ({ label: redact(n.name), name: '', ref: n.ref, value: redact(n.value),
        type: n.role === 'spinbutton' ? 'number' : 'search', context: redact(n.context) }))),
  };
  // Hash includes actual field values and URL, not volatile AX refs or timestamps.
  const fingerprint = digest([url.href, fields.map(({ field }) => [field.name, field.label, field.value, field.options?.map(o => o.selected)]),
    nodes.map(({ role, name, context, value }) => [role, name, context, value]), visible.replace(/\[e\d+\]/g, '')]);
  return { nodes, fields, state, fingerprint, visible, url, redact };
}

function success(viewed, success) {
  if (!success || !Object.keys(success).length) return false;
  return (!success.urlPath || viewed.url.pathname === success.urlPath) &&
    (!success.textIncludes || viewed.visible.toLowerCase().includes(success.textIncludes.toLowerCase()));
}

function choicesFor(viewed, request) {
  if (viewed.fields.some(({ field }) => isSensitive(field))) throw Error('sensitive_fields');
  const forbidden = request.forbidActions ?? [];
  const blocked = label => forbidden.some(literal => normalize(label).includes(normalize(literal)));
  const numericNodes = viewed.nodes.filter(n => n.role === 'spinbutton' && !n.disabled && !SENSITIVE.test(n.name));
  const searchNodes = viewed.nodes.filter(n => n.role === 'searchbox' && !n.disabled && !SENSITIVE.test(n.name));
  const fields = viewed.fields.filter(({ field, ref }) => ref && !field.disabled && !isSensitive(field))
    .map(({ field, ref }) => ({ ...field, ref, context: viewed.nodes.find(n => n.ref === ref)?.context ?? '' }));
  // A repeated AX spinbutton is independently actionable from its ref and AX value;
  // no assumption is made about which structurally ambiguous DOM form owns it.
  for (const node of [...numericNodes, ...searchNodes]) {
    if (!fields.some(f => f.ref === node.ref)) fields.push({ label: node.name, name: '', type: 'number', tag: 'input',
      value: node.value, ref: node.ref, context: node.context, ...(node.role === 'searchbox' && { type: 'search' }) });
  }
  const unmatchedStructure = viewed.fields.filter(({ field, ref }) => !field.disabled && !ref &&
    (field.tag === 'select' || field.tag === 'textarea' || field.tag === 'input' && EDITABLE.has(field.type || 'text')));
  const prepared = Object.entries(request.variables).filter(([key, value]) => !SENSITIVE.test(key) && value);
  const matches = (field, key) => {
    const words = new Set(normalize(`${field.label} ${field.name}`).split(' '));
    return normalize(key).split(' ').some(word => word.length > 2 && words.has(word));
  };
  const matchedKeys = new Set(prepared.filter(([key]) => fields.some(f => matches(f, key))).map(([key]) => key));
  const incompleteForm = unmatchedStructure.some(({ field }) => {
    if ((field.type === 'number' && numericNodes.some(n => normalize(n.name) === normalize(field.label))) ||
        (field.type === 'search' && searchNodes.some(n => normalize(n.name) === normalize(field.label)))) return false;
    const related = prepared.filter(([key]) => matches(field, key));
    return !field.value || related.some(([, value]) => value !== field.value);
  });
  const desired = new Map(fields.map(field => {
    const aligned = prepared.filter(([key]) => matches(field, key));
    // Retain unmatched values only for unmatched fields. If an alias has the
    // same value as an aligned key, the aligned key supplies its coverage.
    const alternatives = aligned.length ? aligned : prepared.filter(([key, value]) => !matchedKeys.has(key) &&
      !prepared.some(([other, v]) => matchedKeys.has(other) && value === v));
    return [field.ref, alternatives];
  }));
  const target = normalize(request.variables.target);
  const targetedNumeric = target && numericNodes.some(n => normalize(n.context).includes(target));
  const targetLinks = target && viewed.nodes.some(n => n.role === 'link' && normalize(n.name).includes(target));
  const pending = field => (desired.get(field.ref) ?? []).some(([, value]) => field.value !== value &&
    (field.tag !== 'select' || (field.options ?? []).some(o => (o.label === value || o.value === value) && !o.selected)));
  const stageHasPendingValues = fields.some(pending);
  const choices = [], actions = new Map();
  let unsafeControls = false;
  const add = (kind, description, data) => {
    const choice = viewed.redact(`${kind} ${description}`);
    if (actions.has(choice)) throw Error('ambiguous_choices');
    if (choice.length > 256) throw Error('choice_representation_limit');
    choices.push(choice); actions.set(choice, { kind, ...data });
  };
  for (const node of viewed.nodes) {
    const paymentContext = ['button', 'link'].includes(node.role) && /\b(?:payment|purchase|checkout|order)\b/i.test(node.context);
    if (['button', 'link'].includes(node.role) && (DANGEROUS_ACTION.test(node.name) || paymentContext)) {
      unsafeControls = true;
      continue;
    }
    if (!['button', 'link', 'checkbox', 'radio'].includes(node.role) || node.disabled ||
        stageHasPendingValues && node.role === 'link' ||
        targetLinks && node.role === 'link' && !normalize(node.name).includes(target) ||
        node.role === 'button' && (incompleteForm || fields.some(f => f.context === node.context && pending(f)) ||
          targetedNumeric && !normalize(node.context).includes(target)) ||
        SENSITIVE_ACTION.test(node.name) || blocked(`${node.context} ${node.name}`)) continue;
    add('CLICK', `${node.role} "${clean(node.name, 100)}" (${clean(node.context, 100)}) [${node.ref}]`, { ref: node.ref });
  }
  for (const field of fields) {
    if (blocked(field.label) || targetedNumeric && field.type === 'number' && !normalize(field.context).includes(target)) continue;
    for (const [key, value] of desired.get(field.ref) ?? []) {
      const ref = field.ref;
      const label = `${clean(field.context, 35)} ${clean(field.label, 50)} [${ref}] <- ${clean(key, 40)}=${value}`;
      if (field.tag === 'select') {
        const options = (field.options ?? []).filter(o => o.value === value || o.label === value);
        if (options.length !== 1 || options[0].selected || field.optionsTruncated) continue;
        add('SELECT', label, { ref, option: options[0].value });
      } else if ((field.tag === 'textarea' || field.tag === 'input' && EDITABLE.has(field.type || 'text')) &&
          field.value !== value && (field.type !== 'number' || /^-?\d+(?:\.\d+)?$/.test(value))) {
        add('TYPE', label, { ref, text: value });
      }
    }
  }
  const canScroll = /\b(scroll|load more|more results|infinite)\b/i.test(viewed.state.text);
  if (choices.length > MAX_CHOICES - (Number(canScroll) + Number(!stageHasPendingValues) + 1)) throw Error('choice_limit');
  if (canScroll) add('SCROLL', 'down 600 pixels', { direction: 'down', amount: 600 });
  if (!stageHasPendingValues) add('STOP', 'request human checkpoint', {});
  add('ESCALATE', 'cannot proceed safely', {});
  return { choices, actions, incompleteForm, unsafeControls };
}

function validateDecision(answer, choices, threshold, margin) {
  const probs = answer?.probabilities;
  if (!probs || typeof probs !== 'object' || Array.isArray(probs) ||
      Object.keys(probs).length !== choices.length || choices.some(c => !Object.hasOwn(probs, c) || !Number.isFinite(probs[c]) || probs[c] < 0 || probs[c] > 1) ||
      Math.abs(Object.values(probs).reduce((a, b) => a + b, 0) - 1) > 0.001 ||
      !choices.includes(answer.choice) || !Number.isFinite(answer.latency_ms) || answer.latency_ms < 0) throw Error('invalid_model_output');
  const sorted = choices.map(c => probs[c]).sort((a, b) => b - a);
  if (probs[answer.choice] !== sorted[0] || sorted[0] < threshold || sorted[0] - sorted[1] < margin) throw Error('uncertain');
  return answer.choice;
}

/** Trusted recovery only; never register this as a model tool. The operator must
 * inspect the fresh observation and explicitly accept possible late remote effects.
 * A settled HTTP fetch does NOT prove that Camofox's page operation has ended.
 */
export async function recoverBrowserTab(browser, tabId, { confirm } = {}) {
  if (!browser || typeof browser.snapshot !== 'function' || typeof confirm !== 'function' ||
      typeof tabId !== 'string' || !/^[\w-]{1,128}$/.test(tabId)) throw Error('invalid_recovery');
  const key = tabKey(browser, tabId), lease = locks.get(key);
  if (!lease?.poisoned || lease.busy || !lease.mutationSettled) return false;
  let timer;
  let observation;
  try {
    observation = await Promise.race([browser.snapshot(tabId, { signal: AbortSignal.timeout(15_000) }),
      new Promise((_, reject) => { timer = setTimeout(() => reject(Error('recovery_timeout')), 15_000); })]);
  } finally { clearTimeout(timer); }
  if (!record(observation) || typeof observation.snapshot !== 'string' || typeof observation.url !== 'string')
    throw Error('invalid_recovery_snapshot');
  safeUrl(observation.url);
  if (await confirm(observation) !== true) return false;
  if (locks.get(key) !== lease || lease.busy || !lease.mutationSettled) return false;
  locks.delete(key);
  return true;
}

/** decide receives only a bounded redacted state and exact legal choices; browser handles scoped refs only. */
export async function executeBrowser(request, { browser, decide, telemetry, signal, maxSteps = 8, timeoutMs = 120_000,
  threshold = 0.5, margin = 0.05 } = {}) {
  let steps = 0, currentUrl = '', relevantState = '';
  const result = (status, reason) => {
    try { telemetry?.({ event: 'result', status, reason, steps }); } catch { /* metrics never affect outcomes */ }
    return { status, reason, steps, current_url: currentUrl, relevant_state: relevantState.slice(0, 1500),
      ...(['action_outcome_unknown', 'tab_quarantined'].includes(reason) && {
        recovery_hint: 'Remote mutation may complete later. Stop all mutations on this tab; trusted operator must re-snapshot, inspect, then acknowledge recovery.',
      }),
      ...(['matched_on_entry', 'matched_conditions_after_action'].includes(reason) &&
        { matched_conditions: Object.keys(request.success) }) };
  };
  try {
    validateRequest(request);
    if (!browser || typeof browser.snapshot !== 'function' || typeof decide !== 'function' ||
        !Number.isInteger(maxSteps) || maxSteps < 1 || maxSteps > 24 || !Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 120_000 ||
        !Number.isFinite(threshold) || threshold < 0 || threshold > 1 || !Number.isFinite(margin) || margin < 0 || margin > 1) throw Error('invalid_configuration');
  } catch { return result('escalated', 'invalid_request'); }
  const key = tabKey(browser, request.tabId);
  if (locks.has(key)) return result('escalated', locks.get(key).poisoned ? 'tab_quarantined' : 'tab_busy');
  const lease = { busy: true, poisoned: false, mutationSettled: true };
  locks.set(key, lease);
  const deadline = AbortSignal.timeout(timeoutMs);
  const combined = signal ? AbortSignal.any([signal, deadline]) : deadline;
  const guard = async promise => {
    if (combined.aborted) throw Error('timeout_or_cancelled');
    let onAbort;
    try {
      return await Promise.race([promise, new Promise((_, reject) => {
        onAbort = () => reject(Error('timeout_or_cancelled'));
        combined.addEventListener('abort', onAbort, { once: true });
      })]);
    } finally { combined.removeEventListener('abort', onAbort); }
  };
  let reason = 'max_steps';
  let mutationStarted = false, observedAfterMutation = false;
  try {
    const snapshot = async () => {
      if (combined.aborted) throw Error('timeout_or_cancelled');
      const observed = await guard(browser.snapshot(request.tabId, { signal: combined }));
      try { telemetry?.({ event: 'snapshot', exposed_to_large_model: false }); } catch { /* metadata only */ }
      return observed;
    };
    let raw = await snapshot();
    const initial = safeUrl(raw.url);
    const initialPage = view(raw, request, new Set([initial.origin])).state.title;
    const origins = new Set([initial.origin, ...(request.allowedOrigins ?? [])]);
    const seen = new Set();
    let recent = [], decisions = 0;
    for (;;) {
      const v = view(raw, request, origins);
      currentUrl = v.redact(displayUrl(raw.url));
      relevantState = clean(v.state.text, 1500);
      if (success(v, request.success)) return steps ? result('completed', 'matched_conditions_after_action') :
        result('checkpoint', 'matched_on_entry');
      if (!request.success && steps > 0 && (v.state.title !== initialPage || v.url.pathname !== initial.pathname))
        return result('checkpoint', 'page_changed_checkpoint');
      if (steps >= maxSteps) break;
      if (++decisions > maxSteps * 3) throw Error('decision_limit');
      const { choices, actions, incompleteForm, unsafeControls } = choicesFor(v, request);
      if (![...actions.values()].some(action => !['STOP', 'ESCALATE'].includes(action.kind)))
        return incompleteForm ? result('escalated', 'unmapped_fields') : unsafeControls ?
          result('escalated', 'unsafe_controls') : result('checkpoint', 'no_actionable_controls');
      const answer = await guard(decide({ state: { ...v.state, recent }, choices: [...choices] }, { signal: combined }));
      if (answer?.probabilities && typeof answer.probabilities === 'object') {
        const ranked = Object.values(answer.probabilities).filter(Number.isFinite).sort((a, b) => b - a);
        try { telemetry?.({ event: 'decision', kind: String(answer.choice ?? '').split(' ')[0].slice(0, 12),
          index: choices.indexOf(answer.choice), confidence: ranked[0], margin: ranked[0] - ranked[1], candidates: choices.length }); } catch { /* metadata only */ }
      }
      const choice = validateDecision(answer, choices, threshold, margin);
      const action = actions.get(choice);
      if (action.kind === 'STOP') return result('checkpoint', 'model_stop');
      if (action.kind === 'ESCALATE') return result('escalated', 'model_escalation');
      const tuple = `${v.fingerprint}:${choice.replace(/\[e\d+\]/g, '[ref]')}`;
      if (seen.has(tuple)) return result('escalated', 'action_loop');
      seen.add(tuple);
      // A fresh snapshot before mutation prevents stale refs after model latency.
      if (combined.aborted) throw Error('timeout_or_cancelled');
      const fresh = await snapshot();
      const next = view(fresh, request, origins);
      if (next.fingerprint !== v.fingerprint || JSON.stringify(next.nodes) !== JSON.stringify(v.nodes)) {
        raw = fresh; reason = 'state_changed'; continue;
      }
      if (combined.aborted) throw Error('timeout_or_cancelled');
      mutationStarted = true;
      observedAfterMutation = false;
      lease.mutationSettled = false;
      const mutation = Promise.resolve().then(() => browser[action.kind.toLowerCase()](request.tabId, action, { signal: combined }));
      mutation.then(() => { lease.mutationSettled = true; }, () => { lease.mutationSettled = true; });
      await guard(mutation);
      steps++;
      recent = [...recent, choice.replace(/\[e\d+\]/g, '[ref]').replace(/<- .+$/, '<- variable')].slice(-2);
      try { telemetry?.({ event: 'action', kind: action.kind, step: steps }); } catch { /* observation must not affect browser control */ }
      raw = await snapshot();
      safeUrl(raw.url);
      observedAfterMutation = true;
      currentUrl = v.redact(displayUrl(raw.url));
      const after = view(raw, request, origins);
      if (after.fingerprint === v.fingerprint) return result('escalated', 'no_state_change');
      if (action.kind === 'TYPE' || action.kind === 'SELECT') {
        const beforeNode = v.nodes.find(node => node.ref === action.ref);
        const candidates = after.nodes.filter(node => beforeNode && node.role === beforeNode.role &&
          node.name === beforeNode.name && node.context === beforeNode.context);
        if (candidates.length !== 1) return result('escalated', 'field_unverifiable');
        const beforeField = v.fields.find(({ ref }) => ref === action.ref)?.field;
        const afterField = after.fields.find(({ ref }) => ref === candidates[0].ref)?.field;
        if (beforeField && (!afterField || ['tag', 'type', 'name', 'label'].some(key =>
          beforeField[key] !== afterField[key]))) return result('escalated', 'field_unverifiable');
        const observed = afterField?.value ?? candidates[0].value;
        if (observed == null) return result('escalated', 'field_unverifiable');
        if (observed !== (action.kind === 'TYPE' ? action.text : action.option))
          return result('escalated', 'value_not_applied');
      }
    }
  } catch (error) {
    if (mutationStarted && !observedAfterMutation) {
      lease.poisoned = true;
      reason = 'action_outcome_unknown';
    } else reason = ['origin_changed', 'choice_limit', 'choice_representation_limit', 'model_input_limit', 'model_rejected_input',
      'model_timeout', 'model_exit', 'model_output_limit', 'invalid_native_answer', 'backend_unavailable', 'response_too_large',
      'action_loop', 'decision_limit', 'incomplete_snapshot', 'sensitive_fields', 'duplicate_refs', 'ambiguous_choices',
      'invalid_model_output', 'uncertain', 'timeout_or_cancelled'].includes(error.message) ? error.message :
      combined.aborted ? 'timeout_or_cancelled' : 'backend_or_model_error';
  } finally {
    lease.busy = false;
    if (!lease.poisoned) locks.delete(key);
  }
  return result('escalated', reason);
}
