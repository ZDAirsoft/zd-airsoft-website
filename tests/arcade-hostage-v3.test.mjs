import test from 'node:test';
import assert from 'node:assert/strict';
import {HOSTAGE_MODES,HOSTAGE_PUBLIC_BOARDS,hostageBoardForScreen,normalizeHostageMetrics,computeHostageScore,validHostageReceipt} from '../netlify/functions/arcade-hostage-v3.mjs';
import {handleVerifiedLeaderboard} from '../netlify/functions/arcade-verified-leaderboard.mjs';
const metrics=(override={})=>({s:12,h:12,p:0,m:0,c:2,f:0,t:15000,w:0,...override});
const score=(mode,q)=>computeHostageScore(mode,normalizeHostageMetrics(q));
const receipt=(mode,q)=>({g:'hostage-rescue',m:mode,rv:3,s:score(mode,q),t:1790000000,d:'01',k:'K1234567890ABCDEF',e:2,q});
test('all nine private mode IDs; precisely two public hard boards',()=>{
 assert.equal(HOSTAGE_MODES.length,9); assert.equal(HOSTAGE_PUBLIC_BOARDS.length,2);
 assert.equal(hostageBoardForScreen('classic-rescue-easy'),'classic-rescue-hard');
 assert.equal(hostageBoardForScreen('timed-45s-normal'),'timed-45s-hard');
 assert.equal(hostageBoardForScreen('no-mistakes-hard'),null);
 for(const mode of HOSTAGE_MODES){const q=metrics();assert.equal(score(mode,q)!==null,true);assert.equal(validHostageReceipt(receipt(mode,q)),true);}
});
test('perfect score 300, cubic discipline rounds half up',()=>{
 assert.equal(score('classic-rescue-hard',metrics()),300);
 assert.equal(score('no-mistakes-normal',metrics({t:17000})),300);
 // 12 hits/16 shots -> 50*(.75)^3 = 21.09375 -> 21
 const q=metrics({s:16,m:4});assert.equal(score('classic-rescue-easy',q),271);
});
test('tampered score, malformed counters, invalid modes, excessive misses and timed expiry reject',()=>{
 const q=metrics();assert.equal(validHostageReceipt({...receipt('classic-rescue-hard',q),s:299}),false);
 assert.equal(score('fake',q),null);
 assert.equal(score('no-mistakes-hard',metrics({s:13,m:1})),null);
 assert.equal(score('no-mistakes-normal',metrics({s:14,m:2})),null);
 assert.equal(score('no-mistakes-easy',metrics({p:1,s:13})),null);
 assert.equal(score('timed-45s-hard',metrics({t:45001})),null);
 assert.equal(score('classic-rescue-hard',{...q,bad:2}),null);
 assert.equal(score('classic-rescue-hard',metrics({w:1})),null);
});
test('unavailable/unsupported boards fail closed without backend query',async()=>{
 let count=0;const fetcher=()=>{count++;throw Error('should not fetch')};
 const env={SUPABASE_URL:'https://x.supabase.co',SUPABASE_SECRET_KEY:'sb_secret_aaaaaaaaaaaaaaaa'};
 const a=await handleVerifiedLeaderboard(new Request('https://zdairsoft.com/arcade/api/leaderboard-verified?game=hostage-rescue&mode=classic-rescue-easy&rev=3'),env,fetcher);
 const b=await handleVerifiedLeaderboard(new Request('https://zdairsoft.com/arcade/api/leaderboard-verified?game=hostage-rescue&mode=no-mistakes-hard&rev=3'),env,fetcher);
 assert.equal(a.status,404);assert.equal(b.status,404);assert.equal(count,0);
});
