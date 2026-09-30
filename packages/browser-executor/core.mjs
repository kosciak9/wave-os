import { createHash, randomBytes } from 'node:crypto';
import { resolveSemanticFields } from './resolver.mjs';

const MAX_CHOICES = 40, TTL = 600_000;
const continuations = new Map();
const FAILURE_CODES = new Set(['invalid_request', 'invalid_continuation_shape', 'invalid_continuation_unknown',
  'invalid_continuation_expired', 'invalid_continuation_scope', 'origin_changed', 'incomplete_snapshot',
  'sensitive_fields', 'duplicate_refs', 'unsafe_url', 'timeout_or_cancelled', 'storage_error',
  'tab_state_unavailable', 'tab_busy', 'tab_quarantined', 'invalid_configuration', 'backend_or_model_error',
  'field_value_unverified', 'action_outcome_unknown', 'continuation_stale', 'invalid_resolution',
  'fact_not_grounded', 'invalid_choice', 'binding_not_grounded', 'approved_choice_stale', 'action_not_grounded']);
const SENSITIVE = /\b(?:pass(?:word|phrase)?|secret|token|api[_ -]?key|auth(?:entication|orization)?|credential|card(?:[_ -]?number)?|cvv|cvc|pin[_ -]?(?:code|number)|otp|one[_ -]?time|security[_ -]?code|ssn|social[_ -]?security|account[_ -]?(?:number|no|id)|routing[_ -]?number)\b/i;
const DANGEROUS = /\b(?:pay(?:ment)?(?:\s+(?:now|online))?|submit\s+payment|complete\s+payment|finalize\s+purchase|(?:submit|complete|place)\s+order|confirm\s+(?:order|purchase|payment|reservation)|buy\s+now|checkout|purchase|delete\s+(?:account|profile|data)|remove\s+all|transfer\s+(?:money|funds))\b/i;
const EDITABLE = new Set(['text', 'search', 'email', 'tel', 'url', 'number', 'date', 'time', 'datetime-local', 'month', 'week']);
const record = v => v !== null && typeof v === 'object' && !Array.isArray(v) &&
  [Object.prototype, null].includes(Object.getPrototypeOf(v));
const clean = (v, n = 160) => String(v ?? '').replace(/[\x00-\x1f\x7f]/g, ' ').trim().slice(0, n);
const norm = v => clean(v, 300).toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
const hash = v => createHash('sha256').update(JSON.stringify(v)).digest('hex');
const safeUrl = url => { const u = new URL(url); if (!['http:', 'https:'].includes(u.protocol) || u.username || u.password) throw Error('unsafe_url'); return u; };
const sensitive = f => f.type === 'password' || SENSITIVE.test([f.label, f.name, f.id, f.type, f.autocomplete].join(' '));
const validTab = id => typeof id === 'string' && /^[\w-]{1,128}$/.test(id);
const validFact = (k, v) => typeof k === 'string' && k.length > 0 && k.length <= 100 && !SENSITIVE.test(k) &&
  typeof v === 'string' && v.length > 0 && v.length <= 120 && !/\b\d{3}-\d{2}-\d{4}\b|\b(?:\d[ -]?){13,19}\b/.test(v);
const validBinding = b => record(b) && Object.keys(b).sort().join(',') === 'context,label' &&
  typeof b.label === 'string' && norm(b.label) && b.label.length <= 120 && !SENSITIVE.test(b.label) &&
  typeof b.context === 'string' && norm(b.context) && b.context.length <= 200 && !SENSITIVE.test(b.context);
const scopeKey = (scope, tab) => {
  if (typeof scope !== 'string' || !scope.trim() || scope.length > 512 || /[\x00-\x1f\x7f]/.test(scope) || !validTab(tab)) throw Error('invalid_scope');
  return `${scope}:${tab}`;
};
function extractAx(snapshot) {
  const nodes = [], headings = [];
  for (const line of snapshot.split('\n')) {
    const m = /^(\s*)- ([\w-]+)(?: "((?:[^"\\]|\\.)*)")?(?: \[(e\d+)\])?(.*)$/.exec(line);
    if (!m) continue;
    const [, indent, role, raw = '', ref, suffix] = m;
    if (role === 'heading') {
      while (headings.length && headings.at(-1).depth >= indent.length) headings.pop();
      headings.push({ depth: indent.length, name: clean(raw, 200) });
    }
    if (ref) nodes.push({ ref, role, name: clean(raw.replace(/\\"/g, '"'), 200),
      disabled: /\[disabled\]/i.test(suffix), readOnly: /\[readonly\]/i.test(suffix),
      ...(['checkbox', 'radio'].includes(role) && { checked: /\[checked\]/i.test(suffix) }),
      value: /^:\s*"?([^"\n]{0,120})"?/.exec(suffix)?.[1]?.trim() ?? '',
      context: headings.map(h => h.name).join(' / ').slice(0, 200) });
  }
  return nodes;
}

