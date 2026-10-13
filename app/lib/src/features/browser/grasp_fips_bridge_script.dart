import 'dart:convert';

/// The secret remains in a top-frame closure. Cross-origin frames can see the
/// platform channel but cannot authorize calls or receive its responses.
String graspFipsBridgeScript(String documentToken, String pageOrigin) => '''
(() => {
  if (window !== window.top || location.origin !== ${jsonEncode(pageOrigin)}) return;
  const token = ${jsonEncode(documentToken)};
  let seq = 0, revoked = false, generation = 0, towerHandle = null;
  const pairs = new Map();
  const sockets = new Set();
  const activeStreams = new Set();
  const pending = new Map();
  const workerPorts = new WeakMap();
  const portCleanups = new Set();
  const rpc = (method, params = {}) => new Promise((resolve, reject) => {
    if (revoked) { reject(new Error('GRASP grant revoked.')); return; }
    const id = String(++seq);
    const timer = (method === 'pull' || method === 'connect' || method === 'connectDrive' || method === 'saveBegin' || method === 'saveFinish' || method === 'wsNext') ? null : setTimeout(() => { pending.delete(id); reject(new Error('GRASP FIPS request timed out.')); }, 30000);
    pending.set(id, {resolve, reject, timer});
    WingmanGrasp.postMessage(JSON.stringify({token, id, method, params}));
  });
  window.__wingmanGraspReply = (secret, id, result, error) => {
    if (secret !== token) return;
    const p = pending.get(id);
    if (!p) return;
    pending.delete(id);
    clearTimeout(p.timer);
    if (error) p.reject(new Error(error)); else p.resolve(result);
  };
  window.__wingmanGraspRevoke = secret => {
    if (secret !== token) return;
    revoked = true; pairs.clear(); towerHandle = null; generation++;
    for (const socket of [...sockets]) socket._end(1006, '', false);
    for (const stop of [...activeStreams]) stop();
    for (const cleanup of [...portCleanups]) cleanup();
    for (const p of pending.values()) { clearTimeout(p.timer); p.reject(new Error('GRASP grant revoked.')); }
    pending.clear();
  };
  const encode = bytes => {
    let s = ''; for (const b of bytes) s += String.fromCharCode(b);
    return btoa(s);
  };
  const decode = s => Uint8Array.from(atob(s), c => c.charCodeAt(0));
  const nativeFetch = async (input, init = {}, selectedGrant = null) => {
    if (pairs.size===0) throw new Error('Connect to a service first.');
    const request = new Request(input, init);
    const approvedPair = selectedGrant
      ? pairs.get(selectedGrant)
      : [...pairs.values()].find(grant => request.url.startsWith(grant.endpoint + '/'));
    if (!approvedPair || !request.url.startsWith(approvedPair.endpoint + '/'))
      throw new Error('Request must target an approved FIPS service.');
    if (request.signal.aborted) throw request.signal.reason || new DOMException('Aborted', 'AbortError');
    const headers = Object.fromEntries(request.headers.entries());
    // Native transport must deliver compressed representation consistently.
    // A page cannot set accept-encoding; native backend handles decompression.
    const opening = rpc('open', {grantId:approvedPair.grantId,url: request.url, method: request.method, headers});
    let earlyAbort, id;
    const interrupted = new Promise((_, reject) => {
      earlyAbort = () => reject(request.signal.reason || new DOMException('Aborted', 'AbortError'));
      request.signal.addEventListener('abort', earlyAbort, {once:true});
      if (request.signal.aborted) earlyAbort();
    });
    try { id = await Promise.race([opening, interrupted]); }
    catch (e) {
      opening.then(requestId => rpc('cancel', {requestId})).catch(() => {});
      throw e;
    } finally { request.signal.removeEventListener('abort', earlyAbort); }
    let cancelled = false, responseController, uploadReader;
    const cancel = () => {
      if (cancelled) return;
      cancelled = true;
      activeStreams.delete(stop);
      rpc('cancel', {requestId: id}).catch(() => {});
      request.signal.removeEventListener('abort', abort);
    };
    const stop = () => { cancel(); responseController?.error(new Error('GRASP grant revoked.')); };
    activeStreams.add(stop);
    const abort = () => {
      cancel();
      uploadReader?.cancel().catch(() => {});
      if (responseController) responseController.error(request.signal.reason || new DOMException('Aborted', 'AbortError'));
    };
    request.signal.addEventListener('abort', abort, {once:true});
    if (request.signal.aborted) abort();
    try {
      if (request.body) {
        const reader = request.body.getReader();
        uploadReader = reader;
        try {
          while (true) {
            const {done, value} = await reader.read();
            if (done) break;
            for (let offset = 0; offset < value.length; offset += 65536) {
              if (cancelled) throw new DOMException('Aborted', 'AbortError');
              await rpc('write', {requestId:id, chunk:encode(value.subarray(offset, offset+65536))});
            }
          }
        } finally { await reader.cancel().catch(() => {}); uploadReader = null; }
      }
      if (cancelled) throw new DOMException('Aborted', 'AbortError');
      const meta = await rpc('finish', {requestId:id});
      if (cancelled) throw new DOMException('Aborted', 'AbortError');
      const empty = request.method === 'HEAD' || [204,205,304].includes(meta.status);
      const body = empty ? null : new ReadableStream({
        start(controller) { responseController = controller; },
        async pull(controller) {
          try {
            const next = await rpc('pull', {requestId:id});
            if (cancelled) return;
            if (next.done) {
              activeStreams.delete(stop);
              request.signal.removeEventListener('abort', abort);
              controller.close();
            } else controller.enqueue(decode(next.chunk));
          } catch (e) { if (!cancelled) { controller.error(e); cancel(); } }
        },
        cancel,
      }, {highWaterMark:0});
      if (empty) cancel();
      const response = new Response(body, meta);
      Object.defineProperty(response, 'url', {value:request.url});
      return response;
    } catch (e) { cancel(); if (request.signal.aborted) throw request.signal.reason || new DOMException('Aborted','AbortError'); throw e; }
  };
  class NativeWebSocket extends EventTarget {
    static CONNECTING=0; static OPEN=1; static CLOSING=2; static CLOSED=3;
    CONNECTING=0; OPEN=1; CLOSING=2; CLOSED=3;
    readyState=0; bufferedAmount=0; protocol=''; extensions=''; binaryType='blob';
    onopen=null; onmessage=null; onerror=null; onclose=null;
    _id=null; _queue=Promise.resolve();
    constructor(url, protocols=[], selectedGrant=null) {
      super();
      this.url = new URL(url).href;
      const approvedPair = selectedGrant
        ? pairs.get(selectedGrant)
        : [...pairs.values()].find(grant => this.url.startsWith(grant.endpoint.replace('http:', 'ws:')+'/'));
      if (!approvedPair) throw new DOMException('Unapproved relay', 'SecurityError');
      if ((typeof protocols==='string' && protocols) || (Array.isArray(protocols) && protocols.length)) throw new DOMException('Relay subprotocols unsupported', 'NotSupportedError');
      sockets.add(this);
      rpc('wsOpen',{grantId:approvedPair.grantId,url:this.url}).then(async id=> {
        this._id=id;
        if (this.readyState!==0 || revoked) { rpc('wsClose',{requestId:id}).catch(()=>{}); return; }
        this.readyState=1; this._emit(new Event('open'));
        while (this.readyState===1) {
          const next=await rpc('wsNext',{requestId:id});
          if (this.readyState!==1) return;
          if (next.done) { this._end(next.code,next.reason,next.code!==1006); return; }
          const bytes=next.text ? null : decode(next.data);
          const data=next.text ? next.data : this.binaryType==='arraybuffer' ? bytes.buffer : new Blob([bytes]);
          this._emit(new MessageEvent('message',{data,origin:this.url}));
        }
      }).catch(()=>{ if(this.readyState!==3) {this._emit(new Event('error'));this._end(1006,'',false);} });
    }
    _emit(event) {
      this.dispatchEvent(event);
      try { this['on'+event.type]?.call(this,event); } catch(e) { setTimeout(()=>{throw e;}); }
    }
    _end(code,reason,wasClean) {
      if (this.readyState===3) return;
      this.readyState=3; sockets.delete(this);
      if(this._id) rpc('wsClose',{requestId:this._id}).catch(()=>{});
      this._emit(new CloseEvent('close',{code,reason,wasClean}));
    }
    send(data) {
      if (this.readyState===0) throw new DOMException('Relay connecting','InvalidStateError');
      if (this.readyState!==1) return;
      const text=typeof data==='string';
      if(!text && !(data instanceof Blob) && !(data instanceof ArrayBuffer) && !ArrayBuffer.isView(data)) data=String(data);
      const isText=typeof data==='string';
      // Snapshot caller-owned buffers immediately, preserving send ordering.
      const snapshot=isText || data instanceof Blob ? data : new Uint8Array(data instanceof ArrayBuffer ? data : new Uint8Array(data.buffer,data.byteOffset,data.byteLength)).slice();
      const size=isText?new TextEncoder().encode(snapshot).length:snapshot.size??snapshot.byteLength;
      if(size>1048576 || this.bufferedAmount+size>4194304) throw new DOMException('Relay queue limit','QuotaExceededError');
      this.bufferedAmount+=size;
      this._queue=this._queue.then(async()=>{
        if(this.readyState===3) return;
        const encoded=isText?snapshot:encode(snapshot instanceof Blob?new Uint8Array(await snapshot.arrayBuffer()):snapshot);
        await rpc('wsSend',{requestId:this._id,text:isText,data:encoded});
      }).catch(()=>{this._emit(new Event('error'));this._end(1006,'',false);}).finally(()=>{this.bufferedAmount-=size;});
    }
    close(code=1000, reason='') {
      if(code!==1000 && (code<3000 || code>4999)) throw new DOMException('Invalid close code','InvalidAccessError');
      if(new TextEncoder().encode(reason).length>123) throw new DOMException('Close reason too long','SyntaxError');
      if(this.readyState>=2)return;
      this.readyState=2;
      this._queue.then(()=>this._id?rpc('wsClose',{requestId:this._id,code,reason}):null)
        .then(()=>this._end(code,reason,false),()=>this._end(1006,'',false));
    }
  }
  const makeHandle = result => {
    const handle = {
      version:2, grantId:result.grantId, endpoint:result.endpoint,
      peerNpub:result.peerNpub, purpose:result.purpose,
      fetch:(input,init)=>nativeFetch(input,init,result.grantId),
      WebSocket:class extends NativeWebSocket { constructor(url,protocols=[]) { super(url,protocols,result.grantId); } },
      disconnect:()=>transport.disconnect(result.grantId),
    };
    return Object.freeze(handle);
  };
  const transport = Object.freeze({
    version:2, available:true,
    capabilities:Object.freeze({multiEndpoint:true, connect:true, connectDrive:true, fetch:true, save:true, WebSocket:true, workers:true, streaming:true}),
    async connectDrive(options) { return this.connect({...options,purpose:'drive'}, 'connectDrive'); },
    async save(response, {name, signal, onProgress, open=false}={}) {
      let id, reader, done=false, total=0;
      const abort=()=>{reader?.cancel().catch(()=>{});if(id)rpc('saveCancel',{saveId:id}).catch(()=>{});};
      try {
        if(signal?.aborted)throw new DOMException('Aborted','AbortError');
        const opening=rpc('saveBegin',{name});
        let cancelOpening;
        const interrupted=new Promise((_,reject)=>{cancelOpening=()=>reject(new DOMException('Aborted','AbortError'));signal?.addEventListener('abort',cancelOpening,{once:true});});
        try { id=await Promise.race([opening,interrupted]); }
        catch(error){opening.then(saveId=>rpc('saveCancel',{saveId})).catch(()=>{});throw error;}
        finally{signal?.removeEventListener('abort',cancelOpening);}
        if(signal?.aborted)throw new DOMException('Aborted','AbortError');
        signal?.addEventListener('abort',abort,{once:true}); reader=response.body.getReader();
        while(true){if(signal?.aborted)throw new DOMException('Aborted','AbortError');const chunk=await reader.read();if(chunk.done)break;
          for(let n=0;n<chunk.value.length;n+=65536){await rpc('saveWrite',{saveId:id,chunk:encode(chunk.value.subarray(n,n+65536))});total+=Math.min(65536,chunk.value.length-n);onProgress?.(total);}}
        if(signal?.aborted)throw new DOMException('Aborted','AbortError');
        const expected=response.headers.get('content-length');if(expected!==null&&total!==Number(expected))throw new Error('Changed or interrupted file');
        const result=await rpc('saveFinish',{saveId:id,open});if(signal?.aborted&&!result?.committed)throw new DOMException('Cancelled','AbortError');done=true;return result||{saved:true};
      }finally{signal?.removeEventListener('abort',abort);await reader?.cancel().catch(()=>{});if(!reader)await response.body?.cancel().catch(()=>{});if(!done&&id)await rpc('saveCancel',{saveId:id}).catch(()=>{});}
    },
    async connect(options, method='connect') {
      const current = generation;
      const result = await rpc(method, options);
      if (revoked || current !== generation) throw new Error('Connection revoked.');
      const handle=makeHandle(result);pairs.set(result.grantId,handle);return handle;
    },
    fetch:nativeFetch,
    WebSocket:NativeWebSocket,
    detachWorker(worker) { workerPorts.get(worker)?.(); workerPorts.delete(worker); },
    attachWorker(worker, messageType='wingman-fips-transport-port') {
      workerPorts.get(worker)?.();
      const channel = new MessageChannel();
      const requests = new Map();
      const cleanup = (close = true) => {
        for (const [id,state] of requests) {
          state.abort.abort(); channel.port1.postMessage({type:'error',id});
        }
        requests.clear();
        if (close) { channel.port1.close(); portCleanups.delete(cleanup); }
      };
      workerPorts.set(worker,cleanup); portCleanups.add(cleanup);
      const send = value => channel.port1.postMessage(value);
      channel.port1.onmessage = async ({data}) => {
        const id = data?.id;
        if (typeof id !== 'string') return;
        try {
          if (data.type === 'request') {
            if (data.bodyBase64 != null && (typeof data.bodyBase64 !== 'string' || data.bodyBase64.length > 22369624)) throw new Error('Worker upload exceeds 16 MiB');
            if (requests.has(id) || requests.size >= 64) throw new Error('Duplicate or excessive request');
            const state = {abort:new AbortController(), reader:null, busy:false};
            requests.set(id,state);
            const body = data.bodyBase64 == null ? undefined : decode(data.bodyBase64);
            if (body && body.byteLength > 16777216) throw new Error('Worker upload exceeds 16 MiB');
            const response = await nativeFetch(data.url, {
              method:data.method, headers:data.headers,
              body,
              signal:state.abort.signal,
            });
            if (requests.get(id) !== state) { await response.body?.cancel(); return; }
            state.reader = response.body?.getReader();
            send({type:'headers',id,status:response.status,headers:[...response.headers]});
          } else if (data.type === 'cancel') {
            const state = requests.get(id); requests.delete(id);
            state?.abort.abort(); await state?.reader?.cancel().catch(()=>{});
          } else if (data.type === 'pull') {
            const state = requests.get(id);
            if (!state || state.busy) return;
            state.busy = true;
            const next = await state.reader?.read() || {done:true};
            state.busy = false;
            if (requests.get(id) !== state) return;
            if (next.done) { requests.delete(id); send({type:'end',id}); }
            else send({type:'chunk',id,bodyBase64:encode(next.value)});
          }
        } catch (_) {
          const state = requests.get(id); requests.delete(id);
          state?.abort.abort(); send({type:'error',id});
        }
      };
      channel.port1.start();
      worker.postMessage({type:messageType,port:channel.port2},[channel.port2]);
    },
    async disconnect(handleOrId) {
      const grantId=typeof handleOrId==='string'?handleOrId:handleOrId?.grantId;
      if(grantId){pairs.delete(grantId);if(towerHandle?.grantId===grantId)towerHandle=null;await rpc('disconnect',{grantId});return;}
      pairs.clear();towerHandle=null;generation++;for(const socket of [...sockets])socket._end(1006,'',false);for(const stop of [...activeStreams])stop();for(const cleanup of [...portCleanups])cleanup(false);await rpc('disconnect');
    },
  });
  Object.defineProperty(window, 'fipsTransport', {configurable:true, value:transport});
  // Compatibility only. Remove after Flight Deck no longer references it.
  Object.defineProperty(window,'wingmanTowerTransport',{configurable:true,value:Object.freeze({
    version:2,available:true,pairingIdentity:'service-npub',
    async connect(options){
      if(!options?.serviceNpub)throw new Error('A Tower transport identity is required.');
      towerHandle=await transport.connect({...options,peerNpub:options.serviceNpub,purpose:'tower'});
      return {version:2,endpoint:towerHandle.endpoint,serviceNpub:options.serviceNpub,transport:'native'};
    },
    fetch:(input,init)=>{if(!towerHandle)throw new Error('Connect first.');return towerHandle.fetch(input,init);},
    attachWorker:(worker)=>transport.attachWorker(worker,'wingman-tower-transport-port'),
    detachWorker:transport.detachWorker,
    async disconnect(){if(towerHandle)await transport.disconnect(towerHandle);towerHandle=null;}
  })});
  window.dispatchEvent(new Event('wingman-fips-transport-ready'));
  window.dispatchEvent(new Event('wingman-grasp-transport-ready'));
  window.dispatchEvent(new Event('wingman-tower-transport-ready'));
})();
''';
