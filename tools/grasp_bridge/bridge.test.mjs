import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import test from 'node:test';

// Execute the production injected script with a synthetic native RPC channel.
const source = readFileSync(new URL('../../app/lib/src/features/browser/grasp_fips_bridge_script.dart', import.meta.url), 'utf8')
  .split("=> '''\n")[1].split("\n''';")[0]
  .replace('${jsonEncode(pageOrigin)}', JSON.stringify('https://example.com'))
  .replace('${jsonEncode(documentToken)}', JSON.stringify('test-token'));
function host({ frame = false, origin = 'https://example.com', timer = setTimeout } = {}) {
  const window = new EventTarget();
  window.top = frame ? {} : window;
  window.nostr = { signEvent() { throw Error('Unexpected signing'); } };
  const calls = [];
  const endpoint = 'http://synthetic.fips:8787';
  let downloaded = false;
  const context = {
    window, location: { origin }, EventTarget, Event, MessageEvent,
    Request, Response, ReadableStream, AbortController, DOMException,
    Blob, URL, TextEncoder, Uint8Array, ArrayBuffer, MessageChannel,
    setTimeout: timer, clearTimeout, atob, btoa,
    WingmanGrasp: { postMessage(message) {
      const call = JSON.parse(message); calls.push(call);
      let result;
      if (call.method === 'connect') result = { version: 2, grantId: `grant-${call.id}`, endpoint:call.params.endpoint, peerNpub:'synthetic', purpose:call.params.purpose||'service' };
      if (call.method === 'open') result = 'request';
      if (call.method === 'finish') result = { status: 201, headers: { 'Content-Type': 'application/octet-stream' } };
      if (call.method === 'pull') {
        result = downloaded ? { done: true } : { done: false, chunk: btoa('\x00\xff\x0d') };
        downloaded = true;
      }
      queueMicrotask(() => window.__wingmanGraspReply('test-token', call.id, result));
    } },
  };
  return { window, calls, endpoint, run: () => runInNewContext(source, context) };
}

test('FIPS capability preserves readiness, binary transport, revocation and separate signing', async () => {
  const h = host(); const signer = h.window.nostr;
  let ready = 0;
  h.window.addEventListener('wingman-fips-transport-ready', () => {
    ready++;
    assert.ok(Object.isFrozen(h.window.fipsTransport));
  });
  h.run();
  assert.equal(ready, 1); assert.equal(h.window.nostr, signer);
  await h.window.fipsTransport.connect({ endpoint: h.endpoint });
  const response = await h.window.fipsTransport.fetch(h.endpoint + '/echo', {
    method: 'POST', body: new Uint8Array([0, 255, 13]),
  });
  assert.equal(response.status, 201);
  assert.deepEqual([...new Uint8Array(await response.arrayBuffer())], [0, 255, 13]);
  assert.equal(h.calls.find(c => c.method === 'write').params.chunk, 'AP8N');
  await h.window.fipsTransport.disconnect();
  await assert.rejects(h.window.fipsTransport.fetch(h.endpoint + '/'), /Connect/);
  await h.window.fipsTransport.connect({ endpoint: h.endpoint });
  h.window.__wingmanGraspRevoke('test-token');
  await assert.rejects(h.window.fipsTransport.connect({ endpoint: h.endpoint }), /revoked/);
});

for (const options of [{ frame: true }, { origin: 'https://other.example' }]) {
  test(`does not install capability outside approved top origin: ${JSON.stringify(options)}`, () => {
    const h = host(options); h.run();
    assert.equal(h.window.fipsTransport, undefined);
    assert.equal(h.calls.length, 0);
  });
}

