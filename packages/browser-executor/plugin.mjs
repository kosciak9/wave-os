import { createCamofoxBrowser } from './camofox.mjs';
import { executeBrowser } from './core.mjs';
import { createDecisionBridge } from './bridge.mjs';

// Context has already passed the trusted actor guard in the wrapper. Only its
// scoped identity, not tool arguments, can select a browser namespace.
export function registerBrowserExecutor(api, { scope, decide, baseUrl, accessKey, observations, tabState }) {
  if (typeof scope !== 'function' || typeof decide !== 'function' || !observations || !tabState)
    throw Error('browser_runtime_required');
  const run = async (ctx, params) => {
    const browser = createCamofoxBrowser({ baseUrl, userId: scope(ctx), accessKey });
    const outcome = await executeBrowser(params, { browser, decide, observations, tabState,
      maxSteps: 64, timeoutMs: 120_000 });
    return { content: [{ type: 'text', text: JSON.stringify(outcome) }] };
  };
  api.registerTool(ctx => ({
    name: 'browser_execute',
    description: 'Start a bounded browser goal in an existing tab. If reasoning is needed, use browser_resolve with the returned continuation_id; never resend the start request.',
    parameters: {
      type: 'object', additionalProperties: false, required: ['goal', 'tabId', 'facts'],
      properties: {
        goal: { type: 'string', minLength: 1, maxLength: 360 },
        tabId: { type: 'string', pattern: '^[A-Za-z0-9_-]{1,128}$' },
        facts: { type: 'object', maxProperties: 32, propertyNames: { minLength: 1, maxLength: 100 },
          additionalProperties: { type: 'string', maxLength: 120 },
          description: 'Known values keyed by a canonical field name, for example the HTML name; do not key by a guess. Bindings may map a fact key to an exact observed label and context.' },
        constraints: { type: 'object', additionalProperties: false, properties: {
          forbidActions: { type: 'array', maxItems: 24, items: { type: 'string', minLength: 1, maxLength: 100 } },
          allowedOrigins: { type: 'array', maxItems: 8, items: { type: 'string' } },
        } },
        bindings: { type: 'object', maxProperties: 32, additionalProperties: {
          type: 'object', additionalProperties: false, required: ['label', 'context'], properties: {
            label: { type: 'string', minLength: 1, maxLength: 120 },
            context: { type: 'string', minLength: 1, maxLength: 200 },
          },
        } },
      },
    },
    execute: (_id, params) => run(ctx, params),
  }), { name: 'browser_execute' });
  api.registerTool(ctx => ({
    name: 'browser_resolve',
    description: 'Continue only a needs_reasoning handoff from browser_execute using exactly its continuation_id and a typed resolution: fact {type:"fact",key:problem.fact_key,value:exact observed option value or label}, choice {type:"choice",candidateId}, finish {type:"finish"}, or user_input {type:"user_input",question}. If a fact value is rejected while the continuation remains valid, use the same token with a corrected canonical key and exact observed option value or label; never invent, paraphrase, restart, or retry after an unknown mutation.',
    parameters: {
      type: 'object', additionalProperties: false, required: ['continuation_id', 'resolution'],
      properties: {
        continuation_id: { type: 'string', pattern: '^[A-Za-z0-9_-]{43}$',
          description: 'Opaque single-use continuation_id from the latest needs_reasoning result.' },
        resolution: { type: 'object', oneOf: [
          { additionalProperties: false, required: ['type', 'key', 'value'], properties: { type: { const: 'fact' },
            key: { type: 'string', minLength: 1, maxLength: 100 }, value: { type: 'string', minLength: 1, maxLength: 120 } },
          description: 'Use exactly problem.fact_key. Value must equal an observed options[].value or options[].label; never shorten or paraphrase an option.' },
          { additionalProperties: false, required: ['type', 'candidateId'], properties: { type: { const: 'choice' },
            candidateId: { type: 'string', pattern: '^[0-9a-f]{24}$' } },
          description: 'Example: {"type":"choice","candidateId":"<problem.candidates[].id>"} for a grounded observed control.' },
          { additionalProperties: false, required: ['type'], properties: { type: { const: 'finish' } },
            description: 'Example: {"type":"finish"} only if the observed full goal is finished.' },
          { additionalProperties: false, required: ['type', 'question'], properties: { type: { const: 'user_input' },
            question: { type: 'string', minLength: 1, maxLength: 180 } },
          description: 'Example: {"type":"user_input","question":"<business decision to ask the user>"}.' },
        ] },
      },
    },
    execute: (_id, params) => run(ctx, params),
  }), { name: 'browser_resolve' });
}

export function registerLocalBrowserExecutor(api, { executable, ...options }) {
  const bridge = createDecisionBridge({ executable });
  const decide = ({ state, choices }, context) => bridge({ state: {
    title: '', url: '', recent: [], pagesSeen: [], ...state,
  }, choices }, context);
  try { registerBrowserExecutor(api, { ...options, decide }); }
  catch (error) { bridge.close(); throw error; }
  return { close: bridge.close };
}

export function registerBrowserObservations(api, { observations }) {
  api.registerTool(() => ({
    name: 'browser_observations',
    description: 'Read bounded, value-free browser operation observations; no snapshots, URLs, facts or page contents.',
    parameters: { type: 'object', additionalProperties: false, properties: {
      after: { type: 'string', minLength: 1, maxLength: 128, pattern: '^[A-Za-z0-9_-]+$' },
      limit: { type: 'integer', minimum: 1, maximum: 50 },
    } },
    async execute(_id, params) {
      const after = params?.after;
      const limit = params?.limit ?? 20;
      if (after !== undefined && (typeof after !== 'string' || after.length > 128 || !/^[A-Za-z0-9_-]+$/.test(after)) ||
          !Number.isSafeInteger(limit) || limit < 1 || limit > 50)
        throw Error('invalid_observation_window');
      const result = await observations.read({ after, limit });
      return { content: [{ type: 'text', text: JSON.stringify(result) }] };
    },
  }), { name: 'browser_observations' });
}
