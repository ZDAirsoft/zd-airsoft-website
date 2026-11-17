import {test} from 'node:test';
import assert from 'node:assert/strict';
import {validSilhouetteMetrics, normalizedSilhouetteMetrics, validSilhouetteReceipt, SILHOUETTE_MODES} from '../netlify/functions/arcade-silhouette-r1.mjs';
import {handleSignedClaim} from '../netlify/functions/arcade-signed-claim.mjs';
import {handleVerifiedLeaderboard} from '../netlify/functions/arcade-verified-leaderboard.mjs';
const metrics={s:10,h:9,t:2,c:1,m:9000,a:1,b:1,d:2,e:4,f:2};
const receipt={g:'silhouette-precision',m:'standard-10',rv:1,s:77,e:2,d:'01',p:1,t:1795000000,q:metrics};
test('all nine boards accepted by namespace',()=>assert.equal(SILHOUETTE_MODES.length,9));
test('normalizes the exact signed field set',()=>{
  const m=normalizedSilhouetteMetrics(metrics);
  assert.ok(m);assert.equal(validSilhouetteMetrics('standard-10',77,m),true);
  assert.equal(validSilhouetteReceipt(receipt),true);
  assert.equal(normalizedSilhouetteMetrics({...metrics,extra:0}),null);
  assert.equal(normalizedSilhouetteMetrics({...metrics,t:-1}),null);
  assert.equal(validSilhouetteReceipt({...receipt,m:'standard-20'}),false);
});
test('tampered metrics, precision rules, and wrong pilot identity rejected',()=>{
  assert.equal(validSilhouetteReceipt({...receipt,q:{...metrics,e:5}}),false);
  assert.equal(validSilhouetteReceipt({...receipt,p:undefined}),false);
  assert.equal(validSilhouetteReceipt({...receipt,e:3}),false);
  assert.equal(validSilhouetteReceipt({...receipt,q:{...metrics,c:3}}),false);
  const p={s:10,h:3,t:3,c:3,m:5000,a:7,b:0,d:0,e:0,f:3};
  assert.equal(validSilhouetteReceipt({...receipt,m:'precision-10',s:30,q:p}),true);
  assert.equal(validSilhouetteReceipt({...receipt,m:'precision-10',s:30,q:{...p,b:1}}),false);
});
test('signed route rejects missing session before contacting upstream',async()=>{
  const r=await handleSignedClaim(new Request('https://zdairsoft.com/arcade/api/claim-signed-score',{method:'POST',headers:{'content-type':'application/json'},body:'{}'}));
  assert.equal(r.status,401);
});
test('leaderboard remains explicitly disabled without env variable',async()=>{
  const r=await handleVerifiedLeaderboard(new Request('https://zdairsoft.com/arcade/api/leaderboard-verified?game=silhouette-precision&mode=standard-10&rev=1&limit=3'),{},async()=>{throw Error('upstream called');});
  assert.equal(r.status,503);assert.equal((await r.json()).error,'verified_rankings_unavailable');
});
import {generateKeyPairSync,createHash,sign as signPayload} from 'node:crypto';
const cborHead=(major,n)=>n<24?Buffer.from([(major<<5)|n]):n<256?Buffer.from([(major<<5)|24,n]):n<65536?Buffer.from([(major<<5)|25,n>>8,n&255]):Buffer.concat([Buffer.from([(major<<5)|26]),Buffer.from([n>>>24,n>>>16,n>>>8,n])]);
function enc(x){
 if(typeof x==='number')return cborHead(0,x);
 if(typeof x==='string'){const b=Buffer.from(x);return Buffer.concat([cborHead(3,b.length),b]);}
 if(Buffer.isBuffer(x))return Buffer.concat([cborHead(2,x.length),x]);
 if(x instanceof Map){const entries=[...x].sort((a,b)=>{const ak=enc(a[0]),bk=enc(b[0]);return ak.length-bk.length||Buffer.compare(ak,bk)});return Buffer.concat([cborHead(5,entries.length),...entries.flatMap(([k,v])=>[enc(k),enc(v)])]);}
 throw Error('invalid_fixture');
}
test('real P-256 signature selects Silhouette RPC and full metrics, pilot flag gated',async()=>{
 const {privateKey,publicKey}=generateKeyPairSync('ec',{namedCurve:'prime256v1'});
 const spki=publicKey.export({format:'der',type:'spki'});
 const keyId='KFFFFFFFFFFFFFFFF';
 const resultId='12345678-1234-4123-8123-123456789abc';
 const compact=new Map(Object.entries(metrics));
 const map=new Map([[1,1],[2,Buffer.from(resultId.replaceAll('-',''),'hex')],[3,'01'],[4,keyId],[5,'silhouette-precision'],[6,'standard-10'],[7,1],[8,77],[9,1795000000],[10,compact],[12,2],[13,1]]);
 const payload=enc(map);
 const rawSignature=signPayload('sha256',Buffer.concat([Buffer.from('ZDAIRSOFT_SCORE_V1\0'),payload]),{key:privateKey,dsaEncoding:'ieee-p1363'});
 const wire='zda1:'+payload.toString('base64url')+'.'+rawSignature.toString('base64url');
 assert.ok(wire.length<=362,`wire length ${wire.length}`);
 const now=1795001000000;
 const registry={keyId,monitorId:'01',eventId:2,publicKeyHex:spki.toString('hex'),publicKeySha256:createHash('sha256').update(spki).digest('hex'),
   startsAt:'2026-01-01T00:00:00Z',endsAt:'2027-01-01T00:00:00Z',keyStatus:'active',eventStatus:'active'};
 const env={SUPABASE_URL:'https://arcadetest.supabase.co',SUPABASE_SECRET_KEY:'sb_secret_ABCDEFGHIJKLMNOP',SUPABASE_PUBLISHABLE_KEY:'sb_publishable_ABCDEFGHIJKLMNOP',
   ARCADE_SIGNED_CLAIMS_ENABLED:'true',ARCADE_SIGNED_TEST_EVENT_ID:'2',ARCADE_SILHOUETTE_R1_PILOT:'true'};
 const called=[];
 const fetcher=async(url,opt)=>{
  called.push({url,opt});
  const data=url.endsWith('/auth/v1/user')?{id:'12345678-1234-4123-8123-123456789abc'}:
   url.endsWith('/arcade_live_signed_preflight_v1')?registry:{outcome:'created'};
  return new Response(JSON.stringify(data),{status:200});
 };
 const makeReq=(mode)=>new Request('https://zdairsoft.com/arcade/api/claim-signed-score',{method:'POST',headers:{'content-type':'application/json',authorization:'Bearer abc.def.ghi'},body:JSON.stringify({mode,wire})});
 let r=await handleSignedClaim(makeReq('verify'),{...env,ARCADE_SILHOUETTE_R1_PILOT:'false'},fetcher,()=>now);
 assert.equal(r.status,200);assert.equal((await r.json()).claimable,false);
 r=await handleSignedClaim(makeReq('claim'),env,fetcher,()=>now);
 assert.equal(r.status,201);assert.equal((await r.json()).gameId,'silhouette-precision');
 const rpc=called.find(c=>c.url.endsWith('/arcade_live_signed_claim_silhouette_v1'));
 assert.ok(rpc,'dedicated Silhouette RPC selected');
 const posted=JSON.parse(rpc.opt.body);
 assert.deepEqual(posted.p_metrics,normalizedSilhouetteMetrics(metrics));
 assert.equal(posted.p_game_id,'silhouette-precision');
 assert.equal(posted.p_score,77);
 r=await handleSignedClaim(makeReq('claim'),{...env,ARCADE_SILHOUETTE_R1_PILOT:'false'},fetcher,()=>now);
 assert.equal(r.status,503);assert.equal((await r.json()).code,'signed_claims_not_activated');
});