test('Drive multiple host grants coexist with Git and revoke together', async () => {
  const h=host(); h.run(); const t=h.window.fipsTransport;
  // Synthetic host replies for connectDrive must echo its requested endpoint.
  const original=h.window.__wingmanGraspReply;
  h.window.__wingmanGraspReply=(secret,id,result,error)=>{
    const call=h.calls.find(c=>c.id===id);
    return original(secret,id,call?.method==='connectDrive'?{version:2,grantId:`grant-${id}`,endpoint:call.params.endpoint,peerNpub:'synthetic',purpose:'drive'}:result,error);
  };
  await t.connect({endpoint:h.endpoint});
  await t.connectDrive({endpoint:'http://first.fips:7345'});
  await t.connectDrive({endpoint:'http://second.fips:7345'});
  for(const endpoint of ['http://first.fips:7345','http://second.fips:7345',h.endpoint]){
    const response=await t.fetch(endpoint+'/drive/v1/share/list');await response.body.cancel();
  }
  await assert.rejects(t.fetch('http://unapproved.fips:7345/drive/v1/share/list'),/approved/);
  h.window.__wingmanGraspRevoke('test-token');
  await assert.rejects(t.fetch('http://first.fips:7345/drive/v1/share/list'),/Connect|revoked/);
});

test('Flight Deck session/Agents and GitWorkshop use independent Autopilot/GRASP handles', async () => {
  const h=host();h.run();const t=h.window.fipsTransport;
  const original=h.window.__wingmanGraspReply;
  h.window.__wingmanGraspReply=(secret,id,result,error)=>{
    const call=h.calls.find(c=>c.id===id);
    if(call?.method==='connect') result={version:2,grantId:`grant-${id}`,endpoint:call.params.endpoint,peerNpub:'synthetic',purpose:call.params.purpose||'service'};
    return original(secret,id,result,error);
  };
  const first=await t.connect({endpoint:h.endpoint,purpose:'tower'});
  const secondEndpoint='http://second.fips:7345';
  const second=await t.connect({endpoint:secondEndpoint,purpose:'autopilot'});
  const gitEndpoint='http://git.fips:9418';
  const git=await t.connect({endpoint:gitEndpoint,purpose:'git'});
  assert.notEqual(first.grantId,second.grantId);
  assert.notEqual(second.grantId,git.grantId);
  assert.equal(Object.isFrozen(first),true);
  await (await first.fetch(h.endpoint+'/events')).body.cancel();
  await (await second.fetch(secondEndpoint+'/sessions/live-thinking')).body.cancel();
  await (await second.fetch(secondEndpoint+'/pipelines')).body.cancel();
  await (await git.fetch(gitEndpoint+'/owner/repository.git/info/refs')).body.cancel();
  assert.deepEqual(h.calls.filter(c=>c.method==='connect').map(c=>c.params.purpose),['tower','autopilot','git']);
  await first.disconnect();
  await assert.rejects(first.fetch(h.endpoint+'/events'),/approved/);
  await (await second.fetch(secondEndpoint+'/sessions')).body.cancel();
  await (await git.fetch(gitEndpoint+'/owner/repository.git/git-upload-pack')).body.cancel();
});

test('legacy Tower surface delegates connect, fetch and disconnect to fipsTransport', async () => {
  const h=host();h.run();
  const tower=h.window.wingmanTowerTransport;
  assert.equal(tower.available,true);
  await tower.connect({endpoint:h.endpoint,serviceNpub:'synthetic'});
  await (await tower.fetch(h.endpoint+'/api')).body.cancel();
  assert.equal(h.calls.find(c=>c.method==='connect').params.purpose,'tower');
  assert.equal(h.calls.find(c=>c.method==='connect').params.peerNpub,'synthetic');
  let workerMessage;
  const worker={postMessage:(message)=>{workerMessage=message;}};
  tower.attachWorker(worker);
  assert.equal(workerMessage.type,'wingman-tower-transport-port');
  tower.detachWorker(worker);
  await tower.disconnect();
  await assert.rejects(Promise.resolve().then(()=>tower.fetch(h.endpoint+'/api')),/Connect/);
});

