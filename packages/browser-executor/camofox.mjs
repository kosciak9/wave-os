/** Trusted local transport: URLs, selectors, credentials and userId never come from model decisions. */
export function createCamofoxBrowser({ baseUrl = 'http://127.0.0.1:9377', userId, accessKey, fetchImpl = fetch }) {
  const base = new URL(baseUrl);
  if (base.protocol !== 'http:' || base.hostname !== '127.0.0.1' || base.username || base.password ||
      base.pathname !== '/' || base.search || base.hash || typeof userId !== 'string' || !userId ||
      typeof accessKey !== 'string' || !accessKey) throw Error('invalid_backend_configuration');
  const scopeId = `${base.origin}:${userId}`;
  async function call(tabId, operation, body, signal) {
    if (!/^[\w-]{1,128}$/.test(tabId)) throw Error('invalid_tab');
    const url = new URL(`/tabs/${encodeURIComponent(tabId)}/${operation}`, base);
    if (!body) url.search = new URLSearchParams({ userId, includeScreenshot: 'false' }).toString();
    let response;
    try {
      response = await fetchImpl(url, { method: body ? 'POST' : 'GET', redirect: 'error', signal,
        headers: { Authorization: `Bearer ${accessKey}`, ...(body && { 'content-type': 'application/json' }) },
        ...(body && { body: JSON.stringify({ userId, ...body }) }) });
    } catch {
      const error = Error('backend_unavailable');
      error.mutationOutcome = body ? 'unknown' : 'not_dispatched';
      throw error;
    }
    const length = Number(response.headers.get('content-length'));
    if (length > 250_000) { await response.body?.cancel(); throw Error('response_too_large'); }
    let text = '', bytes = 0;
    const decoder = new TextDecoder();
    try {
      for await (const chunk of response.body ?? []) {
        bytes += chunk.byteLength;
        if (bytes > 250_000) throw Error('response_too_large');
        text += decoder.decode(chunk, { stream: true });
      }
      text += decoder.decode();
    } catch (error) {
      if (body) error.mutationOutcome = 'unknown';
      throw error;
    }
    let parsed;
    try { parsed = JSON.parse(text); } catch {
      const error = Error('invalid_backend_response'); error.mutationOutcome = body ? 'unknown' : 'not_dispatched'; throw error;
    }
    const uncertain = ['unknown', 'mutation_outcome_unknown', 'page_changed_after_dispatch'].includes(parsed?.outcome);
    if (!response.ok || parsed?.error || body && (parsed === null || typeof parsed !== 'object' ||
        Array.isArray(parsed) || parsed.ok !== true) || parsed?.outcome === 'not_dispatched' || uncertain) {
      const error = Error('backend_rejected_action');
      // Only trusted structured dispatch acknowledgments can prove a mutation was not dispatched.
      error.mutationOutcome = body && !uncertain && parsed?.outcome !== 'dispatched' &&
        (parsed?.dispatched === false || parsed?.outcome === 'not_dispatched' && parsed?.dispatched !== true) ?
        'not_dispatched' : 'unknown';
      throw error;
    }
    return parsed;
  }
  return { scopeId,
    snapshot: (tabId, { signal } = {}) => call(tabId, 'snapshot', null, signal),
    click: (tabId, { ref }, { signal } = {}) => call(tabId, 'click', { ref }, signal),
    type: (tabId, { ref, text }, { signal } = {}) => call(tabId, 'type', { ref, text, pressEnter: false }, signal),
    select: (tabId, { ref, option }, { signal } = {}) => call(tabId, 'select', { ref, option }, signal),
  };
}
