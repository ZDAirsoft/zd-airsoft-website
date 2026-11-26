import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync,createHash,sign } from 'node:crypto';
import { verifyFleetEnrollmentProof,handleFleetV1 } from '../netlify/functions/arcade-fleet-v1.mjs';

const {privateKey,publicKey}=generateKeyPairSync('ec',{namedCurve:'prime256v1'});
const spki=publicKey.export({format:'der',type:'spki'});
const keyId='K'+createHash('sha256').update(spki).digest('hex').slice(0,16).toUpperCase();
const challengeId='f3a415cf-9bf9-4512-b82c-5b27d780d158';
const nonceHex='12'.repeat(32);
const challenge={challengeId,keyId,nonceHex};
const domain=Buffer.from('ZDAIRSOFT_FLEET_ENROLL_V1\0','utf8');
const message=Buffer.concat([domain,Buffer.from(challengeId+':'+nonceHex+':'+keyId,'ascii')]);
const signatureHex=sign('sha256',message,{key:privateKey,dsaEncoding:'der'}).toString('hex');
const payload={action:'prove',challengeId,keyId,publicKeyHex:spki.toString('hex'),signatureHex};

test('P-256 proof of possession binds challenge, key ID and SPKI',()=>{
 assert.equal(verifyFleetEnrollmentProof(payload,challenge),true);
 assert.equal(verifyFleetEnrollmentProof({...payload,keyId:'K'+'A'.repeat(16)},challenge),false);
 assert.equal(verifyFleetEnrollmentProof({...payload,signatureHex:'00'.repeat(70)},challenge),false);
 assert.equal(verifyFleetEnrollmentProof(payload,{...challenge,nonceHex:'34'.repeat(32)}),false);
 assert.equal(verifyFleetEnrollmentProof(payload,{...challenge,challengeId:'c3a415cf-9bf9-4512-b82c-5b27d780d158'}),false);
});
test('feature is disabled by default; no server RPC call occurs',async()=>{
 let calls=0;
 const req=new Request('https://zdairsoft.com/arcade/api/fleet-v1',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({action:'challenge',keyId})});
 const response=await handleFleetV1(req,{},async()=>{calls++;throw Error('unexpected network')});
 assert.equal(response.status,503);
 assert.equal((await response.json()).code,'fleet_enrollment_disabled');
 assert.equal(calls,0);
});
test('unknown action is rejected without an upstream call',async()=>{
 let calls=0;
 const req=new Request('https://zdairsoft.com/arcade/api/fleet-v1',{method:'POST',headers:{'content-type':'application/json'},body:'{"action":"sign-score"}'});
 const env={ARCADE_FLEET_ENROLLMENT_V1:'true',SUPABASE_URL:'https://test.supabase.co',SUPABASE_SECRET_KEY:'sb_secret_abcdefghijklmnop',SUPABASE_PUBLISHABLE_KEY:'sb_publishable_abcdefghijklmnop'};
 const response=await handleFleetV1(req,env,async()=>{calls++;throw Error('unexpected')});
 assert.equal(response.status,400);
 assert.equal(calls,0);
});
test('owner-only endpoint requires a Supabase bearer token',async()=>{
 let calls=0;
 const req=new Request('https://zdairsoft.com/arcade/api/fleet-v1',{method:'POST',headers:{'content-type':'application/json'},body:'{"action":"pending"}'});
 const env={ARCADE_FLEET_ENROLLMENT_V1:'true',SUPABASE_URL:'https://test.supabase.co',SUPABASE_SECRET_KEY:'sb_secret_abcdefghijklmnop',SUPABASE_PUBLISHABLE_KEY:'sb_publishable_abcdefghijklmnop'};
 const response=await handleFleetV1(req,env,async()=>{calls++;throw Error('unexpected')});
 assert.equal(response.status,401);
 assert.equal(calls,0);
});

test('successful proof automatically assigns station without staff login',async()=>{
 const calls=[];
 const env={ARCADE_FLEET_ENROLLMENT_V1:'true',
   SUPABASE_URL:'https://test.supabase.co',
   SUPABASE_SECRET_KEY:'sb_secret_abcdefghijklmnop',
   SUPABASE_PUBLISHABLE_KEY:'sb_publishable_abcdefghijklmnop'};
 const req=new Request('https://zdairsoft.com/arcade/api/fleet-v1',{
   method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(payload)});
 const fakeFetch=async(url,opts)=>{
   const fn=String(url).split('/').pop();calls.push(fn);
   const data=fn==='arcade_fleet_challenge_check_v1'?challenge:
     fn==='arcade_fleet_record_proof_v1'?{keyId,status:'pending'}:
     fn==='arcade_fleet_autoadmit_v1'?{keyId,status:'approved',monitorId:'03'}:null;
   if(data===null)throw Error('unexpected RPC '+fn);
   return new Response(JSON.stringify(data),{status:200});
 };
 const result=await handleFleetV1(req,env,fakeFetch);
 assert.equal(result.status,200);
 assert.deepEqual(calls,[
  'arcade_fleet_challenge_check_v1',
  'arcade_fleet_record_proof_v1',
  'arcade_fleet_autoadmit_v1'
 ]);
 const out=await result.json();
 assert.equal(out.status,'approved');
 assert.equal(out.monitorId,'03');
});
