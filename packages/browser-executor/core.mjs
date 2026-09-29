import { createHash, randomBytes } from 'node:crypto';
import { resolveSemanticFields } from './resolver.mjs';

const MAX_CHOICES = 40;
const SENSITIVE = /\b(?:pass(?:word|phrase)?|secret|token|api[_ -]?key|auth(?:entication|orization)?|credential|card(?:[_ -]?number)?|cvv|cvc|pin[_ -]?(?:code|number)|otp|one[_ -]?time|security[_ -]?code|ssn|social[_ -]?security|account[_ -]?(?:number|no|id)|routing[_ -]?number)\b/i;
const SENSITIVE_ACTION = /\b(?:pass(?:word|phrase)?|secret|token|api[_ -]?key|auth(?:entication|orization)?|credential|card(?:[_ -]?number)?|cvv|cvc|otp|one[_ -]?time|security[_ -]?code|ssn|social[_ -]?security|account[_ -]?(?:number|no|id))\b/i;
const SENSITIVE_VALUE = /\b\d{3}-\d{2}-\d{4}\b|\b(?:\d[ -]?){13,19}\b/g;
const SENSITIVE_VALUE_TEST = new RegExp(SENSITIVE_VALUE.source);
const DANGEROUS_ACTION = /\b(?:pay(?:ment)?(?:\s+(?:now|online))?|submit\s+payment|complete\s+payment|payment\s+submission|finalize\s+purchase|(?:submit|complete|place)\s+order|confirm\s+(?:order|purchase|payment|reservation)|buy\s+now|checkout|purchase|delete\s+(?:account|profile|data)|remove\s+all|transfer\s+(?:money|funds))\b/i;
// This is a conservative handoff boundary, not evidence of business success.
const SUBMISSION_BUTTON = /^(?:submit|send|confirm|finish)(?:\b|$)/i;
const EDITABLE = new Set(['text', 'search', 'email', 'tel', 'url', 'number', 'date', 'time', 'datetime-local', 'month', 'week']);
const locks = new Map();
const continuations = new Map();
const CONTINUATION_TTL = 10 * 60_000;
const MAX_CONTINUATIONS = 128;
const FORWARD = /^(?:open confirmation|continue|review|confirm details|finish inquiry)$/i;
const RESTART = /\b(?:restart|start another|book another|new request|search again|try again)\b/i;
const RECEIPT = /\b(?:receipt|accepted|completed|finished|success(?:ful)?|thank you)\b/i;
const NAVIGATION = /^(?:help|about|browse directory|directory|home|back|done)$/i;
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
const validBinding = binding => {
  const label = typeof binding === 'string' ? binding : binding?.field;
  return (typeof binding === 'string' || record(binding) && Object.keys(binding).length === 2 &&
    Object.hasOwn(binding, 'field') && Object.hasOwn(binding, 'context') &&
    typeof binding.context === 'string' && binding.context.length <= 200 &&
    binding.context.split('/').every(part => normalize(part) && !SENSITIVE.test(part))) &&
    typeof label === 'string' && label.length <= 120 && normalize(label) && !SENSITIVE.test(label);
};
const contextMatches = (actual, expected) => {
  const path = value => value.split('/').map(normalize).filter(Boolean);
  const observed = path(actual), wanted = path(expected);
  return wanted.length > 0 && observed.length >= wanted.length &&
    wanted.every((part, i) => part === observed[observed.length - wanted.length + i]);
};
const selectorMatches = (field, selector) => {
  const name = normalize(typeof selector === 'string' ? selector : selector.field);
  return name && [field.label, field.name, field.axName].some(label => normalize(label) === name) &&
    (typeof selector === 'string' || field.grounded && contextMatches(field.context, selector.context));
};
const validPolicies = policies => policies == null || Array.isArray(policies) && policies.length <= 16 &&
  policies.every(policy => record(policy) && Object.keys(policy).length === 2 &&
    Object.hasOwn(policy, 'field') && Object.hasOwn(policy, 'preserve') && validBinding(policy.field) &&
    typeof policy.preserve === 'string' && policy.preserve.length <= 120 &&
    !SENSITIVE_VALUE_TEST.test(policy.preserve));
const validScope = scope => scope == null || record(scope) && Object.keys(scope).length === 2 &&
  Object.hasOwn(scope, 'title') && Object.hasOwn(scope, 'context') &&
  typeof scope.title === 'string' && scope.title.length <= 140 && normalize(scope.title) && !SENSITIVE.test(scope.title) &&
  validBinding({ field: scope.title, context: scope.context });
const validStopAfter = stop => stop == null || record(stop) &&
  Object.keys(stop).every(key => ['click', 'context'].includes(key)) && Object.hasOwn(stop, 'click') &&
  typeof stop.click === 'string' && stop.click.length <= 120 && normalize(stop.click) && !SENSITIVE.test(stop.click) &&
  (stop.context === undefined ? !Object.hasOwn(stop, 'context') :
    validBinding({ field: stop.click, context: stop.context }));
const invalidRequest = category => { const error = Error('invalid_request'); error.category = category; throw error; };

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

