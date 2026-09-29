import { createCamofoxBrowser } from './camofox.mjs';
import { executeBrowser } from './core.mjs';
import { createDecisionBridge } from './bridge.mjs';
import { appendFileSync, closeSync, fchmodSync, fstatSync, openSync } from 'node:fs';
import { constants } from 'node:fs';
import { lstatSync } from 'node:fs';
import process from 'node:process';

const metricEvents = new Set(['action', 'decision', 'failure', 'model_call', 'result', 'snapshot', 'mapping', 'boundary']);
const boundaryReasons = new Set(['terminal_observed', 'unsafe_controls', 'unique_forward', 'ambiguous_boundary']);
const evidenceClasses = new Set(['exactLabel', 'exactName', 'alias', 'type', 'options', 'context']);
const actionKinds = new Set(['CLICK', 'TYPE', 'SELECT', 'SCROLL', 'NAVIGATE', 'STOP', 'ESCALATE']);
const backends = new Set(['kev', 'laya']);
const snapshotPurposes = new Set(['initial', 'pre_action', 'post_action']);
const resultReasons = new Set([
  'invalid_request', 'tab_busy', 'tab_quarantined', 'matched_on_entry', 'matched_conditions_after_action',
  'preserved_field_changed', 'preserved_field_unverifiable', 'scope_changed', 'scope_unverifiable',
  'unsupported_value', 'unmapped_fields', 'unsafe_controls', 'no_actionable_controls',
  'model_stop', 'model_escalation', 'action_loop', 'no_state_change', 'field_unverifiable', 'value_not_applied',
  'action_outcome_unknown', 'max_steps', 'state_changed', 'origin_changed', 'choice_limit',
  'choice_representation_limit', 'model_input_limit', 'model_rejected_input', 'model_timeout', 'model_exit',
  'model_output_limit', 'invalid_native_answer', 'backend_unavailable', 'response_too_large',
  'decision_limit', 'incomplete_snapshot', 'sensitive_fields', 'duplicate_refs', 'ambiguous_choices',
  'invalid_model_output', 'uncertain', 'timeout_or_cancelled', 'preserved_field_conflict',
  'scope_conflict', 'backend_or_model_error',
  'requested_action_observed', 'ambiguous_stop_after',
  'submission_observed',
  'missing_fact', 'ambiguous_mapping', 'unsupported_choice',
  'continuation_stale', 'continuation_mismatch', 'terminal_observed', 'boundary_unresolved',
]);
const fieldSelectorSchema = { oneOf: [
  { type: 'string', minLength: 1, maxLength: 120 },
  { type: 'object', additionalProperties: false, required: ['field', 'context'], properties: {
    field: { type: 'string', minLength: 1, maxLength: 120 },
    context: { type: 'string', minLength: 1, maxLength: 200 },
  } },
] };

export function createValueFreeMetricSink(path) {
  if (typeof path !== 'string' || !path.startsWith('/')) return undefined;
  return event => {
    try {
      if (!event || !metricEvents.has(event.event)) return;
      const safe = { event: event.event };
      if (backends.has(event.backend)) safe.backend = event.backend;
      if (event.event === 'action') {
        if (actionKinds.has(event.kind)) safe.kind = event.kind;
        if (Number.isSafeInteger(event.step) && event.step >= 0) safe.step = event.step;
        if (typeof event.deterministic === 'boolean') safe.deterministic = event.deterministic;
      }
      if (event.event === 'decision') {
        if (actionKinds.has(event.kind)) safe.kind = event.kind;
        for (const key of ['index', 'candidates'])
          if (Number.isSafeInteger(event[key]) && event[key] >= 0) safe[key] = event[key];
        for (const key of ['confidence', 'margin'])
          if (Number.isFinite(event[key])) safe[key] = event[key];
      }
      if (event.event === 'snapshot') {
        if (snapshotPurposes.has(event.purpose)) safe.purpose = event.purpose;
        safe.exposed_to_large_model = event.exposed_to_large_model === true;
      }
      if (event.event === 'result') {
        if (['completed', 'checkpoint', 'escalated', 'needs_decision', 'needs_mapping'].includes(event.status)) safe.status = event.status;
        if (Number.isSafeInteger(event.steps) && event.steps >= 0) safe.steps = event.steps;
        if (resultReasons.has(event.reason)) safe.reason = event.reason;
        for (const key of ['assignments_verified', 'pages_seen', 'remaining_facts'])
          if (Number.isSafeInteger(event[key]) && event[key] >= 0) safe[key] = event[key];
      }
      if (event.event === 'mapping' && evidenceClasses.has(event.evidence)) safe.evidence = event.evidence;
      if (event.event === 'boundary' && boundaryReasons.has(event.reason)) safe.reason = event.reason;
      for (const key of ['latency_ms', 'wall_ms'])
        if (Number.isFinite(event[key]) && event[key] >= 0) safe[key] = event[key];
      let fd;
      try {
        try {
          const existing = lstatSync(path);
          if (!existing.isFile() || existing.uid !== process.getuid()) return;
        } catch (error) { if (error.code !== 'ENOENT') return; }
        fd = openSync(path, constants.O_WRONLY | constants.O_APPEND | constants.O_CREAT | constants.O_NOFOLLOW, 0o600);
        const status = fstatSync(fd);
        if (!status.isFile() || status.uid !== process.getuid()) return;
        fchmodSync(fd, 0o600);
        appendFileSync(fd, `${JSON.stringify(safe)}\n`);
      } finally { if (fd !== undefined) closeSync(fd); }
    } catch { /* telemetry must never affect browser outcomes */ }
  };
}

