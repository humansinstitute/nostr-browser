/** Conservative legacy-publisher hold. No signing, credentials or mutation. */
export const CATALOG_RELAY = 'wss://relay.zapstore.dev';
const LIMIT = 500;
type Claim = { id: string; pubkey: string; kind: number; created_at: number; content: string; tags: string[][]; sig: string };
export function requireLegacyClaim(claims: Claim[], certificate: string, publisher: string, verify: (e: any) => boolean, now = Math.floor(Date.now()/1000)) {
  const hold = () => { throw Error('Zapstore publishing held: certificate claims changed or are incomplete; review current ownership and use the authorized owner signer.'); };
  if (!/^[0-9a-f]{64}$/.test(certificate) || !/^[0-9a-f]{64}$/.test(publisher) || !claims.length || claims.length >= LIMIT) hold();
  const seen = new Set<string>();
  for (const e of claims) {
    // JSON cloning prevents a verifier cache on a mutable object from becoming authority.
    let valid = false; try { valid = verify(JSON.parse(JSON.stringify(e))); } catch {}
    if (!valid || e.kind !== 30509 || e.pubkey !== publisher || !Number.isSafeInteger(e.created_at) || e.created_at <= 0 || e.created_at > now+5 || e.content !== '' || !Array.isArray(e.tags) || e.tags.length !== 3) hold();
    if (seen.has(e.id)) continue;
    seen.add(e.id);
    const one = (name: string) => { const ts=e.tags.filter(t=>t[0]===name); if(ts.length!==1 || ts[0].length!==2) hold(); return ts[0][1]; };
    if (e.tags.some(t=>!['d','signature','expiry'].includes(t[0])) || one('d')!==certificate || !one('signature') || !/^[1-9][0-9]*$/.test(one('expiry')) || !Number.isSafeInteger(Number(one('expiry'))) || Number(one('expiry'))<=now) hold();
  }
  if (seen.size !== 1) hold();
  return { certificate, publisher, claim: [...seen][0], scope: 'official-relay conservative signed-claim hold; not app-key verification or global ownership proof' };
}
export async function queryCertificateClaims(certificate: string): Promise<Claim[]> {
  if (!/^[0-9a-f]{64}$/.test(certificate)) throw Error('Exact certificate hash required.');
  return new Promise((resolve,reject)=>{
    const ws=new WebSocket(CATALOG_RELAY), sub=crypto.randomUUID(), events:Claim[]=[];
    let settled=false;
    const finish=(error?:Error)=>{if(settled)return;settled=true;clearTimeout(timer);ws.close();error?reject(error):resolve(events);};
    const timer=setTimeout(()=>finish(Error('Zapstore ownership query incomplete; publishing held.')),15000);
    ws.onopen=()=>ws.send(JSON.stringify(['REQ',sub,{kinds:[30509],'#d':[certificate],limit:LIMIT}]));
    ws.onerror=()=>finish(Error('Zapstore ownership query failed; publishing held.'));
    ws.onclose=()=>{if(!settled)finish(Error('Zapstore ownership query closed before EOSE; publishing held.'));};
    ws.onmessage=({data})=>{
      if(settled)return;
      let m:any;try{if(String(data).length>1024*1024)throw Error();m=JSON.parse(String(data));}catch{finish(Error('Malformed ownership query response; publishing held.'));return;}
      if(!Array.isArray(m))return;
      if(m[0]==='EVENT'&&m[1]===sub){events.push(m[2]);if(events.length>=LIMIT)finish(Error('Ownership query may be truncated; publishing held.'));}
      if(m[0]==='EOSE'&&m[1]===sub)finish();
      if(m[0]==='CLOSED'&&m[1]===sub)finish(Error('Ownership query rejected; publishing held.'));
    };
  });
}
export async function assertLegacyPublisherAllowed(certificate:string,publisher:string,verify:(e:any)=>boolean,query=queryCertificateClaims) {
  return requireLegacyClaim(await query(certificate),certificate,publisher,verify);
}
