import { test, expect } from "bun:test";
import { validate, signChecked, verifyProof, eventSet, historyMax, completeHistory, PACKAGE, PUBLISHER, BLOSSOM } from "./zapstore_broker.ts";
const cert="a".repeat(64);
const asset=()=>({kind:3063,pubkey:PUBLISHER,created_at:1,content:"",tags:[["i",PACKAGE],["x","b".repeat(64)],["apk_certificate_hash",cert],["version_code","12"],["url",BLOSSOM+"/"+"b".repeat(64)]]});
test("rejects stable APK, foreign publisher, certificate and host",()=>{
  for(const e of [{...asset(),pubkey:"b".repeat(64)},{...asset(),tags:asset().tags.map(t=>t[0]==="i"?["i","com.wingmanbefree.wingman_app"]:t)},{...asset(),tags:asset().tags.map(t=>t[0]==="apk_certificate_hash"?[t[0],"b".repeat(64)]:t)},{...asset(),tags:asset().tags.map(t=>t[0]==="url"?["url","https://evil.example/file"]:t)}])expect(()=>validate(e,cert)).toThrow();
});
test("broker denial propagates without retry or fallback",async()=>{
  let calls=0;await expect(signChecked(asset(),cert,async()=>{calls++;throw Error("denied");},()=>true)).rejects.toThrow("denied");expect(calls).toBe(1);
});
test("broker mutation, invalid signature and timestamp mismatch fail closed",async()=>{
  await expect(signChecked(asset(),cert,async()=>({event:{...asset(),pubkey:"x"}}),()=>true)).rejects.toThrow();
  await expect(signChecked(asset(),cert,async()=>({event:asset()}),()=>false)).rejects.toThrow();
  const proof={kind:30509,pubkey:PUBLISHER,created_at:1,content:"",tags:[["d",cert],["expiry","2"],["signature","abc"]]};
  await expect(signChecked(proof,cert,async()=>({event:{...proof,created_at:2}}),()=>true)).rejects.toThrow("timestamp changed");
});
test("valid template retains exact tags and content while asset ID changes",async()=>{
  const e=asset();const signed=await signChecked(e,cert,async()=>({event:{...e,created_at:5,id:"signed"}}),()=>true);expect(signed.id).toBe("signed");expect(signed.tags).toEqual(e.tags);
});
test("invalid certificate proof is rejected before publication",()=>expect(()=>verifyProof({kind:30509,pubkey:PUBLISHER,created_at:1,content:"",tags:[]},new Uint8Array())).toThrow());

test("public GitHub assets require the exact authorized Nightly repository",()=>{
 const e=asset();e.tags=e.tags.map(t=>t[0]==="url"?["url","https://github.com/OtherStuffAI/wingman-nightly/releases/download/nightly-2026-10-06-12/app-release.apk"]:t);
 expect(()=>validate(e,cert)).not.toThrow();
 e.tags=e.tags.map(t=>t[0]==="url"?["url",t[1].replace("wingman-nightly","wm-app")]:t);expect(()=>validate(e,cert)).toThrow();
});

test("exact cardinality and release asset references are mandatory",()=>{
 const a={...asset(),id:"asset"};const r={...asset(),kind:30063,tags:[["e","asset"]]};const app={...asset(),kind:32267};
 expect(eventSet([a,r,app]).asset.id).toBe("asset");
 for(const events of [[a,r],[a,r,a],[a,r,app,app],[a,{...r,tags:[["e","wrong"]]},app],[a,{...r,tags:[["e","asset"],["e","asset"]]},app]])expect(()=>eventSet(events)).toThrow();
});
test("history rejects malformed, noncanonical, duplicate identity and unsigned codes",()=>{
 for(const code of ["NaN","1.5","0","-1","","01","Infinity"]){const e=asset();e.tags=e.tags.map(t=>t[0]==="version_code"?[t[0],code]:t);expect(()=>historyMax([e],()=>true)).toThrow();}
 expect(()=>historyMax([asset()],()=>false)).toThrow();expect(historyMax([asset()],()=>true)).toBe(12);
});
test("complete history paginates and includes full timestamp boundary",async()=>{
 const event=(id:string,t:number)=>({...asset(),id,created_at:t});let calls=0;
 const result=await completeHistory(async filter=>{calls++;if(calls===1)return Array.from({length:500},(_,i)=>event(String(i),100));if(calls===2){expect(filter.since).toBe(100);return [event("hidden-at-boundary",100)];}expect(filter.until).toBe(99);return [event("old",1)];});
 expect(result.length).toBe(502);expect(calls).toBe(3);
 await expect(completeHistory(async()=>Array.from({length:5000},(_,i)=>event(String(i),100)))).rejects.toThrow("incomplete");
});
test("certificate expiry and conflicting proof tags fail closed",()=>{
 const proof={kind:30509,pubkey:PUBLISHER,created_at:1,content:"",tags:[["d",cert],["expiry","2"],["signature","abc"]]};
 for(const expiry of ["NaN","1","1.5","01"]){expect(()=>validate({...proof,tags:proof.tags.map(t=>t[0]==="expiry"?[t[0],expiry]:t)},cert)).toThrow();}
 expect(()=>validate({...proof,tags:[...proof.tags,["expiry","3"]]},cert)).toThrow("Duplicate");
});

test("release download metadata only allows the verified CDN redirect read path",()=>{
 const e={kind:30063,pubkey:PUBLISHER,created_at:1,content:"",tags:[["i",PACKAGE],["version","1"],["d",PACKAGE+"@1"],["c","nightly"],["url",BLOSSOM+"/"+"b".repeat(64)+"?redirect=true"]]};
 expect(()=>validate(e,cert)).not.toThrow();e.tags=e.tags.map(t=>t[0]==="url"?["url",t[1].replace("redirect=true","delete=true")]:t);expect(()=>validate(e,cert)).toThrow();
 const h=asset();h.tags.push(["version_code","13"]);expect(()=>historyMax([h],()=>true)).toThrow();
});