function mapFields(structure, nodes) {
  const fields = (structure?.forms ?? []).flatMap(form => form.fields ?? []);
  const mapped = fields.map(field => {
    if (sensitive(field) || field.disabled) return { field, ref: null };
    const roles = field.tag === 'select' ? ['combobox'] : field.type === 'number' ? ['spinbutton'] :
      field.type === 'search' ? ['searchbox', 'textbox'] : field.tag === 'input' && field.type === 'text' ?
        ['textbox', 'combobox'] : ['textbox'];
    const options = (field.options ?? []).map(o => norm(o.label)).filter(Boolean);
    const matches = nodes.filter(n => roles.includes(n.role) && !n.disabled && (
      norm(n.name) === norm(field.label) && norm(n.name) ||
      field.tag === 'select' && options.length && norm(n.name) && norm(field.label).startsWith(norm(n.name)) &&
        [options.join(' '), options.join('')].includes(norm(field.label).slice(norm(n.name).length).trim())));
    return { field, ref: matches.length === 1 && (!field.ref || field.ref === matches[0].ref) ? matches[0].ref : null };
  });
  return mapped.map(entry => ({ ...entry, ref: entry.ref && mapped.filter(e => e.ref === entry.ref).length === 1 ? entry.ref : null }));
}

function validateRequest(request) {
  if (!record(request) || Object.keys(request).some(k => !['tabId', 'goal', 'facts', 'constraints', 'bindings'].includes(k)) ||
      !validTab(request.tabId) || typeof request.goal !== 'string' || !request.goal.trim() || request.goal.length > 360 ||
      !record(request.facts) || Object.keys(request.facts).length > 32 ||
      !Object.entries(request.facts).every(([k, v]) => validFact(k, v))) throw Error('invalid_request');
  if (request.bindings != null && (!record(request.bindings) || Object.keys(request.bindings).length > 32 ||
      !Object.entries(request.bindings).every(([key, binding]) => Object.hasOwn(request.facts, key) && validBinding(binding)))) throw Error('invalid_request');
  if (request.constraints != null && (!record(request.constraints) ||
      Object.keys(request.constraints).some(k => !['allowedOrigins', 'forbidActions'].includes(k)))) throw Error('invalid_request');
  const { allowedOrigins, forbidActions } = request.constraints ?? {};
  if (allowedOrigins != null) {
    if (!Array.isArray(allowedOrigins) || allowedOrigins.length > 8) throw Error('invalid_request');
    try { if (allowedOrigins.some(o => typeof o !== 'string' || safeUrl(o).origin !== o)) throw Error('invalid_request'); }
    catch { throw Error('invalid_request'); }
  }
  if (forbidActions != null && (!Array.isArray(forbidActions) || forbidActions.length > 24 ||
      forbidActions.some(s => typeof s !== 'string' || !norm(s) || s.length > 100))) throw Error('invalid_request');
}

