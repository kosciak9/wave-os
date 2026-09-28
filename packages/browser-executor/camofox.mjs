/** Trusted local Camofox transport. Never accepts paths, URLs, selectors or userId from model/tool parameters. */
export function createCamofoxBrowser({ baseUrl = 'http://127.0.0.1:9377', userId, accessKey, fetchImpl = fetch }) {
  const base = new URL(baseUrl);
  if (base.protocol !== 'http:' || base.hostname !== '127.0.0.1' || base.username || base.password || base.pathname !== '/' || base.search || base.hash ||
      typeof userId !== 'string' || !userId || typeof accessKey !== 'string' || !accessKey) throw Error('invalid_backend_configuration');
  const scopeId = `${base.origin}:${userId}`;
  async function call(tabId, operation, body, signal) {
    if (!/^[\w-]{1,128}$/.test(tabId)) throw Error('invalid_tab');
    const path = `/tabs/${encodeURIComponent(tabId)}/${operation}`;
    const url = new URL(path, base);
    if (!body) url.search = new URLSearchParams({ userId, includeScreenshot: 'false' }).toString();
    const response = await fetchImpl(url, {
      method: body ? 'POST' : 'GET', redirect: 'error', signal,
      headers: { Authorization: `Bearer ${accessKey}`, ...(body && { 'content-type': 'application/json' }) },
      ...(body && { body: JSON.stringify({ userId, ...body }) }),
    });
    if (!response.ok) throw Error('backend_unavailable');
    const length = Number(response.headers.get('content-length'));
    if (length > 250_000) { await response.body?.cancel(); throw Error('response_too_large'); }
    let text = '', bytes = 0;
    const decoder = new TextDecoder();
    for await (const chunk of response.body) {
      bytes += chunk.byteLength;
      if (bytes > 250_000) throw Error('response_too_large');
      text += decoder.decode(chunk, { stream: true });
    }
    text += decoder.decode();
    return JSON.parse(text);
  }
  return {
    scopeId,
    snapshot: (tabId, { signal } = {}) => call(tabId, 'snapshot', null, signal),
    click: (tabId, { ref }, { signal } = {}) => call(tabId, 'click', { ref }, signal),
    type: (tabId, { ref, text }, { signal } = {}) => call(tabId, 'type', { ref, text, pressEnter: false }, signal),
    select: (tabId, { ref, option }, { signal } = {}) => call(tabId, 'select', { ref, option }, signal),
    scroll: (tabId, { direction, amount }, { signal } = {}) => call(tabId, 'scroll', { direction, amount }, signal),
  };
}
