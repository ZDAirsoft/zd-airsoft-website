import test from 'node:test';
import assert from 'node:assert/strict';
import {validWildHuntReceipt,normalizeWildHuntMetrics,validWildHuntRankRow} from '../netlify/functions/arcade-wild-hunt-v1.mjs';
import {handleVerifiedLeaderboard} from '../netlify/functions/arcade-verified-leaderboard.mjs';

const q={imp:50,hit:50,vital:45,pro:0,miss:0,stage:5,win:1,time:160000,har:50,cov:0,base:22000,sq:0};
const r=(mode='hard',metrics=q,score=22000)=>({g:'wild-hunt',m:mode,rv:1,q:metrics,s:score});
const env={ARCADE_WILD_HUNT_R1_FEED:'true',SUPABASE_URL:'https://example.supabase.co',SUPABASE_SECRET_KEY:'sb_secret_aaaaaaaaaaaaaaaa'};
const url=(mode='hard')=>'https://zdairsoft.com/arcade/api/leaderboard-verified?game=wild-hunt&mode='+mode+'&rev=1&limit=3';

test('Wild Hunt revision 1 private modes and hard only victory bounds',()=>{
 assert.equal(validWildHuntReceipt(r()),true);
 assert.equal(validWildHuntReceipt(r('medium',{...q,imp:25,hit:25,vital:25,har:25})),true);
 assert.equal(validWildHuntReceipt(r('easy',{...q,imp:25,hit:25,vital:25,har:25})),true);
 assert.equal(validWildHuntReceipt(r('hard',{...q,imp:49})),false);
 assert.equal(validWildHuntReceipt(r('hard',{...q,pro:1})),false);
 assert.equal(validWildHuntReceipt(r('hard',{...q,sq:1})),false);
 assert.equal(validWildHuntReceipt(r('hard',{...q,har:49})),false);
 assert.equal(validWildHuntReceipt(r('hard',{...q,stage:4})),false);
 assert.equal(validWildHuntReceipt(r('hard',{...q,base:22001})),false);
 assert.equal(validWildHuntReceipt(r('hard',{...q,extra:1})),false);
 assert.equal(validWildHuntReceipt(r('hard',q,29201)),false);
 assert.deepEqual(normalizeWildHuntMetrics(q),q);
});

test('Hard tied ranks 1,1,3, with no elapsed-time tiebreak',()=>{
 const rows=[{rank:1,nickname:'PlayerOne',score:23000},{rank:1,nickname:'PlayerTwo',score:23000},{rank:3,nickname:'PlayerThree',score:21000}];
 assert.ok(validWildHuntRankRow(rows[0],0,null));
 assert.ok(validWildHuntRankRow(rows[1],1,rows[0]));
 assert.ok(validWildHuntRankRow(rows[2],2,rows[1]));
 assert.equal(validWildHuntRankRow({...rows[2],rank:2},2,rows[1]),false);
});

test('Easy/Medium and disabled Hard never query Supabase',async()=>{
 let calls=0;const nofetch=()=>{calls++;throw Error('unwanted network')};
 assert.equal((await handleVerifiedLeaderboard(new Request(url('easy')),env,nofetch)).status,404);
 assert.equal((await handleVerifiedLeaderboard(new Request(url('medium')),env,nofetch)).status,404);
 assert.equal((await handleVerifiedLeaderboard(new Request(url()),{...env,ARCADE_WILD_HUNT_R1_FEED:'false'},nofetch)).status,503);
 assert.equal(calls,0);
});

test('Hard tie board validates and filters to maximum three entries',async()=>{
 const rows=[{rank:1,nickname:'PlayerOne',score:23000},{rank:1,nickname:'PlayerTwo',score:23000},
  {rank:3,nickname:'PlayerThree',score:21000},{rank:4,nickname:'PlayerFour',score:20000}];
 let calls=0;
 const mock=async(upstream,options)=>{
  calls++;
  assert.match(upstream,/arcade_live_verified_leaderboard_wildhunt_v1$/);
  assert.equal(JSON.parse(options.body).p_mode_id,'hard');
  return Response.json({version:1,gameId:'wild-hunt',modeId:'hard',scoringRevision:1,rows});
 };
 const res=await handleVerifiedLeaderboard(new Request(url()),env,mock,()=>new Date('2026-11-22T21:00:00Z'));
 assert.equal(res.status,200);
 const response=await res.json();
 assert.equal(response.verified,true);
 assert.deepEqual(response.rankingOrder,['score_desc']);
 assert.deepEqual(response.rows.map(x=>x.rank),[1,1,3]);
 assert.equal(response.rows.length,3);
 assert.equal(calls,1);
});

test('invalid tied rank and duplicate nickname fail closed',async()=>{
 for(const rows of [
  [{rank:1,nickname:'PlayerOne',score:23000},{rank:2,nickname:'PlayerTwo',score:23000}],
  [{rank:1,nickname:'PlayerOne',score:23000},{rank:2,nickname:'playerone',score:22000}]
 ]){
  const mock=async()=>Response.json({version:1,gameId:'wild-hunt',modeId:'hard',scoringRevision:1,rows});
  const res=await handleVerifiedLeaderboard(new Request(url()),env,mock);
  assert.equal(res.status,503);
 }
});
