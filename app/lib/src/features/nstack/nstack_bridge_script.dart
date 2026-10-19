import 'dart:convert';

String nstackBridgeScript({
  required String documentId,
  required String pageOrigin,
}) {
  return '''
(() => {
  if (window !== window.top || location.origin !== ${jsonEncode(pageOrigin)}) return;
  const documentId = ${jsonEncode(documentId)};
  const pending = new Map();
  const listeners = new Set();
  let seq = 0;
  window.__nstackResolve = (id, payload) => {
    const request = pending.get(id);
    if (!request) return;
    pending.delete(id);
    if (payload && payload.error) {
      const error = new Error(String(payload.error.message || payload.error));
      error.code = String(payload.error.code || 'unavailable');
      request.reject(error);
    } else request.resolve(payload ? payload.result : undefined);
  };
  window.__nstackChange = (detail) => {
    const event = Object.freeze(detail || { reason: 'changed' });
    listeners.forEach((handler) => { try { handler(event); } catch (_) {} });
  };
  function call(method, params) {
    const id = `nstack-${r'$'}{++seq}`;
    const promise = new Promise((resolve, reject) => pending.set(id, {resolve, reject}));
    const timer = setTimeout(() => {
      const request = pending.get(id);
      if (!request) return;
      pending.delete(id);
      const error = new Error('NStack request expired or document was revoked.');
      error.code = 'stale_handle';
      request.reject(error);
    }, 30000);
    promise.then(() => clearTimeout(timer), () => clearTimeout(timer));
    WingmanSigner.postMessage(JSON.stringify({
      id, method: `nstack.${r'$'}{method}`, params: params || {}, documentId
    }));
    return promise;
  }
  Object.defineProperty(window, 'NStack', { configurable: true, value: Object.freeze({
    version: 1,
    isAvailable: () => Promise.resolve({ available: true, version: 1 }),
    requestDiscovery: (options) => call('requestDiscovery', options),
    listNStacks: () => call('listNStacks'),
    listWorkspaces: (options) => call('listWorkspaces', options),
    requestCapabilities: (options) => call('requestCapabilities', options),
    revoke: (options) => call('revoke', options),
    on: (name, handler) => {
      if (name !== 'change' || typeof handler !== 'function') {
        throw new TypeError('Only on("change", handler) is supported.');
      }
      listeners.add(handler);
      return () => listeners.delete(handler);
    },
  })});
})();
''';
}
