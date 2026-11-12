import {test,expect} from 'bun:test';
import {requireLegacyClaim,queryCertificateClaims,assertLegacyPublisherAllowed} from './certificate-owner-guard';
const {finalizeEvent,getPublicKey,verifyEvent}=await import((process.env.AUTOPILOT_REPO??'/Users/mini/code/wm/autopilot')+'/node_modules/nostr-tools/lib/esm/index.js');
const key=new Uint8Array(32);key[31]=11;const other=new Uint8Array(32);other[31]=12;
const publisher=getPublicKey(key),cert='a'.repeat(64),now=Math.floor(Date.now()/1000);
const claim=(k=key,tags=[['d',cert],['signature','public-app-key-proof'],['expiry',String(now+1000)]])=>finalizeEvent({kind:30509,created_at:now-1,content:'',tags},k);
test('only one expected signed claim permits legacy publishing; foreign claims hold even if old events were retained',async()=>{
 const prior=claim();expect(requireLegacyClaim([prior],cert,publisher,verifyEvent).claim).toBe(prior.id);
 for(const claims of [[],[prior,claim(other)],[claim(other)],[{...prior,sig:''}],[claim(key,[['d',cert],['signature','proof'],['expiry',String(now-1)]])],[claim(key,[['d',cert],['signature','proof'],['revoked','1']])]])expect(()=>requireLegacyClaim(claims as any,cert,publisher,verifyEvent)).toThrow('held');
 let queried=0;await expect(assertLegacyPublisherAllowed(cert,publisher,verifyEvent,async()=>{queried++;return [prior,claim(other)];})).rejects.toThrow('held');expect(queried).toBe(1);
});
test('incomplete, malformed and ambiguous claim snapshots never authorize',()=>{
 const prior=claim();expect(()=>requireLegacyClaim(Array.from({length:500},()=>prior),cert,publisher,verifyEvent)).toThrow('held');
 const newer=finalizeEvent({kind:30509,created_at:now,content:'',tags:prior.tags},key);
 expect(()=>requireLegacyClaim([prior,newer],cert,publisher,verifyEvent)).toThrow('held');
 expect(()=>requireLegacyClaim([claim(key,[['d','b'.repeat(64)],['signature','proof'],['expiry',String(now+1000)]])],cert,publisher,verifyEvent)).toThrow('held');
});
test('relay requires matching complete EOSE and rejects closed/disconnected/full/malformed responses',async()=>{
 const Native=globalThis.WebSocket;
 class Fake {onopen:any;onclose:any;onerror:any;onmessage:any;static mode='complete';constructor(){queueMicrotask(()=>this.onopen?.());}close(){}send(raw:string){const sub=JSON.parse(raw)[1];queueMicrotask(()=>{if(Fake.mode==='complete'){this.onmessage?.({data:JSON.stringify(['EVENT',sub,claim()])});this.onmessage?.({data:JSON.stringify(['EOSE',sub])});}if(Fake.mode==='closed')this.onmessage?.({data:JSON.stringify(['CLOSED',sub,'no'])});if(Fake.mode==='disconnect')this.onclose?.();if(Fake.mode==='malformed')this.onmessage?.({data:'not json'});if(Fake.mode==='full')for(let n=0;n<500;n++)this.onmessage?.({data:JSON.stringify(['EVENT',sub,claim()])});});}}
 try{globalThis.WebSocket=Fake as any;expect((await queryCertificateClaims(cert)).length).toBe(1);for(const mode of ['closed','disconnect','malformed','full']){Fake.mode=mode;await expect(queryCertificateClaims(cert)).rejects.toThrow('held');}}finally{globalThis.WebSocket=Native;}
});
