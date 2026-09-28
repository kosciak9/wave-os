import { createCamofoxBrowser } from './camofox.mjs';
import { executeBrowser } from './core.mjs';
import { createDecisionBridge } from './bridge.mjs';

/**
 * Integrate inside the trusted wrapper: scope(ctx) MUST return the existing HMAC-derived
 * Camofox userId, not ctx.agentId, sessionKey, or a caller supplied value.
 * decide is a configured local bridge; it does not receive credentials or backend config.
 */
export function registerBrowserExecutor(api, { scope, decide, baseUrl, accessKey, telemetry, maxSteps, timeoutMs, threshold, margin }) {
  if (typeof scope !== 'function' || typeof decide !== 'function') throw Error('scope_and_bridge_required');
  api.registerTool(ctx => ({
    name: 'browser_execute',
    description: 'Execute a bounded browser goal in an existing scoped Camofox tab; escalates when uncertain.',
    parameters: {
      type: 'object', additionalProperties: false,
      properties: {
        goal: { type: 'string' }, tabId: { type: 'string' },
        variables: { type: 'object', additionalProperties: { type: 'string' } },
        success: { type: 'object', additionalProperties: false, properties: { textIncludes: { type: 'string' }, urlPath: { type: 'string' } } },
        allowedOrigins: { type: 'array', items: { type: 'string' } },
        forbidActions: { type: 'array', items: { type: 'string' } },
      }, required: ['goal', 'tabId', 'variables'],
    },
    async execute(_id, params) {
      const userId = scope(ctx);
      const browser = createCamofoxBrowser({ baseUrl, userId, accessKey });
      const outcome = await executeBrowser(params, { browser, decide, telemetry, maxSteps, timeoutMs, threshold, margin });
      return { content: [{ type: 'text', text: JSON.stringify(outcome) }] };
    },
  }), { name: 'browser_execute' });
}

/** Trusted wrapper entry point. Executable and backend come from deployment config, never tool input. */
export function registerHybridBrowserExecutor(api, { executable, backend = 'kev', onMetric, ...options }) {
  const decide = createDecisionBridge({ executable, backend, onMetric });
  try {
    // The synthetic .2/.01 arm is not a calibrated production policy.
    registerBrowserExecutor(api, { ...options, decide, threshold: options.threshold ?? 0.5, margin: options.margin ?? 0.05 });
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
