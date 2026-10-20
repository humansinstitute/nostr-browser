import 'dart:convert';

const nstackDocumentStartBootstrapScript = r'''
(() => {
  if (window !== window.top || window.__nstackBootstrapInstalled) return;
  const local = ['localhost', '127.0.0.1', '::1', 'wingman.local'].includes(location.hostname);
  if (location.protocol !== 'https:' && !(location.protocol === 'http:' && local)) return;
  Object.defineProperty(window, '__nstackBootstrapInstalled', { value: true });
  let resolveReady;
  const ready = new Promise((resolve) => { resolveReady = resolve; });
  const callWhenReady = (method, args) => ready.then((api) => api[method](...args));
  const rejectCapabilities = () => {
    const error = new Error('NStack capabilities are not supported; use connection discovery.');
    error.code = 'invalid_request';
    return Promise.reject(error);
  };
  const stub = Object.freeze({
    version: 1,
    ready,
    isAvailable: (...args) => callWhenReady('isAvailable', args),
    requestDiscovery: (...args) => callWhenReady('requestDiscovery', args),
    listNStacks: (...args) => callWhenReady('listNStacks', args),
    getServiceCatalogue: (...args) => callWhenReady('getServiceCatalogue', args),
    listWorkspaces: (...args) => callWhenReady('listWorkspaces', args),
    getConnection: (...args) => callWhenReady('getConnection', args),
    requestCapabilities: rejectCapabilities,
    revoke: (...args) => callWhenReady('revoke', args),
    on: (...args) => {
      let cancelled = false;
      let unsubscribe;
      ready.then((api) => {
        if (!cancelled) unsubscribe = api.on(...args);
      });
      return () => {
        cancelled = true;
        if (typeof unsubscribe === 'function') unsubscribe();
      };
    },
  });
  Object.defineProperty(window, 'NStackReady', { configurable: true, value: ready });
  Object.defineProperty(window, 'NStack', { configurable: true, value: stub });
  Object.defineProperty(window, '__nstackInstall', { configurable: true, value: (api) => {
    Object.defineProperty(window, 'NStack', { configurable: true, value: api });
    resolveReady(api);
    window.dispatchEvent(new CustomEvent('nstackready', { detail: { version: 1 } }));
  }});
})();
''';

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
  function rejectCapabilities() {
    const error = new Error('NStack capabilities are not supported; use connection discovery.');
    error.code = 'invalid_request';
    return Promise.reject(error);
  }
  const api = Object.freeze({
    version: 1,
    ready: Promise.resolve(),
    isAvailable: () => Promise.resolve({ available: true, version: 1 }),
    requestDiscovery: (options) => call('requestDiscovery', options),
    listNStacks: () => call('listNStacks'),
    getServiceCatalogue: (options) => call('getServiceCatalogue', options),
    listWorkspaces: (options) => call('listWorkspaces', options),
    getConnection: (options) => call('getConnection', options),
    requestCapabilities: rejectCapabilities,
    revoke: () => call('revoke'),
    on: (name, handler) => {
      if (name !== 'change' || typeof handler !== 'function') {
        throw new TypeError('Only on("change", handler) is supported.');
      }
      listeners.add(handler);
      return () => listeners.delete(handler);
    },
  });
  if (typeof window.__nstackInstall === 'function') window.__nstackInstall(api);
  else {
    Object.defineProperty(window, 'NStackReady', { configurable: true, value: Promise.resolve(api) });
    Object.defineProperty(window, 'NStack', { configurable: true, value: api });
    window.dispatchEvent(new CustomEvent('nstackready', { detail: { version: 1 } }));
  }
})();
''';
}
