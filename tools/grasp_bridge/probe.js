// Supply globalThis.graspProbe={endpoint,repositoryRoot?,fixture} before this file.
(async()=>{
  const assert=(ok,label)=>{if(!ok)throw Error(label);};
  const {endpoint,repositoryRoot,fixture}=globalThis.graspProbe;
  const transport=window.fipsTransport;
  assert(transport && Object.isFrozen(transport),'frozen FIPS capability');
  try {
    assert(location.protocol==='https:' && isSecureContext,'HTTPS context');
    const iframe=document.createElement('iframe');
    iframe.srcdoc='<script>window.webkit.messageHandlers.WingmanGrasp.postMessage("forged-frame")<\/script>';
    document.body.append(iframe);
    await new Promise(r=>setTimeout(r,200));
    iframe.contentWindow.webkit.messageHandlers.WingmanGrasp.postMessage('forged-frame-object');
    const csp=[];
    document.addEventListener('securitypolicyviolation',e=>csp.push({directive:e.effectiveDirective,blockedURI:e.blockedURI}));
    if(!fixture) {
      let blockedHTTP=false;
      try{await fetch(endpoint+'/',{signal:AbortSignal.timeout(2000)});}catch(_){blockedHTTP=true;}
      assert(blockedHTTP,'stock HTTP blocked');
      try {
        const stock=new WebSocket(endpoint.replace('http:','ws:')+'/');
        await new Promise(resolve=>{stock.onerror=resolve;stock.onopen=()=>{stock.close();resolve();};setTimeout(resolve,500);});
      } catch(_) {}
      await new Promise(r=>setTimeout(r,100));
      assert(csp.some(e=>e.directive==='connect-src' && e.blockedURI.startsWith('http:')),'actual HTTP CSP gate');
      assert(csp.some(e=>e.directive==='connect-src' && e.blockedURI.startsWith('ws:')),'actual WS CSP gate');
    }
    await transport.connect({endpoint});
    let forbidden=false;
    try{await transport.fetch(endpoint.replace(/:\d+$/,':1')+'/');}catch(_){forbidden=true;}
    assert(forbidden,'other port rejected');
    const info=await transport.fetch(endpoint+'/',{headers:{Accept:'application/nostr+json'}});
    assert(info.status===200,'NIP11 status');
    assert((await info.json()).supported_grasps.includes('GRASP-08'),'GRASP08');
    const relay=new transport.WebSocket(endpoint.replace('http:','ws:')+'/');
    const challenge=await new Promise((resolve,reject)=>{
      relay.onmessage=({data})=>{const f=JSON.parse(data);if(f[0]==='AUTH')resolve(f[1]);};
      relay.onerror=()=>reject(Error('relay error'));
    });
    assert(typeof challenge==='string' && challenge.length>0,'actual NIP42 challenge');
    if(fixture) {
      const echo=new Promise(resolve=>relay.onmessage=({data})=>resolve(data));
      relay.send('fixture echo');assert(await echo==='fixture echo','relay text echo');
      relay.binaryType='arraybuffer';
      const binary=new Promise(resolve=>relay.onmessage=({data})=>resolve(new Uint8Array(data)));
      relay.send(new Uint8Array([0,255,13]));assert((await binary).join(',')==='0,255,13','relay binary');
      const bytes=Uint8Array.from({length:180000},(_,i)=>i%256);
      const response=await transport.fetch(endpoint+'/echo',{method:'POST',body:bytes,headers:{'Content-Type':'application/x-git-upload-pack-request'}});
      assert(response.status===201,'HTTP status');
      const received=new Uint8Array(await response.arrayBuffer());
      assert(received.length===bytes.length && received.every((b,i)=>b===bytes[i]),'binary HTTP');
      let redirected=false;try{await transport.fetch(endpoint+'/redirect');}catch(_){redirected=true;}assert(redirected,'redirect rejection');
      const abort=new AbortController();const hanging=transport.fetch(endpoint+'/hang',{signal:abort.signal});
      setTimeout(()=>abort.abort(),50);let aborted=false;try{await hanging;}catch(e){aborted=e.name==='AbortError';}assert(aborted,'preheaders cancellation');
    } else {
      const root=await transport.fetch(repositoryRoot);
      assert(root.status===401 && root.headers.get('www-authenticate')?.includes('Nostr'),'private root challenge');await root.body?.cancel();
      const refs=await transport.fetch(repositoryRoot+'/info/refs?service=git-upload-pack');
      assert(refs.status===401,'anonymous Git stays private');await refs.body?.cancel();
    }
    const closed=new Promise(resolve=>relay.onclose=resolve);
    await transport.disconnect();await closed;
    let revoked=false;try{await transport.fetch(endpoint+'/');}catch(_){revoked=true;}assert(revoked,'revocation');
    window.webkit.messageHandlers.Result.postMessage('PASS '+JSON.stringify({origin:location.origin,fixture,nip11:true,nip42Challenge:true,binaryFixture:fixture,anonymousPrivate:!fixture,otherPortRejected:true,disconnect:true,memberUX:false,csp}));
  }catch(e){window.webkit.messageHandlers.Result.postMessage('FAIL '+e.name+': '+e.message);}
})();