test('native save splits a large response into bounded chunks and cancels partial output', async () => {
  const h=host();h.run();const t=h.window.fipsTransport;
  const original=h.window.__wingmanGraspReply;
  h.window.__wingmanGraspReply=(secret,id,result,error)=>{const c=h.calls.find(c=>c.id===id);return original(secret,id,c?.method==='saveBegin'?'save-id':result,error);};
  let progress=0;
  await t.save(new Response(new Uint8Array(4*1024*1024),{headers:{'content-length':String(4*1024*1024)}}),{name:'large.bin',onProgress:n=>{progress=n;}});
  assert.equal(progress,4*1024*1024);
  assert.equal(h.calls.filter(c=>c.method==='saveWrite').length,64);
  assert.ok(h.calls.filter(c=>c.method==='saveWrite').every(c=>atob(c.params.chunk).length<=65536));
  const controller=new AbortController();
  await assert.rejects(t.save(new Response(new Uint8Array(256*1024)),{name:'cancel.bin',signal:controller.signal,onProgress:()=>controller.abort()}));
  assert.ok(h.calls.some(c=>c.method==='saveCancel'));
});

test('abort while native finalization reply is pending rejects save completion', async () => {
  const h=host(); h.run(); const controller=new AbortController();
  const original=h.window.__wingmanGraspReply;
  h.window.__wingmanGraspReply=(secret,id,result,error)=>{
    const call=h.calls.find(c=>c.id===id);
    if(call?.method==='saveFinish') controller.abort();
    return original(secret,id,call?.method==='saveBegin'?'pending-save':result,error);
  };
  await assert.rejects(h.window.fipsTransport.save(new Response('data'),{
    name:'file.txt',signal:controller.signal
  }),{name:'AbortError'});
  assert.ok(h.calls.some(c=>c.method==='saveCancel'));
});

test('late abort preserves a native committed save and export outcome', async () => {
  const h=host(); h.run(); const controller=new AbortController();
  const original=h.window.__wingmanGraspReply;
  h.window.__wingmanGraspReply=(secret,id,result,error)=>{
    const call=h.calls.find(c=>c.id===id);
    if(call?.method==='saveFinish') {
      controller.abort(); result={saved:true,committed:true,exportCompleted:false};
    }
    return original(secret,id,call?.method==='saveBegin'?'committed-save':result,error);
  };
  const result=await h.window.fipsTransport.save(new Response('data'),{name:'file',signal:controller.signal});
  assert.equal(result.saved,true); assert.equal(result.committed,true); assert.equal(result.exportCompleted,false);
});


test('save picker and export wait for the user without RPC deadlines', async () => {
  const deadlines=[];
  const h=host({timer:(fn,ms)=>{deadlines.push(ms);return setTimeout(fn,ms);}});h.run();
  const original=h.window.__wingmanGraspReply;
  h.window.__wingmanGraspReply=(secret,id,result,error)=>{
    const call=h.calls.find(c=>c.id===id);
    return original(secret,id,call?.method==='saveBegin'?'save-id':result,error);
  };
  await h.window.fipsTransport.save(new Response(new Uint8Array(0)),{name:'empty.txt'});
  assert.deepEqual(deadlines,[]);
});

test('cancel during save picker promptly aborts and cleans a late native destination', async () => {
  const h=host();h.run();const controller=new AbortController();let pendingReply;
  const original=h.window.__wingmanGraspReply;
  h.window.__wingmanGraspReply=(secret,id,result,error)=>{
    if(h.calls.find(c=>c.id===id)?.method==='saveBegin') {pendingReply=()=>original(secret,id,'late-save',error);return;}
    return original(secret,id,result,error);
  };
  let cancelled=false;
  const response=new Response(new ReadableStream({cancel(){cancelled=true;}}));
  const saving=h.window.fipsTransport.save(response,{name:'file.txt',signal:controller.signal});
  await new Promise(resolve=>setImmediate(resolve));controller.abort();
  await assert.rejects(saving,{name:'AbortError'});
  assert.equal(cancelled,true);
  pendingReply();await new Promise(resolve=>setImmediate(resolve));
  assert.ok(h.calls.some(c=>c.method==='saveCancel'&&c.params.saveId==='late-save'));
  assert.equal(h.calls.some(c=>c.method==='saveWrite'||c.method==='saveFinish'),false);
});