/**
 * Integrate inside the trusted wrapper: scope(ctx) MUST return the existing HMAC-derived
 * Camofox userId, not ctx.agentId, sessionKey, or a caller supplied value.
 * decide is a configured local bridge; it does not receive credentials or backend config.
 */
export function registerBrowserExecutor(api, { scope, decide, baseUrl, accessKey, telemetry, maxSteps, timeoutMs, threshold, margin,
  modelGoal, bindings, candidateMode, applyPrepared, stopPolicy, contractMode = 'procedural', resolverOptions, defaultPolicy,
  semanticProblemDetail = 'contextual', semanticBoundary = 'conservative' }) {
  if (typeof scope !== 'function' || typeof decide !== 'function') throw Error('scope_and_bridge_required');
  if (!['procedural', 'semantic'].includes(contractMode)) throw Error('invalid_contract_mode');
  if (!['compact', 'contextual'].includes(semanticProblemDetail)) throw Error('invalid_semantic_problem_detail');
  if (!['conservative', 'none', 'adaptive'].includes(semanticBoundary)) throw Error('invalid_semantic_boundary');
  const semantic = contractMode === 'semantic';
  api.registerTool(ctx => ({
    name: 'browser_execute',
    description: 'Execute a bounded browser goal in an existing scoped Camofox tab; escalates when uncertain.',
    parameters: semantic ? {
      type: 'object', additionalProperties: false, oneOf: [
        { required: ['goal', 'tabId', 'facts'] },
        { required: ['continuation_id', 'new_facts'] },
      ],
      properties: {
        continuation_id: { type: 'string', pattern: '^[A-Za-z0-9_-]{43}$',
          description: 'Opaque single-use process-local handoff ID from needs_decision.' },
        new_facts: { type: 'object', minProperties: 1, maxProperties: 1,
          propertyNames: { minLength: 1, maxLength: 100 }, additionalProperties: { type: 'string', maxLength: 100 },
          description: 'One new fact keyed by problem.expected_fact_key for the missing field; original goal and restrictions remain fixed.' },
        goal: { type: 'string', minLength: 1, maxLength: 360,
          description: 'Concise, complete navigation objective; supply field values in facts and enforceable restrictions in constraints.' },
        tabId: { type: 'string', pattern: '^[A-Za-z0-9_-]{1,128}$' },
        facts: { type: 'object', maxProperties: 32, propertyNames: { minLength: 1, maxLength: 100 },
          additionalProperties: { type: 'string', maxLength: 100 } },
        constraints: { type: 'object', additionalProperties: false, properties: {
          forbidActions: { type: 'array', maxItems: 24, items: { type: 'string', minLength: 1, maxLength: 100 } },
          allowedOrigins: { type: 'array', maxItems: 8, items: { type: 'string' } },
        } },
        bindings: { type: 'object', maxProperties: 32, additionalProperties: fieldSelectorSchema },
        fieldPolicies: { type: 'array', maxItems: 16, items: { type: 'object', additionalProperties: false,
          required: ['field', 'preserve'], properties: { field: fieldSelectorSchema,
            preserve: { type: 'string', maxLength: 120 } } } },
      },
    } : {
      type: 'object', additionalProperties: false,
      properties: {
        goal: { type: 'string', minLength: 1, maxLength: 2000 },
        modelGoal: { type: 'string', minLength: 1, maxLength: 360,
          description: 'Optional concise local-model goal. It does not supply variables or change the full goal.' },
        tabId: { type: 'string', pattern: '^[A-Za-z0-9_-]{1,128}$' },
        variables: { type: 'object', maxProperties: 32, propertyNames: { minLength: 1, maxLength: 100 },
          additionalProperties: { type: 'string', maxLength: 100 },
          description: 'Explicit values to set; goal/modelGoal text alone does not generate field actions.' },
        bindings: { type: 'object', maxProperties: 32, additionalProperties: fieldSelectorSchema,
          description: 'Variable keys map to exact observed field labels/names, optionally qualified by a heading context; no selectors.' },
        fieldPolicies: { type: 'array', maxItems: 16, description: 'Preserve an exact value already observed in a uniquely grounded field.',
          items: { type: 'object', additionalProperties: false,
            required: ['field', 'preserve'], properties: {
              field: fieldSelectorSchema,
              preserve: { type: 'string', maxLength: 120 },
            },
          } },
        executionScope: { type: 'object', additionalProperties: false, required: ['title', 'context'],
          description: 'Anchor actions to one observed page title and heading context; cannot authorize another nonterminal page.',
          properties: { title: { type: 'string', minLength: 1, maxLength: 120 },
            context: { type: 'string', minLength: 1, maxLength: 200 } } },
        stopAfter: { type: 'object', additionalProperties: false, required: ['click'],
          description: 'Alternative to success when the receipt is unknown: checkpoint only after a unique legal button/link click and fresh changed observation; not proof of completion.',
          properties: { click: { type: 'string', minLength: 1, maxLength: 120,
            description: 'Exact observed button or link name, never a selector.' },
          context: { type: 'string', minLength: 1, maxLength: 200,
            description: 'Optional observed heading path or trailing heading components.' } } },
        success: { type: 'object', additionalProperties: false, minProperties: 1,
          description: 'All supplied checks must match. Completion proves only these caller conditions, not the full goal.', properties: {
            textIncludes: { type: 'string', minLength: 1, maxLength: 300 },
            urlPath: { type: 'string', minLength: 1, maxLength: 300 },
            allText: { type: 'array', minItems: 1, maxItems: 8, items: { type: 'string', minLength: 1, maxLength: 300 } },
            fieldValues: { type: 'object', minProperties: 1, maxProperties: 12,
              propertyNames: { minLength: 1, maxLength: 120 },
              additionalProperties: { type: 'string', minLength: 1, maxLength: 120 } },
          } },
        allowedOrigins: { type: 'array', maxItems: 8, items: { type: 'string' },
          description: 'Exact additional origins only; never an arbitrary navigation URL.' },
        forbidActions: { type: 'array', maxItems: 24, items: { type: 'string', minLength: 1, maxLength: 100 } },
      }, required: ['goal', 'tabId', 'variables'],
    },
    async execute(_id, params) {
      const userId = scope(ctx);
      const browser = createCamofoxBrowser({ baseUrl, userId, accessKey });
      const outcome = await executeBrowser(params, { browser, decide, telemetry, maxSteps, timeoutMs, threshold, margin,
        modelGoal, bindings, candidateMode, applyPrepared, stopPolicy, contractMode, resolverOptions, defaultPolicy,
        problemDetail: semanticProblemDetail, semanticBoundary });
      return { content: [{ type: 'text', text: JSON.stringify(outcome) }] };
    },
  }), { name: 'browser_execute' });
}