function validateRequest(request, semantic = false) {
  if (!record(request) || Object.keys(request).some(k => !(semantic ? ['goal', 'tabId', 'facts', 'bindings', 'constraints', 'fieldPolicies'] : ['goal', 'modelGoal', 'tabId', 'variables', 'bindings', 'fieldPolicies', 'executionScope', 'stopAfter', 'success', 'allowedOrigins', 'forbidActions']).includes(k)) ||
      typeof request.goal !== 'string' || !request.goal.trim() || request.goal.length > (semantic ? 360 : 2000) ||
       typeof request.tabId !== 'string' || !/^[\w-]{1,128}$/.test(request.tabId) ||
         !record(semantic ? request.facts : request.variables)) invalidRequest('request_shape');
  if (semantic && (request.constraints != null && (!record(request.constraints) ||
      Object.keys(request.constraints).some(k => !['forbidActions', 'allowedOrigins'].includes(k))))) invalidRequest('constraints');
  if (request.modelGoal != null && (typeof request.modelGoal !== 'string' || !request.modelGoal.trim() || request.modelGoal.length > 360))
    invalidRequest('model_goal_length');
  const variables = Object.entries(semantic ? request.facts : request.variables);
  if (variables.length > 32 || variables.some(([k, v]) => !k || k.length > 100 || typeof v !== 'string' || v.length > 100 ||
       SENSITIVE_VALUE_TEST.test(v))) invalidRequest('variables');
  if (request.bindings != null && (!record(request.bindings) || Object.keys(request.bindings).length > 32 ||
      Object.entries(request.bindings).some(([key, binding]) => !Object.hasOwn(semantic ? request.facts : request.variables, key) ||
        !validBinding(binding)))) invalidRequest('bindings');
  if (!validPolicies(request.fieldPolicies)) invalidRequest('field_policies');
  if (!validScope(request.executionScope)) invalidRequest('execution_scope');
  if (!validStopAfter(request.stopAfter) || request.stopAfter != null && request.success != null)
    invalidRequest('stop_after');
  if (request.success != null && (!record(request.success) || !Object.keys(request.success).length ||
       Object.keys(request.success).some(k => !['textIncludes', 'urlPath', 'allText', 'fieldValues'].includes(k)) ||
       Object.entries(request.success).some(([k, v]) => k === 'allText' ?
         !Array.isArray(v) || !v.length || v.length > 8 || v.some(s => typeof s !== 'string' || !s.trim() || s.length > 300) :
         k === 'fieldValues' ? !record(v) || !Object.keys(v).length || Object.keys(v).length > 12 ||
           Object.entries(v).some(([label, value]) => !label || label.length > 120 || typeof value !== 'string' ||
             !value || value.length > 120 || SENSITIVE.test(label) || SENSITIVE_VALUE_TEST.test(value)) :
            typeof v !== 'string' || !v.trim() || v.length > 300))) invalidRequest('success');
  const allowedOrigins = semantic ? request.constraints?.allowedOrigins : request.allowedOrigins;
  const forbidActions = semantic ? request.constraints?.forbidActions : request.forbidActions;
  if (allowedOrigins != null) {
    if (!Array.isArray(allowedOrigins) || allowedOrigins.length > 8) invalidRequest('allowed_origins');
    try {
      if (allowedOrigins.some(origin => safeUrl(origin).origin !== origin)) invalidRequest('allowed_origins');
    } catch { invalidRequest('allowed_origins'); }
  }
  if (forbidActions != null && (!Array.isArray(forbidActions) || forbidActions.length > 24 ||
      forbidActions.some(s => typeof s !== 'string' || !s || s.length > 100))) invalidRequest('forbid_actions');
  if (forbidActions?.some(s => !normalize(s))) invalidRequest('forbid_actions');
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
  // Duplicate DOM labels have no safe positional mapping to AX refs. When the
  // entire same-label group has matching observed values, use AX refs directly
  // for text/number inputs; never invent select options or DOM ownership.
  const axOnly = nodes.filter(node => ['textbox', 'spinbutton'].includes(node.role) && !node.disabled &&
    !fields.some(entry => entry.ref === node.ref) && !SENSITIVE.test(node.name) &&
    (() => {
      const group = fields.filter(({ field }) => !isSensitive(field) && !field.disabled && field.tag === 'input' &&
        (field.type === 'text' && node.role === 'textbox' || field.type === 'number' && node.role === 'spinbutton') &&
        normalize(field.label) === normalize(node.name));
      const peers = nodes.filter(other => other.role === node.role && normalize(other.name) === normalize(node.name) && !other.disabled);
      const counts = values => values.toSorted().join('\u0000');
      return group.length > 1 && group.length === peers.length && group.every(entry => !entry.ref) &&
        counts(group.map(entry => entry.field.value ?? '')) === counts(peers.map(peer => peer.value));
    })());
  const axGroups = new Set(axOnly.map(node => `${node.role}:${normalize(node.name)}`));
  const represented = ({ field, ref }) => ref || axGroups.has(`${field.type === 'number' ? 'spinbutton' : 'textbox'}:${normalize(field.label)}`) &&
    field.tag === 'input' && ['text', 'number'].includes(field.type);
  const state = {
    goal: redact(clean(request.goal, 2000)), url: redact(displayUrl(snapshot.url)),
    variables: Object.fromEntries(Object.entries(request.variables).filter(([key]) => !SENSITIVE.test(key)).map(([key, value]) => [key, redact(clean(value, 100))])),
    title: redact(clean(snapshot.snapshot.match(/^\s*- heading "([^"]+)"/m)?.[1] ?? '', 140)),
    text: semantic.length > 950 ? `${semantic.slice(0, 920)} [observation abbreviated]` : semantic,
    fields: fields.filter(({ field, ref }) => !isSensitive(field) && field.type !== 'hidden' &&
      (ref || !represented({ field, ref }))).map(({ field, ref }) => ({
      label: redact(clean(field.label, 120)), name: clean(field.name, 80), ref,
      value: redact(clean(field.value, 120)), type: field.type,
      ...(ref && { context: redact(nodes.find(node => node.ref === ref)?.context ?? '') }),
    })).concat(nodes.filter(n => !SENSITIVE.test(n.name) &&
      (['spinbutton', 'searchbox'].includes(n.role) && !fields.some(f => f.ref === n.ref) || axOnly.includes(n)))
      .map(n => ({ label: redact(n.name), name: '', ref: n.ref, value: redact(n.value),
        type: n.role === 'spinbutton' ? 'number' : n.role === 'searchbox' ? 'search' : 'text', context: redact(n.context) }))),
  };
  // Keep full observed text (including prices/sidebar), but omit volatile AX refs
  // and structure metadata; canonical field properties still detect option changes.
  const fingerprint = digest([url.href, fields.map(({ field }) => [field.tag, field.type, field.name,
    field.label, field.value, field.disabled, field.required, field.optionsTruncated,
    field.options?.map(o => [o.label, o.value, o.selected])]),
  nodes.map(({ role, name, context, value, disabled }) => [role, name, context, value, disabled]),
  snapshot.snapshot.replace(/\[e\d+\]/g, '')]);
  return { nodes, fields, axOnly, represented, state, fingerprint, visible, url, redact };
}

function actionableFields(viewed) {
  const fields = viewed.fields.filter(({ field, ref }) => ref && !field.disabled && !isSensitive(field))
    .map(({ field, ref }) => ({ ...field, ref, grounded: true, context: viewed.nodes.find(n => n.ref === ref)?.context ?? '',
      axName: viewed.nodes.find(n => n.ref === ref)?.name ?? '',
      axRole: viewed.nodes.find(n => n.ref === ref)?.role ?? '' }));
  const numericNodes = viewed.nodes.filter(n => n.role === 'spinbutton' && !n.disabled && !SENSITIVE.test(n.name));
  const searchNodes = viewed.nodes.filter(n => n.role === 'searchbox' && !n.disabled && !SENSITIVE.test(n.name));
  for (const node of [...numericNodes, ...searchNodes, ...viewed.axOnly]) {
    if (!fields.some(f => f.ref === node.ref)) fields.push({ label: node.name, name: '', type: 'number', tag: 'input',
      grounded: viewed.axOnly.includes(node) || !viewed.fields.some(({ field }) =>
        field.type === 'number' && normalize(field.label) === normalize(node.name)),
       value: node.value, ref: node.ref, context: node.context, axRole: node.role,
       ...(node.role === 'searchbox' && { type: 'search' }),
      ...(node.role === 'textbox' && { type: 'text' }) });
  }
  return { fields, numericNodes, searchNodes };
}

function preservation(viewed, policies) {
  const { fields } = actionableFields(viewed);
  const refs = new Set();
  for (const { field: selector, preserve } of policies ?? []) {
    const name = normalize(typeof selector === 'string' ? selector : selector.field);
    // A hidden field is never a preservation authorization, even if an
    // actionable control elsewhere happens to share its name.
    if (viewed.fields.some(({ field }) => field.type === 'hidden' &&
      [field.label, field.name].some(label => normalize(label) === name)))
      return { reason: 'preserved_field_unverifiable', label: name };
    const candidates = fields.filter(field => field.grounded && selectorMatches(field, selector));
    const observed = typeof selector === 'string' ?
      viewed.fields.some(({ field }) => [field.label, field.name].some(label => normalize(label) === name)) ||
        viewed.nodes.some(node => normalize(node.name) === name && ['textbox', 'combobox', 'spinbutton', 'searchbox'].includes(node.role)) :
      viewed.nodes.some(node => contextMatches(node.context, selector.context));
    if (!candidates.length && !observed) continue; // Future stage, not a missing current field.
    if (candidates.length !== 1 || viewed.fields.some(({ field, ref }) => !ref && field.type !== 'hidden' &&
      [field.label, field.name].some(label => normalize(label) === name) && !viewed.represented({ field, ref })))
      return { reason: 'preserved_field_unverifiable', label: name };
    const candidate = candidates[0];
    const node = viewed.nodes.find(n => n.ref === candidate.ref);
    if (candidate.value !== preserve || node?.value && node.value !== preserve)
      return { reason: 'preserved_field_changed', label: name };
    if (refs.has(candidate.ref)) return { reason: 'preserved_field_unverifiable', label: name };
    refs.add(candidate.ref);
  }
  return { refs };
}

function success(viewed, success) {
  if (!success || !Object.keys(success).length) return false;
  return (!success.urlPath || viewed.url.pathname === success.urlPath) &&
    (!success.textIncludes || viewed.visible.toLowerCase().includes(success.textIncludes.toLowerCase())) &&
    (!success.allText || success.allText.every(text => viewed.visible.toLowerCase().includes(text.toLowerCase()))) &&
    (!success.fieldValues || Object.entries(success.fieldValues).every(([label, value]) => {
      const matches = viewed.fields.filter(({ field, ref }) => ref && !isSensitive(field) &&
        [field.label, viewed.nodes.find(node => node.ref === ref)?.name].some(name => normalize(name) === normalize(label)));
      return matches.length === 1 && matches[0].field.value === value;
    }));
}

function problemEvidence(viewed, problem) {
  const headings = [], candidates = [];
  for (const line of viewed.visible.split('\n')) {
    const heading = /^(\s*)- heading "([^"]+)"/.exec(line);
    if (heading) {
      while (headings.length && headings.at(-1).depth >= heading[1].length) headings.pop();
      headings.push({ depth: heading[1].length, name: heading[2] });
      continue;
    }
    const paragraph = /^\s*- (?:paragraph|text|listitem|alert)\b:?\s*(.*)/.exec(line);
    if (!paragraph?.[1]) continue;
    const text = clean(paragraph[1], 220);
    const normalized = normalize(text);
    const names = [problem.field, ...(problem.options ?? []).map(option => option.label)]
      .map(normalize).filter(name => name.length > 3);
    const relevance = Number(names.some(name => normalized.includes(name))) +
      Number(problem.context && contextMatches(headings.map(h => h.name).join(' / '), problem.context));
    if (relevance) candidates.push({ relevance, text });
  }
  return clean(candidates.toSorted((a, b) => b.relevance - a.relevance)
    .slice(0, 2).map(candidate => candidate.text).join(' | '), 320);
}

