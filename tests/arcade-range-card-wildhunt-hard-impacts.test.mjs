import test from 'node:test';
import assert from 'node:assert/strict';
import {handleMyVerifiedScores} from '../netlify/functions/arcade-my-verified-scores.mjs';
const userId='11111111-1111-4111-8111-111111111111';
const env={SUPABASE_URL:'https://example.supabase.co',SUPABASE_PUBLISHABLE_KEY:'sb_publishable_abcdefghijklmnop',SUPABASE_SECRET_KEY:'sb_secret_abcdefghijklmnop'};
const hunt={gameId:'wild-hunt',modeId:'hard',scoringRevision:1,score:17821,timeMs:121036,
 harvests:50,vitalHits:32,registeredImpacts:57,coverHits:0,basePoints:17821,sasquatchUplift:0};
const report={version:1,maxRecent:50,
 recent:[{...hunt,eventId:2,claimedAt:'2026-11-26T07:46:24.000Z'}],
 personalBests:[{...hunt,achievedAt:'2026-11-26T07:46:24.000Z'}],
 lifetimeByMode:[{gameId:'wild-hunt',modeId:'hard',scoringRevision:1,attempts:1,totalScore:17821,totalRawPoints:null,registeredImpacts:57,centerHits:32}]};
const request=()=>new Request('https://zdairsoft.com/arcade/api/my-verified-scores',{headers:{authorization:'Bearer header.payload.signature'}});
const mock=(doc)=>async(url)=>new Response(JSON.stringify(String(url).endsWith('/auth/v1/user')?{id:userId}:doc),{status:200});
test('private verified Range Card history accepts legitimate Wild Hunt Hard 57 impacts',async()=>{
 const r=await handleMyVerifiedScores(request(),env,mock(report));
 assert.equal(r.status,200);
 const doc=await r.json();
 assert.equal(doc.recent[0].registeredImpacts,57);
 assert.equal(doc.personalBests[0].registeredImpacts,57);
 assert.equal(doc.lifetimeByMode[0].registeredImpacts,57);
});
test('Wild Hunt Hard still rejects more than 100 registered impacts',async()=>{
 const row={...hunt,registeredImpacts:101};
 const r=await handleMyVerifiedScores(request(),env,mock({...report,recent:[{...row,eventId:2,claimedAt:'2026-11-26T07:46:24.000Z'}],personalBests:[{...row,achievedAt:'2026-11-26T07:46:24.000Z'}]}));
 assert.equal(r.status,503);
});