/** Trusted wrapper entry point. Executable and backend come from deployment config, never tool input. */
export function registerHybridBrowserExecutor(api, { executable, backend = 'kev', onMetric, history, representation, ...options }) {
  const decide = createDecisionBridge({ executable, backend, onMetric, history, representation });
  try {
    // The synthetic .2/.01 arm is not a calibrated production policy.
    registerBrowserExecutor(api, { ...options, decide,
      threshold: options.threshold ?? 0.5, margin: options.margin ?? 0.05 });
  } catch (error) {
    decide.close();
    throw error;
  }
  return { close: decide.close };
}

/** Useful without the local model: scoped native select for the large-model control path. */
export function registerScopedSelect(api, { scope, baseUrl, accessKey }) {
  if (typeof scope !== 'function') throw Error('scope_required');
  api.registerTool(ctx => ({
    name: 'camofox_select',
    description: 'Select an observed native option by current Camofox ref and exact option label or value.',
    parameters: { type: 'object', additionalProperties: false, required: ['tabId', 'ref', 'option'],
      properties: { tabId: { type: 'string' }, ref: { type: 'string' }, option: { type: 'string' } } },
    async execute(_id, params) {
      if (!params || typeof params.tabId !== 'string' || !/^[\w-]{1,128}$/.test(params.tabId) ||
          typeof params.ref !== 'string' || !/^e\d{1,6}$/.test(params.ref) ||
          typeof params.option !== 'string' || !params.option || params.option.length > 160) throw Error('invalid_select');
      const browser = createCamofoxBrowser({ baseUrl, userId: scope(ctx), accessKey });
      const payload = await browser.select(params.tabId, { ref: params.ref, option: params.option },
        { signal: AbortSignal.timeout(15_000) });
      return { content: [{ type: 'text', text: JSON.stringify({ ok: payload?.ok === true }) }] };
    },
  }), { name: 'camofox_select' });
}