function choicesFor(viewed, request, preservedRefs, { candidateMode = 'legacy', stopPolicy = 'success', semanticPlan } = {}) {
  if (viewed.fields.some(({ field }) => isSensitive(field))) throw Error('sensitive_fields');
  const forbidden = request.forbidActions ?? [];
  const blocked = label => forbidden.some(literal => normalize(label).includes(normalize(literal)));
  const { fields: allFields, numericNodes, searchNodes } = actionableFields(viewed);
  const fields = semanticPlan ? semanticPlan.active : request.executionScope ? allFields.filter(field => contextMatches(field.context, request.executionScope.context)) : allFields;
  const unmatchedStructure = viewed.fields.filter(({ field, ref }) => !field.disabled && !viewed.represented({ field, ref }) &&
    (field.tag === 'select' || field.tag === 'textarea' || field.tag === 'input' && EDITABLE.has(field.type || 'text')));
  const prepared = Object.entries(request.variables).filter(([key, value]) => !SENSITIVE.test(key) && value);
  const matches = (field, key) => {
    const words = new Set(normalize(`${field.label} ${field.name}`).split(' '));
    return normalize(key).split(' ').some(word => word.length > 2 && words.has(word));
  };
  const strict = candidateMode === 'strictBindings';
  const binding = key => request.bindings?.[key] ?? key;
  const bound = (field, key) => selectorMatches(field, binding(key));
  if (request.executionScope && unmatchedStructure.some(({ field }) => prepared.some(([key]) => {
    const selector = binding(key);
    return [field.label, field.name].some(label => normalize(label) === normalize(
      typeof selector === 'string' ? selector : selector.field)) || matches(field, key);
  }))) throw Error('scope_conflict');
  const unique = key => fields.filter(f => bound(f, key)).length === 1 &&
    prepared.filter(([other]) => bound(fields.find(f => bound(f, key)), other)).length === 1;
  const aligned = (field, key) => strict || Object.hasOwn(request.bindings ?? {}, key) ?
    bound(field, key) && unique(key) : matches(field, key) && fields.filter(other => matches(other, key)).length === 1;
  if (request.executionScope && prepared.some(([key]) => allFields.some(field => !fields.includes(field) &&
    (strict || Object.hasOwn(request.bindings ?? {}, key) ? bound(field, key) : matches(field, key)))))
    throw Error('scope_conflict');
  const matchedKeys = new Set(prepared.filter(([key]) => fields.some(f => aligned(f, key))).map(([key]) => key));
  const ambiguousBindings = prepared.some(([key]) => (strict || Object.hasOwn(request.bindings ?? {}, key)) &&
    fields.some(field => bound(field, key)) && !unique(key));
  const wrongContext = prepared.some(([key]) => {
    const spec = request.bindings?.[key];
    return record(spec) && fields.some(field => [field.label, field.name, field.axName].some(
      label => normalize(label) === normalize(spec.field))) && !fields.some(field => bound(field, key));
  });
  const currentEditable = [...fields.filter(field => field.tag === 'select' || field.tag === 'textarea' ||
    field.tag === 'input' && EDITABLE.has(field.type || 'text')), ...unmatchedStructure.map(({ field }) => field)];
  const strictUnresolvedFields = strict && !semanticPlan ? currentEditable.filter(field => {
    if (preservedRefs.has(field.ref)) return false;
    const related = prepared.filter(([key]) => bound(field, key));
    return !related.length || new Set(related.map(([, value]) => value)).size !== 1 ||
      related.some(([key]) => currentEditable.filter(other => bound(other, key)).length !== 1) ||
      related.some(([, value]) => field.value !== value && (field.tag !== 'select' ||
        !(field.options ?? []).some(option => option.selected && (option.label === value || option.value === value))));
  }) : [];
  const strictUnresolved = strictUnresolvedFields.length > 0;
  const incompleteForm = semanticPlan ? semanticPlan.problems.length > 0 : ambiguousBindings || wrongContext || strictUnresolved || unmatchedStructure.some(({ field }) => {
    if ((field.type === 'number' && numericNodes.some(n => normalize(n.name) === normalize(field.label))) ||
        (field.type === 'search' && searchNodes.some(n => normalize(n.name) === normalize(field.label)))) return false;
    // An unmapped field has no AX ref, so uniqueness among actionable refs
    // cannot establish whether its observed value satisfies a bound request.
    const related = prepared.filter(([key]) => strict || Object.hasOwn(request.bindings ?? {}, key) ?
      bound(field, key) : matches(field, key));
    return !field.value || related.some(([, value]) => value !== field.value);
  });
  const desired = semanticPlan ? new Map(fields.map(field => [field.ref,
    semanticPlan.assignments.filter(a => a.field === field).map(a => [a.key, request.variables[a.key]])])) : new Map(fields.map(field => {
    const matching = prepared.filter(([key]) => aligned(field, key));
    // Retain unmatched values only for unmatched fields. If an alias has the
    // same value as an aligned key, the aligned key supplies its coverage.
    const alternatives = matching.length ? matching : strict ? [] : prepared.filter(([key, value]) =>
      !Object.hasOwn(request.bindings ?? {}, key) && !matchedKeys.has(key) &&
      !fields.some(other => matches(other, key)) &&
      !prepared.some(([other, v]) => matchedKeys.has(other) && value === v));
    return [field.ref, alternatives];
  }));
  if (fields.some(field => preservedRefs.has(field.ref) && desired.get(field.ref)?.length))
    throw Error('preserved_field_conflict');
  const target = normalize(request.variables.target);
  const targetedNumeric = target && numericNodes.some(n => normalize(n.context).includes(target));
  const targetLinks = target && viewed.nodes.some(n => n.role === 'link' && normalize(n.name).includes(target));
  const pending = field => (desired.get(field.ref) ?? []).some(([, value]) => field.value !== value &&
    (field.tag !== 'select' || !(field.options ?? []).some(o => o.selected && (o.label === value || o.value === value))));
  const stageHasPendingValues = fields.some(pending);
  const unsupportedValue = fields.some(field => field.type === 'number' && field.value && pending(field) ||
    field.tag === 'select' && pending(field) && (desired.get(field.ref) ?? []).some(([, value]) => field.value !== value &&
      (field.optionsTruncated || (field.options ?? []).filter(o => o.value === value || o.label === value).length !== 1)));
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
        semanticPlan && semanticPlan.activeContext && node.context && !contextMatches(node.context, semanticPlan.activeContext) ||
        request.executionScope && !contextMatches(node.context, request.executionScope.context) ||
         (stageHasPendingValues || strictUnresolved || semanticPlan && incompleteForm) && node.role === 'link' ||
        targetLinks && node.role === 'link' && !normalize(node.name).includes(target) ||
         node.role === 'button' && (incompleteForm || stageHasPendingValues ||
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
          field.value !== value && (field.type !== 'number' || !field.value && /^-?\d+(?:\.\d+)?$/.test(value))) {
        add('TYPE', label, { ref, text: value });
      }
    }
  }
  const canScroll = !request.executionScope && /\b(scroll|load more|more results|infinite)\b/i.test(viewed.state.text);
  const canStop = !semanticPlan && !request.stopAfter && !stageHasPendingValues && (stopPolicy === 'checkpoint' || !request.success);
  if (choices.length > MAX_CHOICES - (Number(canScroll) + Number(canStop) + 1)) throw Error('choice_limit');
  if (canScroll) add('SCROLL', 'down 600 pixels', { direction: 'down', amount: 600 });
  if (canStop) add('STOP', 'request human checkpoint', {});
  add('ESCALATE', 'cannot proceed safely', {});
  const unbound = strictUnresolvedFields.filter(field => !prepared.some(([key]) => bound(field, key)));
  const diagnosticFields = unbound.length ? unbound : strictUnresolvedFields.length ? strictUnresolvedFields :
    unmatchedStructure.map(({ field }) => field);
  const diagnosticReason = unbound.length ? 'unbound_current_fields' : ambiguousBindings ? 'ambiguous_current_fields' :
    wrongContext ? 'wrong_field_context' : unmatchedStructure.length ? 'unverifiable_current_fields' : 'unresolved_current_fields';
  return { choices, actions, incompleteForm, unsafeControls, unsupportedValue, diagnosticFields, diagnosticReason };
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
  threshold = 0.5, margin = 0.05, modelGoal, bindings, candidateMode = 'legacy', applyPrepared = false,
  stopPolicy = 'success', contractMode = 'procedural', resolverOptions = {}, defaultPolicy = 'strict',
  problemDetail = 'contextual', semanticBoundary = 'conservative' } = {}) {
  const semantic = contractMode === 'semantic';
  const resume = semantic && record(request) && Object.hasOwn(request, 'continuation_id');
  const resumeInput = request;
  const stored = resume ? continuations.get(request.continuation_id) : null;
  let semanticRequest = resume ? stored?.request : request;
  if (resume && stored) request = stored.request;
  const input = semantic ? { ...request, variables: request?.facts, allowedOrigins: request?.constraints?.allowedOrigins,
    forbidActions: request?.constraints?.forbidActions } : request;
  if (semantic) request = input;
  let steps = 0, currentUrl = '', relevantState = '', diagnosticField = '', diagnosticReason = '', observedAction;
  let problem, evidence, progress, redactProblem = value => value, handoffFingerprint, verifiedSeed = [], trustedOrigins;
  let submissionSeen = resume && stored?.submissionSeen === true;
  const boundedText = (value, limit) => clean(redactProblem(clean(value, limit)), limit);
  const boundedProblem = p => p && ({ kind: p.kind,
    field: boundedText(p.field, 120),
    ...(p.proposed_mapping === 'unknown' && { proposed_mapping: 'unknown' }),
    ...(p.fact_keys && { fact_keys: p.fact_keys.slice(0, 8).map(key => boundedText(key, 100)) }),
    ...(p.context && { context: boundedText(p.context, 120) }),
    ...(p.candidates && { candidates: p.candidates.slice(0, 8).map(c => ({
      field: boundedText(c.field, 120), context: boundedText(c.context, 120) })) }),
    ...(p.options && { options: p.options.slice(0, 8).map(o => ({
      label: boundedText(o.label, 120), value: boundedText(o.value, 120) })) }),
    ...(problemDetail === 'contextual' && evidence && { evidence: boundedText(evidence, 320) }),
  });
  const result = (status, reason) => {
    try { telemetry?.({ event: 'result', status, reason, steps,
      ...(semantic && progress && { assignments_verified: progress.assignments_verified,
        pages_seen: progress.pages_seen, remaining_facts: progress.remaining_fact_keys.length }) }); } catch { /* metrics never affect outcomes */ }
    const problemResult = semantic && problem && ['needs_decision', 'needs_mapping'].includes(status);
    let continuation_id;
    if (semantic && status === 'needs_decision' && problem?.kind === 'missing_fact' &&
        problem.field.length <= 100 && handoffFingerprint && trustedOrigins) {
      const now = Date.now();
      for (const [id, item] of continuations) if (item.expires <= now) continuations.delete(id);
      if (continuations.size >= MAX_CONTINUATIONS) continuations.delete(continuations.keys().next().value);
      continuation_id = randomBytes(32).toString('base64url');
      continuations.set(continuation_id, { request: structuredClone(semanticRequest), scope: tabKey(browser, request.tabId),
        fingerprint: handoffFingerprint, expected: { field: problem.field, context: problem.context ?? '' },
        origins: [...trustedOrigins], verified: [...verifiedSeed], submissionSeen, expires: now + CONTINUATION_TTL });
    }
    return { status, reason, steps,
      ...(continuation_id && { continuation_id }),
      ...(!problemResult && { current_url: currentUrl, relevant_state: relevantState.slice(0, 600) }),
      ...(semantic && { progress: problemResult && progress ? {
        assignments_verified: progress.assignments_verified, pages_seen: progress.pages_seen,
        remaining_facts: progress.remaining_fact_keys.length,
        } : progress, ...(problemResult && { problem: { ...boundedProblem(problem),
          ...(continuation_id && { expected_fact_key: boundedText(problem.field, 100) }) } }) }),
      ...(['unmapped_fields', 'unsupported_value', 'field_unverifiable', 'value_not_applied',
        'preserved_field_changed', 'preserved_field_unverifiable'].includes(reason) && diagnosticField &&
        { diagnostic_field: diagnosticField }),
      ...(['unmapped_fields', 'invalid_request'].includes(reason) && diagnosticReason && { diagnostic_reason: diagnosticReason }),
      ...(['action_outcome_unknown', 'tab_quarantined'].includes(reason) && {
        recovery_hint: 'Remote mutation may complete later. Stop all mutations on this tab; trusted operator must re-snapshot, inspect, then acknowledge recovery.',
      }),
      ...(['matched_on_entry', 'matched_conditions_after_action'].includes(reason) &&
        { verification: 'caller_conditions', matched_conditions: Object.keys(request.success) }),
      ...(['requested_action_observed', 'submission_observed'].includes(reason) && observedAction &&
        { verification: 'action_and_fresh_observation', observed_action: observedAction }) };
  };
  try {
    if (resume && (!record(resumeInput) || Object.keys(resumeInput).some(k => !['continuation_id', 'new_facts'].includes(k)) ||
        typeof resumeInput.continuation_id !== 'string' || !/^[\w-]{43}$/.test(resumeInput.continuation_id) ||
        !record(resumeInput.new_facts) || !Object.keys(resumeInput.new_facts).length || !stored ||
        stored.expires <= Date.now())) invalidRequest('continuation');
    validateRequest(semantic ? semanticRequest : request, semantic);
    if (resume) {
      const added = Object.keys(resumeInput.new_facts);
      if (added.length !== 1 || Object.hasOwn(semanticRequest.facts, added[0]) ||
          normalize(added[0]) !== normalize(stored.expected.field) || !resumeInput.new_facts[added[0]])
        invalidRequest('continuation_facts');
      const candidate = { ...semanticRequest, facts: { ...semanticRequest.facts, ...resumeInput.new_facts } };
      validateRequest(candidate, true);
    }
    if (!browser || typeof browser.snapshot !== 'function' || typeof decide !== 'function' ||
        !Number.isInteger(maxSteps) || maxSteps < 1 || maxSteps > 24 || !Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 120_000 ||
         !Number.isFinite(threshold) || threshold < 0 || threshold > 1 || !Number.isFinite(margin) || margin < 0 || margin > 1 ||
          modelGoal != null && (semantic || typeof modelGoal !== 'string' || !modelGoal.trim() || modelGoal.length > 360) ||
          !['legacy', 'strictBindings'].includes(candidateMode) || !['success', 'checkpoint'].includes(stopPolicy) ||
           !['procedural', 'semantic'].includes(contractMode) || !['strict', 'benign'].includes(defaultPolicy) ||
           !['compact', 'contextual'].includes(problemDetail) ||
           !['conservative', 'none', 'adaptive'].includes(semanticBoundary) ||
          !record(resolverOptions) || Object.keys(resolverOptions).some(k => !['useAliases', 'useContext', 'trackProgress'].includes(k)) ||
          Object.values(resolverOptions).some(v => typeof v !== 'boolean') ||
         typeof applyPrepared !== 'boolean' || applyPrepared && candidateMode !== 'strictBindings' ||
          bindings != null && (!record(bindings) || Object.keys(bindings).length > 32 ||
            Object.entries(bindings).some(([key, binding]) => !Object.hasOwn(request.variables, key) ||
              !validBinding(binding)))) throw Error('invalid_configuration');
  } catch (error) {
    diagnosticReason = error.message === 'invalid_request' ? error.category ?? 'request_shape' : 'configuration';
    return result('escalated', 'invalid_request');
  }
  const key = tabKey(browser, request.tabId);
  if (resume && stored.scope !== key) {
    diagnosticReason = 'continuation_scope';
    return result('escalated', 'invalid_request');
  }
  if (locks.has(key)) return result('escalated', locks.get(key).poisoned ? 'tab_quarantined' : 'tab_busy');
  const lease = { busy: true, poisoned: false, mutationSettled: true };
  locks.set(key, lease);
  if (resume) continuations.delete(resumeInput.continuation_id);
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
    const snapshot = async purpose => {
      if (combined.aborted) throw Error('timeout_or_cancelled');
      const observed = await guard(browser.snapshot(request.tabId, { signal: combined }));
      try { telemetry?.({ event: 'snapshot', purpose, exposed_to_large_model: false }); } catch { /* metadata only */ }
      return observed;
    };
    let raw = await snapshot('initial');
    const initial = safeUrl(raw.url);
    const origins = resume ? new Set(stored.origins) : new Set([initial.origin, ...(request.allowedOrigins ?? [])]);
    trustedOrigins = origins;
    if (resume) {
      const observed = view(raw, request, origins);
      if (stored.fingerprint !== observed.fingerprint)
         return result('escalated', 'continuation_stale');
      const candidate = { ...semanticRequest, facts: { ...semanticRequest.facts, ...resumeInput.new_facts } };
      const plan = resolveSemanticFields({ fields: actionableFields(observed).fields.filter(f =>
        f.tag === 'select' || f.tag === 'textarea' || f.tag === 'input' && EDITABLE.has(f.type || 'text')),
      facts: { [Object.keys(resumeInput.new_facts)[0]]: Object.values(resumeInput.new_facts)[0] }, ...resolverOptions });
      if (plan.assignments.length !== 1 || plan.assignments[0].field.label !== stored.expected.field ||
          plan.assignments[0].field.context !== stored.expected.context ||
          plan.problems.some(p => p.field === stored.expected.field && p.context === stored.expected.context))
        return result('escalated', 'continuation_mismatch');
      semanticRequest = candidate;
      request = { ...candidate, variables: candidate.facts, allowedOrigins: candidate.constraints?.allowedOrigins,
        forbidActions: candidate.constraints?.forbidActions };
      verifiedSeed = stored.verified;
    }
    const seen = new Set();
    let recent = [], pagesSeen = [], decisions = 0, scopeUrl;
    const verified = new Set(verifiedSeed), pinned = [];
    const task = { ...request, bindings: bindings ?? request.bindings };
    for (;;) {
      const v = view(raw, request, origins);
      handoffFingerprint = v.fingerprint;
      redactProblem = v.redact;
      currentUrl = v.redact(displayUrl(raw.url));
      relevantState = clean(v.state.text, 600);
      diagnosticField = ''; diagnosticReason = '';
      const page = `${v.state.title} ${v.state.url}`;
      if (!pagesSeen.includes(page)) pagesSeen = [...pagesSeen, page].slice(-4);
      const preserved = preservation(v, [...(task.fieldPolicies ?? []), ...pinned]);
      if (preserved.reason) {
        diagnosticField = v.redact(clean(preserved.label, 120));
        return result('escalated', preserved.reason);
      }
      if (task.executionScope && !(steps && success(v, request.success))) {
        scopeUrl ??= v.url.href;
        if (scopeUrl !== v.url.href) return result('escalated', 'scope_changed');
        if (v.state.title !== task.executionScope.title ||
            v.nodes.filter(node => node.role === 'button' && !node.disabled &&
              contextMatches(node.context, task.executionScope.context)).length !== 1)
          return result('escalated', 'scope_unverifiable');
      }
      if (request.success && task.fieldPolicies?.length && success(v, request.success))
        choicesFor(v, task, preserved.refs, { candidateMode, stopPolicy });
      if (success(v, request.success)) return steps ? result('completed', 'matched_conditions_after_action') :
        result('checkpoint', 'matched_on_entry');
      if (steps >= maxSteps && !(semantic && semanticBoundary === 'adaptive')) break;
      if (++decisions > maxSteps * 3) throw Error('decision_limit');
      const semanticPlan = semantic ? resolveSemanticFields({ fields: actionableFields(v).fields.filter(f =>
        f.tag === 'select' || f.tag === 'textarea' || f.tag === 'input' && EDITABLE.has(f.type || 'text')),
      facts: request.variables, bindings: task.bindings, ...resolverOptions }) : undefined;
      if (semanticPlan) for (const entry of v.fields) {
        const { field, ref } = entry;
        if (ref || v.represented(entry) || field.disabled || field.type === 'hidden' ||
            !(field.tag === 'select' || field.tag === 'textarea' || field.tag === 'input' && EDITABLE.has(field.type || 'text'))) continue;
        if (semanticPlan.activeContext && ![field.label, field.name].some(name =>
          semanticPlan.active.some(active => contextMatches(active.context, semanticPlan.activeContext) &&
            normalize(active.label) === normalize(name)))) continue;
        semanticPlan.problems.push({ kind: 'ambiguous_mapping', field: field.label,
          fact_keys: Object.keys(request.variables).filter(key => normalize(key) === normalize(field.label) ||
            normalize(key) === normalize(field.name)).slice(0, 8), candidates: [], context: '' });
      }
      if (semanticPlan && defaultPolicy === 'benign') {
        for (const field of semanticPlan.active) {
          if (semanticPlan.assignments.some(a => a.field === field) || !field.value || !field.context || field.required !== false ||
              field.type !== 'text' || !field.grounded || isSensitive(field)) continue;
          const selector = { field: field.label, context: field.context };
          if (!pinned.some(p => JSON.stringify(p.field) === JSON.stringify(selector))) pinned.push({ field: selector, preserve: field.value });
        }
        const checked = preservation(v, [...(task.fieldPolicies ?? []), ...pinned]);
        if (checked.reason) return result('escalated', checked.reason);
        preserved.refs = checked.refs;
        semanticPlan.problems = semanticPlan.problems.filter(p => !(p.kind === 'missing_fact' && !p.fact_keys?.length &&
          pinned.some(pin => pin.field.field === p.field && pin.field.context === p.context)));
      }
      if (semanticPlan && task.fieldPolicies?.length) {
        const explicitlyPreserved = preservation(v, task.fieldPolicies).refs;
        const preservedProblem = p => [...explicitlyPreserved].some(ref =>
          semanticPlan.active.some(f => f.ref === ref && f.label === p.field && f.context === p.context));
        if (semanticPlan.problems.some(p => preservedProblem(p) && p.fact_keys?.length))
          return result('escalated', 'preserved_field_conflict');
        semanticPlan.problems = semanticPlan.problems.filter(p => !(p.kind === 'missing_fact' &&
          !p.fact_keys?.length && preservedProblem(p)));
      }
      if (semanticPlan) {
        if (resolverOptions.trackProgress !== false) {
          for (const a of semanticPlan.assignments) {
            if (a.field.value === request.variables[a.key]) verified.add(a.key);
            else verified.delete(a.key);
          }
          progress = { assignments_verified: verified.size, pages_seen: pagesSeen.length,
            remaining_fact_keys: Object.keys(request.variables).filter(k =>
              (k !== 'target' || semanticPlan.assignments.some(a => a.key === k)) && !verified.has(k)).slice(0, 32) };
        }
        for (const a of semanticPlan.assignments) try { telemetry?.({ event: 'mapping', evidence: a.evidence }); } catch { /* metadata only */ }
        problem = semanticPlan.problems.find(p => p.kind === 'ambiguous_mapping');
        if (problem) {
          if (problemDetail === 'contextual') evidence = problemEvidence(v, problem);
          return result('needs_mapping', 'ambiguous_mapping');
        }
      }
      const { choices, actions, incompleteForm, unsafeControls, unsupportedValue, diagnosticFields,
        diagnosticReason: unresolvedReason } = choicesFor(v, task, preserved.refs, { candidateMode: semantic ? 'strictBindings' : candidateMode,
        stopPolicy, semanticPlan });
      if (semantic && semanticBoundary === 'adaptive' &&
          (submissionSeen || RECEIPT.test(`${v.state.title} ${v.state.text}`) &&
            v.nodes.some(n => !n.disabled && ['button', 'link'].includes(n.role) && RESTART.test(n.name))) &&
          !semanticPlan.active.length &&
          !v.fields.some(({ field }) => !field.disabled && (field.tag === 'select' || field.tag === 'textarea' ||
            field.tag === 'input' && EDITABLE.has(field.type || 'text'))) &&
          !v.nodes.some(n => !n.disabled && ['textbox', 'searchbox', 'combobox', 'spinbutton'].includes(n.role))) {
        const legal = [...actions.values()].filter(a => a.kind === 'CLICK').map(a => v.nodes.find(n => n.ref === a.ref))
          .filter(n => n && ['button', 'link'].includes(n.role));
        const forward = legal.filter(n => FORWARD.test(n.name));
        const restart = v.nodes.some(n => !n.disabled && ['button', 'link'].includes(n.role) && RESTART.test(n.name));
        const terminal = RECEIPT.test(`${v.state.title} ${v.state.text}`);
        const distractors = legal.filter(n => n !== forward[0] &&
          (n.role !== 'link' || !NAVIGATION.test(n.name)) && !RESTART.test(n.name));
        const boundary = unsafeControls ? 'unsafe_controls' :
          forward.length === 1 && !restart && !distractors.length ? 'unique_forward' :
            terminal && !forward.length && !distractors.length ? 'terminal_observed' : 'ambiguous_boundary';
        try { telemetry?.({ event: 'boundary', reason: boundary }); } catch { /* metadata only */ }
        if (boundary === 'terminal_observed') return result('checkpoint', 'terminal_observed');
        if (boundary !== 'unique_forward') return result('checkpoint', 'boundary_unresolved');
        // Only the uniquely legal, narrowly named forward control is available.
        for (const [choice, action] of actions) if (action.kind !== 'ESCALATE' &&
          (action.kind !== 'CLICK' || action.ref !== forward[0].ref)) {
          actions.delete(choice);
          choices.splice(choices.indexOf(choice), 1);
        }
      }
      if (![...actions.values()].some(action => !['STOP', 'ESCALATE'].includes(action.kind))) {
        diagnosticReason = unresolvedReason;
        diagnosticField = clean(v.redact((diagnosticFields.length ? diagnosticFields : v.state.fields.filter(field => !field.ref))
          .slice(0, 3).map(field => [field.context, field.label].filter(Boolean).join(' / ')).join('; ')), 120);
        if (unsupportedValue) diagnosticField = v.state.fields.filter(field => field.ref &&
          (field.type === 'number' || v.fields.some(({ field: observed, ref }) => ref === field.ref && observed.tag === 'select')))
          .map(field => field.label).slice(0, 3).join('; ');
        if (semantic && semanticPlan?.problems.length) {
          problem = semanticPlan.problems[0];
          verifiedSeed = [...verified];
          if (problemDetail === 'contextual') evidence = problemEvidence(v, problem);
          return result(['missing_fact', 'unsupported_choice'].includes(problem.kind) ? 'needs_decision' : 'needs_mapping', problem.kind);
        }
        return unsupportedValue ? result('escalated', 'unsupported_value') : incompleteForm ? result('escalated', 'unmapped_fields') : unsafeControls ?
          result('escalated', 'unsafe_controls') : result('checkpoint', 'no_actionable_controls');
      }
      if (steps >= maxSteps) break;
      const prepared = (applyPrepared || semantic) ? choices.filter(c => ['TYPE', 'SELECT'].includes(actions.get(c)?.kind)) : [];
      const automatic = prepared[0];
      const answer = automatic ? null : await guard(decide({ state: { ...v.state,
        goal: v.redact(semantic ? v.state.goal : modelGoal ?? request.modelGoal ?? v.state.goal),
        bindings: task.bindings, terminal_conditions_met: false,
        recent, pagesSeen, ...(semantic && { fields: v.state.fields.filter(f => !semanticPlan.activeContext ||
          contextMatches(f.context, semanticPlan.activeContext)), variables: Object.fromEntries(
          Object.entries(v.state.variables).filter(([key]) => semanticPlan.assignments.some(a => a.key === key))) }) }, choices: [...choices] }, { signal: combined }));
      if (answer?.probabilities && typeof answer.probabilities === 'object') {
        const ranked = Object.values(answer.probabilities).filter(Number.isFinite).sort((a, b) => b - a);
        try { telemetry?.({ event: 'decision', kind: String(answer.choice ?? '').split(' ')[0].slice(0, 12),
          index: choices.indexOf(answer.choice), confidence: ranked[0], margin: ranked[0] - ranked[1], candidates: choices.length }); } catch { /* metadata only */ }
      }
      const choice = automatic ?? validateDecision(answer, choices, threshold, margin);
      const action = actions.get(choice);
      if (action.kind === 'STOP') return result('checkpoint', 'model_stop');
      if (action.kind === 'ESCALATE') return result('escalated', 'model_escalation');
      const stopMatches = task.stopAfter && action.kind === 'CLICK' ? v.nodes.filter(node =>
        !node.disabled && ['button', 'link'].includes(node.role) && node.name === task.stopAfter.click &&
        (!task.stopAfter.context || contextMatches(node.context, task.stopAfter.context))) : [];
      if (stopMatches.some(node => node.ref === action.ref) && stopMatches.length !== 1)
        return result('escalated', 'ambiguous_stop_after');
      const stoppingClick = stopMatches.length === 1 && stopMatches[0].ref === action.ref ? stopMatches[0] : null;
      const tuple = `${v.fingerprint}:${choice.replace(/\[e\d+\]/g, '[ref]')}`;
      if (seen.has(tuple)) return result('escalated', 'action_loop');
      seen.add(tuple);
      // A fresh snapshot before mutation prevents stale refs after model latency.
      if (combined.aborted) throw Error('timeout_or_cancelled');
      const fresh = await snapshot('pre_action');
      const next = view(fresh, request, origins);
      if (resume && !mutationStarted && next.fingerprint !== stored.fingerprint)
        return result('escalated', 'continuation_stale');
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
      try { telemetry?.({ event: 'action', kind: action.kind, step: steps, deterministic: Boolean(automatic) }); } catch { /* observation must not affect browser control */ }
      raw = await snapshot('post_action');
      safeUrl(raw.url);
      observedAfterMutation = true;
      currentUrl = v.redact(displayUrl(raw.url));
      const after = view(raw, request, origins);
      if (after.fingerprint === v.fingerprint) return result('escalated', 'no_state_change');
      if (action.kind === 'TYPE' || action.kind === 'SELECT') {
        const beforeNode = v.nodes.find(node => node.ref === action.ref);
        diagnosticField = v.redact(clean(beforeNode?.name, 120));
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
      if (stoppingClick) {
        const preservedAfter = preservation(after, task.fieldPolicies);
        if (preservedAfter.reason) {
          diagnosticField = clean(after.redact(preservedAfter.label), 120);
          return result('escalated', preservedAfter.reason);
        }
        currentUrl = after.redact(displayUrl(raw.url));
        relevantState = clean(after.state.text, 600);
        observedAction = { click: clean(v.redact(stoppingClick.name), 120),
          context: clean(v.redact(stoppingClick.context), 200) };
        return result('checkpoint', 'requested_action_observed');
      }
      const clicked = action.kind === 'CLICK' ? v.nodes.find(node => node.ref === action.ref) : null;
      if (semantic && clicked?.role === 'button' && SUBMISSION_BUTTON.test(clicked.name)) submissionSeen = true;
      if (semantic && semanticBoundary === 'conservative' && clicked?.role === 'button' &&
          SUBMISSION_BUTTON.test(clicked.name) &&
          !after.fields.some(({ field }) => !field.disabled && (field.tag === 'select' || field.tag === 'textarea' ||
            field.tag === 'input' && EDITABLE.has(field.type || 'text'))) &&
          !after.nodes.some(node => !node.disabled && ['textbox', 'searchbox', 'combobox', 'spinbutton'].includes(node.role))) {
        const preservedAfter = preservation(after, [...(task.fieldPolicies ?? []), ...pinned]);
        if (preservedAfter.reason) {
          diagnosticField = clean(after.redact(preservedAfter.label), 120);
          return result('escalated', preservedAfter.reason);
        }
        const pageAfter = `${after.state.title} ${after.state.url}`;
        if (!pagesSeen.includes(pageAfter)) pagesSeen = [...pagesSeen, pageAfter].slice(-4);
        if (progress) progress.pages_seen = pagesSeen.length;
        relevantState = clean(after.state.text, 320);
        observedAction = { click: clean(v.redact(clicked.name), 120), context: clean(v.redact(clicked.context), 200) };
        return result('checkpoint', 'submission_observed');
      }
    }
  } catch (error) {
    if (mutationStarted && !observedAfterMutation) {
      lease.poisoned = true;
      reason = 'action_outcome_unknown';
    } else reason = ['origin_changed', 'choice_limit', 'choice_representation_limit', 'model_input_limit', 'model_rejected_input',
      'model_timeout', 'model_exit', 'model_output_limit', 'invalid_native_answer', 'backend_unavailable', 'response_too_large',
      'action_loop', 'decision_limit', 'incomplete_snapshot', 'sensitive_fields', 'duplicate_refs', 'ambiguous_choices',
        'invalid_model_output', 'uncertain', 'timeout_or_cancelled', 'preserved_field_conflict', 'scope_conflict'].includes(error.message) ? error.message :
      combined.aborted ? 'timeout_or_cancelled' : 'backend_or_model_error';
  } finally {
    lease.busy = false;
    if (!lease.poisoned) locks.delete(key);
  }
   return semantic && reason === 'max_steps' ? result('checkpoint', 'max_steps') : result('escalated', reason);
}

/** In-memory diagnostic entry point; uses the same guarded execution and tab lease. */
export function executeSemanticBrowser(request, options) {
  return executeBrowser(request, { ...options, contractMode: 'semantic' });
}
