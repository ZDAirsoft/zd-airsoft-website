import test from 'node:test';
import assert from 'node:assert/strict';
import {handleVerifiedLeaderboard} from '../netlify/functions/arcade-verified-leaderboard.mjs';

const base='https://zdairsoft.com/arcade/api/leaderboard-verified?game=silhouette-precision&mode=standard-10&rev=2&limit=3';
const service={ARCADE_FLEET_CLAIMS_ENABLED:'true',SUPABASE_URL:'https://example.supabase.co',SUPABASE_SECRET_KEY:'sb_secret_abcdefghijklmnop'};
const sample={version:1,gameId:'silhouette-precision',modeId:'standard-10',scoringRevision:2,
 rows:[{rank:1,nickname:'TheRealWarNet',score:283,timeMs:4567,tenPointHits:10,centerChestHits:10,groupingRating:891}]};

test('old site continues to require explicit feed flag without global fleet activation',async()=>{
 const req=new Request(base);
 const response=await handleVerifiedLeaderboard(req,{},async()=>{throw Error('unexpected upstream')});
 assert.equal(response.status,503);
});

test('permanent fleet activation makes verified Silhouette public rankings available',async()=>{
 let calls=0;
 const req=new Request(base);
 const response=await handleVerifiedLeaderboard(req,service,async(url)=>{
  calls++;
  assert.match(String(url),/arcade_live_verified_leaderboard_silhouette_v2$/);
  return new Response(JSON.stringify(sample),{status:200});
 });
 assert.equal(response.status,200);
 assert.equal(calls,1);
 const data=await response.json();
 assert.equal(data.verified,true);
 assert.equal(data.rows[0].score,283);
});

test('global fleet activation does not bypass upstream errors or invalid rows',async()=>{
 const req=new Request(base);
 const unavailable=await handleVerifiedLeaderboard(req,service,async()=>new Response('{}',{status:503}));
 assert.equal(unavailable.status,503);
 const tampered={...sample,rows:[{...sample.rows[0],score:9999}]};
 const rejected=await handleVerifiedLeaderboard(req,service,async()=>new Response(JSON.stringify(tampered),{status:200}));
 assert.equal(rejected.status,503);
});