function view(raw, facts, origins) {
  if (!record(raw) || typeof raw.url !== 'string' || typeof raw.snapshot !== 'string' || raw.snapshot.length > 200_000 ||
      raw.hasMore || raw.truncated || !record(raw.structure) || !Array.isArray(raw.structure.forms) ||
      raw.structure.formsTruncated || raw.structure.forms.some(form => !record(form) || !Array.isArray(form.fields) ||
        form.fieldsTruncated || form.fields.some(field => !record(field) || typeof field.label !== 'string' ||
          typeof field.tag !== 'string' || typeof field.type !== 'string' || field.optionsTruncated ||
          field.options != null && (!Array.isArray(field.options) || field.options.some(o => !record(o) ||
            typeof o.label !== 'string' || typeof o.value !== 'string' || typeof o.selected !== 'boolean'))))) throw Error('incomplete_snapshot');
  const url = safeUrl(raw.url);
  if (!origins.has(url.origin)) throw Error('origin_changed');
  const nodes = extractAx(raw.snapshot);
  if (new Set(nodes.map(n => n.ref)).size !== nodes.length) throw Error('duplicate_refs');
  const mapped = mapFields(raw.structure, nodes);
  if (mapped.some(({ field }) => sensitive(field)) || nodes.some(n =>
    ['textbox', 'searchbox', 'combobox', 'spinbutton'].includes(n.role) && SENSITIVE.test(n.name))) throw Error('sensitive_fields');
  const fields = mapped.filter(({ field }) => !field.disabled && field.type !== 'hidden' &&
    (field.tag === 'select' || field.tag === 'textarea' || field.tag === 'input' && EDITABLE.has(field.type)))
    .map(({ field, ref }) => ({ ...field, ref, readOnly: field.readOnly === true || field.readonly === true ||
      nodes.find(n => n.ref === ref)?.readOnly === true, context: nodes.find(n => n.ref === ref)?.context ?? '',
      axName: nodes.find(n => n.ref === ref)?.name ?? '' }));
  for (const node of nodes.filter(n => ['spinbutton', 'searchbox'].includes(n.role) && !n.disabled &&
      !fields.some(f => f.ref === n.ref))) fields.push({ tag: 'input', type: node.role === 'searchbox' ? 'search' : 'number',
    label: node.name, name: node.name, ref: node.ref, value: node.value, context: node.context, readOnly: node.readOnly });
  // An AX-only text/combobox has no DOM ownership or verified option set: it
  // blocks submit instead of silently disappearing from the current form.
  for (const node of nodes.filter(n => ['textbox', 'combobox'].includes(n.role) && !n.disabled &&
      !mapped.some(entry => entry.ref === n.ref))) fields.push({ tag: node.role === 'combobox' ? 'select' : 'input',
    type: node.role === 'combobox' ? 'select-one' : 'text', label: node.name, name: node.name,
    ref: null, context: node.context, value: node.value, readOnly: node.readOnly });
  const redact = value => Object.values(facts).reduce((s, fact) => fact.length > 2 ? s.replaceAll(fact, '[REDACTED]') : s,
    String(value).replace(/\b\d{3}-\d{2}-\d{4}\b|\b(?:\d[ -]?){13,19}\b/g, '[REDACTED]'));
  const visible = raw.snapshot.split('\n').filter(line => !SENSITIVE.test(line) && !/\[(?:e\d+)\].*:\s*\S/.test(line)).map(redact).join('\n');
  const text = clean(visible.split('\n').filter(line => /^\s*- (?:heading|paragraph|alert|text|listitem)\b/.test(line))
    .join(' | '), 650);
  // Ref churn is ignored; all text, values, options and field structure are not.
  const fingerprint = hash([url.href, raw.snapshot.replace(/\[e\d+\]/g, ''), mapped.map(({ field }) =>
    [field.tag, field.type, field.label, field.name, field.value, field.required, field.disabled,
      field.options?.map(o => [o.label, o.value, o.selected])]), nodes.map(({ ref, ...node }) => node)]);
  return { url, nodes, fields, fingerprint, text, redact,
    title: clean(raw.snapshot.match(/^\s*- heading "([^"\n]+)"/m)?.[1], 140) };
}

function candidatesFor(v, request, plan) {
  const forbidden = request.constraints?.forbidActions ?? [];
  const blocked = text => forbidden.some(s => norm(text).includes(norm(s)));
  const unresolved = plan.problems.length > 0 || v.fields.some(f => !f.ref);
  const pending = plan.assignments.filter(({ key, field }) => field.value !== request.facts[key] &&
    !(field.tag === 'select' && field.options?.some(o => o.selected && (o.value === request.facts[key] || o.label === request.facts[key]))));
  const actions = [];
  if (!unresolved) for (const { key, field } of pending) {
    const value = request.facts[key];
    if (blocked(field.label) || field.type === 'number' && field.value && field.value !== value) continue;
    if (field.tag === 'select') {
      const option = field.options?.filter(o => o.value === value || o.label === value);
      if (option?.length === 1) actions.push({ kind: 'SELECT', ref: field.ref, option: option[0].value, label: field.label, context: field.context });
    } else if (field.tag === 'textarea' || field.tag === 'input' && EDITABLE.has(field.type)) {
      if (field.type !== 'number' || /^-?\d+(?:\.\d+)?$/.test(value))
        actions.push({ kind: 'TYPE', ref: field.ref, text: value, label: field.label, context: field.context });
    }
  }
  if (!unresolved && !pending.length) for (const node of v.nodes) {
    if (!['button', 'link', 'checkbox', 'radio'].includes(node.role) || node.disabled || !node.name ||
        SENSITIVE.test(node.name) || DANGEROUS.test(`${node.context} ${node.name}`) ||
        blocked(`${node.context} ${node.name}`)) continue;
    actions.push({ kind: 'CLICK', ref: node.ref, role: node.role, label: node.name, context: node.context,
      ...(['checkbox', 'radio'].includes(node.role) && { checked: node.checked }) });
  }
  if (actions.length > MAX_CHOICES) throw Error('choice_limit');
  return { actions, pending, unresolved };
}

function problemFor(v, kind, data = {}, actions = [], progress = {}, recentAction) {
  const nonce = randomBytes(16).toString('hex');
  const safeOption = (value, limit) => clean(String(value).replace(
    /\b\d{3}-\d{2}-\d{4}\b|\b(?:\d[ -]?){13,19}\b/g, '[REDACTED]'), limit);
  const candidates = actions.slice(0, 8).map((a, index) => ({ id: hash([nonce, v.fingerprint, index, a.kind, a.label, a.context]).slice(0, 24),
    label: clean(v.redact(a.kind === 'BIND' ? `${a.key} → ${a.label}` : a.label), 120),
    context: clean(v.redact(a.context), 160), kind: a.kind,
    ...(['checkbox', 'radio'].includes(a.role) && typeof a.checked === 'boolean' && { checked: a.checked }) }));
  return { kind, question: clean(v.redact(data.question ?? 'What should happen next?'), 180),
    ...(data.field && { field: clean(v.redact(data.field), 120) }),
    ...(data.fact_key && { fact_key: data.fact_key }),
    ...(data.options && { options: data.options.slice(0, 8).filter(o =>
      !SENSITIVE.test(`${o.label} ${o.value}`)).map(o => ({ label: safeOption(o.label, 100),
      value: safeOption(o.value, 120) })) }),
    candidates, evidence: v.text, progress, ...(recentAction && { recent_action: recentAction }) };
}

export async function executeBrowser(input, { browser, decide, telemetry, observations, tabState, signal,
  maxSteps = 64, timeoutMs = 120_000 } = {}) {
  let steps = 0, lease, outcome = 'not_dispatched', lastView, recentAction, request, state, resumed = false, scopedResume = false;
  let recoveryOrigins, dispatchedAttempt = false, attemptedAction, attemptedOwner, attemptedStep, actionLogged = false;
  let mutationIncident;
  const run_id = randomBytes(16).toString('base64url');
  let task_id = randomBytes(16).toString('base64url'), total_steps = 0, arbitrations = 0;
  const emit = event => {
    const metric = { ...event, run_id, task_id, ...(event.event === 'run_start' && { task_count: 1 }) };
    try { observations?.emit(metric); } catch { /* metrics cannot affect control flow */ }
    try { telemetry?.(metric); } catch { /* metrics cannot affect control flow */ }
  };
  const result = (status, reason, extra = {}) => {
    let incident_id;
    if (status === 'mutation_unknown') {
      if (typeof mutationIncident === 'string' && /^[0-9a-f]{32}$/.test(mutationIncident)) incident_id = mutationIncident;
      else if (request && typeof tabState?.inspect === 'function') {
        try { incident_id = tabState.inspect(browser.scopeId, request.tabId).incidentId; } catch { /* do not mask a quarantine */ }
      }
    }
    if (typeof incident_id !== 'string' || !/^[0-9a-f]{32}$/.test(incident_id)) incident_id = undefined;
    if (scopedResume) emit({ event: 'resume_result', status: reason === 'continuation_stale' ? 'stale' :
      status === 'ambiguity' ? 'mismatch' : status === 'mutation_unknown' ? 'unknown' :
      status === 'completed' ? 'acknowledged' : status === 'needs_user_input' ? 'needs_user_input' :
      status === 'technical_failure' ? 'failed' : reason === 'technical_recovery' ? 'handoff' :
      steps > 0 ? 'verified' : 'handoff', owner: 'code' });
    if (status === 'mutation_unknown') emit({ event: 'recovery_result', status: 'quarantined', owner: 'code',
      ...(incident_id && { incident_id }) });
    emit({ event: 'run_result', status, reason: status === 'completed' ? 'semantic_finish_reported' :
      ['needs_reasoning', 'needs_user_input', 'ambiguity'].includes(status) ? 'handoff' :
      status === 'mutation_unknown' || status === 'checkpoint' ? 'safety_stop' :
      reason === 'timeout_or_cancelled' ? 'timeout' : 'unknown', steps, owner: status === 'completed' ? 'luna' : 'code',
      outcome: status === 'completed' ? 'semantic_arbitration' : 'unverified',
      ...(['technical_failure', 'ambiguity', 'mutation_unknown'].includes(status) && {
        failure_code: FAILURE_CODES.has(reason) ? reason : reason === 'storage_release_unverified' ? 'storage_error' : 'other' }),
      ...(incident_id && { incident_id }) });
    return { status, reason, steps, task_steps: total_steps + steps, run_id, task_id,
      ...(incident_id && { incident_id }), ...extra };
  };
  try {
    if (!browser?.scopeId || typeof browser.snapshot !== 'function' || typeof decide !== 'function' ||
        typeof tabState?.acquire !== 'function' || !Number.isInteger(maxSteps) || maxSteps < 1 || maxSteps > 128 ||
        !Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 120_000) return result('technical_failure', 'invalid_configuration');
    resumed = record(input) && Object.hasOwn(input, 'continuation_id');
    if (resumed) {
      if (Object.keys(input).sort().join(',') !== 'continuation_id,resolution' ||
          typeof input.continuation_id !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(input.continuation_id) ||
          !record(input.resolution)) throw Error('invalid_continuation_shape');
      state = continuations.get(input.continuation_id);
      if (!state) throw Error('invalid_continuation_unknown');
      if (state.expires <= Date.now()) throw Error('invalid_continuation_expired');
      request = structuredClone(state.request);
    } else { validateRequest(input); request = structuredClone(input); }
    const key = scopeKey(browser.scopeId, request.tabId);
    if (resumed && state.scope !== key) throw Error('invalid_continuation_scope');
    if (resumed) {
      scopedResume = true;
      task_id = state.task_id; total_steps = state.total_steps; arbitrations = state.arbitrations ?? 0;
      recentAction = state.recentAction;
    }
    try { lease = await tabState.acquire(browser.scopeId, request.tabId); }
    catch (e) { return result(e?.message === 'tab_quarantined' ? 'mutation_unknown' : 'technical_failure',
      ['tab_quarantined', 'tab_busy', 'storage_error'].includes(e?.message) ? e.message : 'tab_state_unavailable'); }
    if (!lease || typeof lease.markMutation !== 'function' || typeof lease.release !== 'function') throw Error('invalid_tab_state');
    if (!resumed) emit({ event: 'run_start', mode: 'semantic', owner: 'code' });
    const deadline = AbortSignal.timeout(timeoutMs), combined = signal ? AbortSignal.any([signal, deadline]) : deadline;
    const guard = async promise => {
      if (combined.aborted) throw Error('timeout_or_cancelled');
      let abort;
      try { return await Promise.race([promise, new Promise((_, reject) => {
        abort = () => reject(Error('timeout_or_cancelled'));
        combined.addEventListener('abort', abort, { once: true });
      })]); } finally { combined.removeEventListener('abort', abort); }
    };
    const snap = async () => guard(browser.snapshot(request.tabId, { signal: combined }));
    let raw = await snap();
    const origins = new Set(resumed ? state.origins : [safeUrl(raw.url).origin, ...(request.constraints?.allowedOrigins ?? [])]);
    recoveryOrigins = origins;
    let v = view(raw, request.facts, origins);
    lastView = v;
    if (resumed && state.fingerprint !== v.fingerprint) {
      continuations.delete(input.continuation_id);
      return result('ambiguity', 'continuation_stale');
    }
    let approved;
    if (resumed) {
      const resolution = input.resolution;
      if (resolution.type === 'finish' && Object.keys(resolution).length === 1 &&
          state.problem.kind === 'semantic_boundary') {
        continuations.delete(input.continuation_id);
        return result('completed', 'semantic_arbitration', { verification: 'semantic_arbitration' });
      }
      if (resolution.type === 'user_input' && Object.keys(resolution).sort().join(',') === 'question,type' &&
          typeof resolution.question === 'string' && resolution.question.trim() && resolution.question.length <= 180 &&
          !/[\x00-\x1f\x7f]/.test(resolution.question)) {
        continuations.delete(input.continuation_id);
        return result('needs_user_input', 'operator_input_required', { problem: { ...state.problem, question: resolution.question.trim() } });
      }
      if (arbitrations >= 32) {
        continuations.delete(input.continuation_id);
        return result('checkpoint', 'arbitration_limit');
      }
      if (resolution.type === 'fact' && Object.keys(resolution).sort().join(',') === 'key,type,value' &&
          validFact(resolution.key, resolution.value) && state.expectedKey &&
          ['missing_fact', 'unsupported_choice'].includes(state.problem.kind)) {
        if (state.problem.kind === 'missing_fact' && norm(resolution.key) === norm(state.expectedKey) &&
            Object.keys(request.facts).length < 32 &&
            !Object.keys(request.facts).some(key => norm(key) === norm(resolution.key))) {
          request.facts[resolution.key] = resolution.value;
        } else if (state.problem.kind === 'unsupported_choice' && resolution.key === state.expectedKey &&
            Object.hasOwn(request.facts, state.expectedKey)) {
          const current = resolveSemanticFields({ fields: v.fields.filter(f => f.ref), facts: request.facts,
            bindings: request.bindings }).problems.filter(p => p.kind === 'unsupported_choice' &&
            p.field.label === state.expectedField && p.field.context === state.expectedContext &&
            p.keys.length === 1 && p.keys[0] === state.expectedKey);
          if (current.length !== 1 || (current[0].field.options ?? []).filter(o =>
              o.label === resolution.value || o.value === resolution.value).length !== 1)
            return result('ambiguity', 'fact_not_grounded', {
              continuation_id: input.continuation_id, problem: state.problem });
          request.facts[state.expectedKey] = resolution.value;
        } else return result('ambiguity', 'invalid_resolution', {
          continuation_id: input.continuation_id, problem: state.problem });
        validateRequest(request);
        const p = resolveSemanticFields({ fields: v.fields.filter(f => f.ref), facts: request.facts, bindings: request.bindings });
        if (!p.assignments.some(a => a.key === resolution.key && a.field.label === state.expectedField &&
            a.field.context === state.expectedContext)) return result('ambiguity', 'fact_not_grounded', {
              continuation_id: input.continuation_id, problem: state.problem });
        arbitrations++;
        continuations.delete(input.continuation_id);
      } else if (resolution.type === 'choice' && Object.keys(resolution).sort().join(',') === 'candidateId,type' &&
          typeof resolution.candidateId === 'string') {
        approved = state.actions[state.problem.candidates.findIndex(c => c.id === resolution.candidateId)];
        if (!approved) return result('ambiguity', 'invalid_choice', {
          continuation_id: input.continuation_id, problem: state.problem });
        if (approved.kind === 'BIND') {
          if (!Object.hasOwn(request.facts, approved.key) || !validBinding({ label: approved.label, context: approved.context }) ||
              v.fields.filter(f => f.label === approved.label && f.context === approved.context && f.ref).length !== 1)
            return result('ambiguity', 'binding_not_grounded', {
              continuation_id: input.continuation_id, problem: state.problem });
          request.bindings = { ...(request.bindings ?? {}), [approved.key]: {
            label: approved.label, context: approved.context } };
          validateRequest(request);
          approved = undefined;
        }
        arbitrations++;
        continuations.delete(input.continuation_id);
      } else return result('ambiguity', 'invalid_resolution', {
        continuation_id: input.continuation_id, problem: state.problem });
    }
    const seen = new Set();
    let submissionSeen = state?.submissionSeen ?? false;
    const progress = { assignments_verified: 0, pages_seen: 0 };
    const pages = new Set(state?.pages ?? []);
    const verifiedKeys = new Set(state?.verifiedKeys ?? []);
    const handoff = (kind, data, actions = [], status = 'needs_reasoning') => {
      const problem = problemFor(v, kind, data, actions, { ...progress }, recentAction);
      emit({ event: 'semantic_handoff', kind, candidate_count: problem.candidates.length,
        resolution_owner: 'luna', attribution: 'arbitration_requested' });
      for (const [id, item] of continuations) if (item.expires <= Date.now()) continuations.delete(id);
      if (continuations.size >= 128) continuations.delete(continuations.keys().next().value);
      const continuation_id = randomBytes(32).toString('base64url');
      continuations.set(continuation_id, { request: structuredClone(request), scope: key,
        fingerprint: v.fingerprint, origins: [...origins], problem, actions: structuredClone(actions.slice(0, 8)),
        expectedField: data.field, expectedContext: data.context, expectedKey: data.fact_key,
        submissionSeen, recentAction, task_id, arbitrations,
        total_steps: total_steps + steps, pages: [...pages].slice(-64),
        verifiedKeys: [...verifiedKeys].slice(0, 32), expires: Date.now() + TTL });
      return result(status, kind, { problem, continuation_id });
    };
    for (;;) {
      v = view(raw, request.facts, origins); lastView = v;
      pages.add(hash([v.url.href, v.text]));
      if (pages.size > 64) pages.delete(pages.values().next().value);
      progress.pages_seen = pages.size;
      const plan = resolveSemanticFields({ fields: v.fields.filter(f => f.ref), facts: request.facts, bindings: request.bindings });
      for (const a of plan.assignments) {
        if (a.field.value === request.facts[a.key] || a.field.tag === 'select' && a.field.options?.some(o => o.selected &&
            (o.value === request.facts[a.key] || o.label === request.facts[a.key]))) verifiedKeys.add(a.key);
        else verifiedKeys.delete(a.key);
      }
      progress.assignments_verified = verifiedKeys.size;
      const unsupportedReadOnly = plan.assignments.find(a => a.field.readOnly && a.field.value !== request.facts[a.key] &&
        !(a.field.tag === 'select' && a.field.options?.some(o => o.selected &&
          (o.value === request.facts[a.key] || o.label === request.facts[a.key]))));
      if (unsupportedReadOnly) return handoff('readonly_field', { field: unsupportedReadOnly.field.label,
        question: 'An observed read-only field cannot be changed through this transport.' });
      const unsupportedNumber = plan.assignments.find(a => a.field.type === 'number' && a.field.value &&
        a.field.value !== request.facts[a.key]);
      if (unsupportedNumber) return handoff('unsupported_number_replacement', { field: unsupportedNumber.field.label,
        question: 'A filled numeric control cannot be safely replaced through this transport.' });
      const { actions, pending, unresolved } = candidatesFor(v, request, plan);
      if (v.fields.some(f => !f.ref)) return handoff('ambiguous_mapping', { question: 'Current field cannot be uniquely grounded.', field: v.fields.find(f => !f.ref).label });
      if (plan.problems.length) {
        const p = plan.problems[0];
        const unmatched = Object.keys(request.facts).filter(k => !verifiedKeys.has(k) &&
          !plan.assignments.some(a => a.key === k));
        const problemKind = p.kind === 'missing_fact' && unmatched.length ? 'ambiguous_mapping' : p.kind;
        const mappings = (problemKind === 'ambiguous_mapping' ? (p.keys.length ? p.keys : unmatched) : [])
          .flatMap(key => v.fields.filter(f => f.ref && f.context && (p.keys.length ?
            f.label === p.field.label : f === p.field)).map(f => ({ kind: 'BIND', key, label: f.label, context: f.context })));
        const nativeName = p.field.name;
        const factKey = [nativeName, p.field.label].find(key => typeof key === 'string' &&
          key === clean(key, 100) && norm(key) && validFact(key, 'x'));
        return handoff(problemKind, { field: p.field.label, context: p.field.context,
          ...((problemKind === 'missing_fact' && factKey || problemKind === 'unsupported_choice' &&
            p.keys.length === 1) && { fact_key: problemKind === 'unsupported_choice' ? p.keys[0] : factKey }),
          question: problemKind === 'missing_fact' ? `What value belongs in ${p.field.label}?` : 'Which fact belongs to which observed field?', options: p.options }, mappings);
      }
      if (total_steps + steps >= 128) return result('checkpoint', 'task_action_limit', { progress });
      if (steps >= maxSteps) return result('checkpoint', 'max_steps', { progress });
      let action = pending.length ? actions[0] : approved;
      let actionOwner = pending.length ? 'code' : approved ? 'luna' : 'code';
      if (action && approved) {
        const current = actions.filter(a => a.kind === approved.kind && a.role === approved.role &&
          a.label === approved.label && a.context === approved.context);
        if (current.length !== 1) return result('ambiguity', 'approved_choice_stale');
        action = current[0];
      }
      approved = undefined;
      if (!action && actions.some(a => a.role === 'checkbox' || a.role === 'radio')) {
        const formChoices = actions.filter(a => a.role === 'checkbox' || a.role === 'radio');
        return handoff('form_choice', { question: 'Which observed form choice, if any, is authorized?' },
          [...formChoices, ...actions.filter(a => !formChoices.includes(a))]);
      }
      if (!action && !unresolved) {
        if (submissionSeen) return handoff('semantic_boundary', { question: 'Has this workflow finished, or should it continue?' }, actions);
        const eligible = actions.filter(a => a.kind === 'CLICK');
        if (!recentAction && steps === 0)
          return handoff('semantic_boundary', { question: 'What should happen on this page before any click?' }, eligible);
        if (eligible.length === 1) action = eligible[0];
        else if (eligible.length < 2 || eligible.length > 7) return handoff('semantic_boundary',
          { question: 'Which observed control, if any, should be used?' }, eligible);
        if (!action) {
          const choices = eligible.map(a => `CLICK ${a.role} "${clean(v.redact(a.label), 100)}" (${clean(v.redact(a.context), 80)}) [${a.ref}]`);
          const abstain = 'ESCALATE cannot choose a supported control';
          choices.push(abstain);
          if (new Set(choices).size !== choices.length) return handoff('ambiguous_choice',
            { question: 'The available controls cannot be represented uniquely.' }, eligible);
          const started = performance.now();
          let answer;
          try {
            answer = await guard(decide({ state: { goal: request.goal, variables: request.facts, text: v.text,
              title: clean(v.title), url: `${v.url.origin}${v.url.pathname.slice(0, 200)}`,
              recent: recentAction ? [`${recentAction.kind} ${recentAction.label}`] : [], pagesSeen: [],
              fields: v.fields.slice(0, 32).map(f => ({ label: clean(v.redact(f.label)), context: clean(v.redact(f.context)),
                ref: f.ref, value: clean(v.redact(f.value), 120) })) }, choices }, { signal: combined }));
          } catch (error) {
            emit({ event: 'local_decision', step: steps, candidate_count: choices.length, status: 'error', owner: 'local_model',
              latency_ms: Math.min(120_000, performance.now() - started) });
            if (combined.aborted) throw error;
            return handoff('local_choice_unavailable', { question: 'The local chooser is unavailable. Which control, if any, should be used?' }, eligible);
          }
          const probs = answer?.probabilities;
          const ranked = record(probs) ? choices.map(c => probs[c]).sort((a, b) => b - a) : [];
          const valid = record(probs) && Object.keys(probs).length === choices.length &&
            choices.every(c => Number.isFinite(probs[c]) && probs[c] >= 0 && probs[c] <= 1) &&
            Math.abs(ranked.reduce((a, b) => a + b, 0) - 1) <= 0.001 && choices.includes(answer?.choice) &&
            ranked[0] === probs[answer.choice] && ranked[0] > ranked[1];
          const uncertain = !valid || ranked[0] < 0.5 || ranked[0] - ranked[1] < 0.05 || answer.choice === abstain;
          emit({ event: 'local_decision', step: steps, candidate_count: choices.length,
            selected_index: valid ? choices.indexOf(answer.choice) : undefined,
            ...(valid && { probabilities: choices.map(c => probs[c]), top1: ranked[0], margin: ranked[0] - ranked[1] }),
            latency_ms: Math.min(120_000, performance.now() - started),
            status: !valid ? 'invalid' : uncertain ? 'uncertain' : 'accepted',
            owner: 'local_model' });
          if (uncertain)
            return handoff('uncertain_choice', { question: 'Which control should be used?' }, eligible);
          action = eligible[choices.indexOf(answer.choice)];
          actionOwner = 'local_model';
        }
      }
      if (!action) return handoff('semantic_boundary', { question: 'What should happen next?' }, actions);
      const signature = hash([v.fingerprint, action.kind, action.label, action.context]);
      if (seen.has(signature)) return handoff('action_loop', { question: 'The same action did not advance the workflow.' });
      seen.add(signature);
      const fresh = await snap(), next = view(fresh, request.facts, origins);
      if (v.fingerprint !== next.fingerprint) {
        if (resumed && steps === 0) return result('ambiguity', 'continuation_stale');
        raw = fresh; continue;
      }
      const grounded = action.kind === 'CLICK' ? next.nodes.filter(n =>
        n.role === action.role && n.name === action.label && n.context === action.context && !n.disabled) :
        next.fields.filter(f => f.ref && f.label === action.label && f.context === action.context &&
          f.tag === v.fields.find(f => f.ref === action.ref)?.tag && f.type === v.fields.find(f => f.ref === action.ref)?.type);
      if (grounded.length !== 1 || DANGEROUS.test(`${action.context} ${action.label}`) || SENSITIVE.test(action.label))
        return result('ambiguity', 'action_not_grounded');
      action = { ...action, ref: grounded[0].ref };
      mutationIncident = lease.markMutation(); outcome = 'unknown'; dispatchedAttempt = true;
      attemptedAction = action; attemptedOwner = actionOwner; attemptedStep = steps + 1; actionLogged = false;
      let ack;
      try { ack = await guard(browser[action.kind.toLowerCase()](request.tabId, action, { signal: combined })); }
      catch (error) {
        outcome = error?.mutationOutcome === 'not_dispatched' ? 'not_dispatched' : 'unknown';
        emit({ event: 'action', kind: action.kind, step: steps + 1, deterministic: actionOwner === 'code',
          owner: actionOwner, outcome });
        actionLogged = true;
        throw error;
      }
      if (ack?.dispatched === false) {
        outcome = 'not_dispatched';
        emit({ event: 'action', kind: action.kind, step: steps + 1, deterministic: actionOwner === 'code',
          owner: actionOwner, outcome });
        actionLogged = true;
        const error = Error('action_not_dispatched'); error.mutationOutcome = 'not_dispatched'; throw error;
      }
      steps++;
      recentAction = { kind: action.kind, label: clean(v.redact(action.label), 120), context: clean(v.redact(action.context), 120) };
      raw = await snap();
      const after = view(raw, request.facts, origins);
      // A dispatched click with no observable change may still complete later;
      // never authorize a second click on this tab from a fresh continuation.
      if (action.kind === 'CLICK' && after.fingerprint === v.fingerprint)
        throw Error('action_effect_unverified');
      if (action.kind === 'TYPE' || action.kind === 'SELECT') {
        const f = after.fields.filter(f => f.ref && f.label === action.label && f.context === action.context &&
          f.tag === grounded[0].tag && f.type === grounded[0].type);
        if (f.length !== 1 || !(action.kind === 'TYPE' ? f[0].value === action.text :
            f[0].value === action.option || f[0].options?.some(o => o.selected && o.value === action.option)))
          throw Error('field_value_unverified');
      }
      await lease.release({ outcome: 'verified' });
      lease = undefined;
      dispatchedAttempt = false;
      outcome = 'not_dispatched';
      mutationIncident = undefined;
      emit({ event: 'action', kind: action.kind, step: steps, deterministic: actionOwner === 'code',
        owner: actionOwner, outcome: 'verified' });
      actionLogged = true;
      if (action.kind === 'CLICK') {
        if (/^(?:submit|send|confirm|finish)(?:\b|$)/i.test(action.label) && action.role === 'button') submissionSeen = true;
        if (!after.fields.some(f => f.ref)) {
          v = after;
          pages.add(hash([after.url.href, after.text]));
          progress.pages_seen = pages.size;
          return handoff('semantic_boundary', { question: 'Does this observed page complete the workflow or require another action?' },
            candidatesFor(after, request, resolveSemanticFields({ fields: [], facts: request.facts })).actions);
        }
      }
      lease = await tabState.acquire(browser.scopeId, request.tabId);
    }
  } catch (error) {
    if (dispatchedAttempt && lastView && recoveryOrigins) {
      let timer;
      try {
        const raw = await Promise.race([browser.snapshot(request.tabId, { signal: AbortSignal.timeout(5000) }),
          new Promise((_, reject) => { timer = setTimeout(() => reject(Error('snapshot_timeout')), 5000); })]);
        lastView = view(raw, request.facts, recoveryOrigins);
      } catch { /* no safe fresh view: never use stale evidence */ lastView = undefined; }
      finally { clearTimeout(timer); }
    }
    if (dispatchedAttempt && !actionLogged) emit({ event: 'action', kind: attemptedAction.kind,
      step: attemptedStep, deterministic: attemptedOwner === 'code', owner: attemptedOwner, outcome });
    const recoveryProblem = lastView ? problemFor(lastView, 'technical_recovery',
      { question: outcome === 'unknown' ? 'Remote mutation may have happened; trusted recovery is required.' :
        'The action was not dispatched. Inspect a fresh page before deciding.' }, [], {}, recentAction) :
      { kind: 'technical_recovery', question: 'A fresh safe observation is unavailable. Do not retry this action.',
        candidates: [], evidence: '', progress: {} };
    if (outcome === 'unknown') return result('mutation_unknown', error?.message === 'field_value_unverified' ?
      'field_value_unverified' : error?.message === 'storage_error' ? 'storage_release_unverified' : 'action_outcome_unknown', {
      problem: recoveryProblem,
      recovery_hint: 'Trusted operator must inspect a fresh snapshot and explicitly acknowledge recovery.' });
    if (outcome === 'not_dispatched' && error?.mutationOutcome === 'not_dispatched') return result('needs_reasoning', 'technical_recovery', {
      problem: recoveryProblem });
    return result('technical_failure', ['invalid_request', 'invalid_continuation_shape', 'invalid_continuation_unknown',
      'invalid_continuation_expired', 'invalid_continuation_scope', 'origin_changed', 'incomplete_snapshot',
      'sensitive_fields', 'duplicate_refs', 'timeout_or_cancelled', 'unsafe_url', 'invalid_tab_state',
      'storage_error', 'quarantine_capacity'].includes(error?.message) ?
      error.message : 'backend_or_model_error');
  } finally {
    if (typeof lease?.release === 'function') await lease.release({ outcome });
  }
}
