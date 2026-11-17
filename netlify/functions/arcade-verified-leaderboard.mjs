import { validR2Score } from './arcade-bullseye-r2.mjs';
import { validR3Score,r3Streak } from './arcade-bullseye-r3.mjs';
import { silhouetteMode,validSilhouetteRankRow } from './arcade-silhouette-r1.mjs';
import { validZombieRankRow } from './arcade-zombie-campaign-v1.mjs';
import {isExtraMode,validBullseyeExtra,supportedBullseye,timedSeconds} from './arcade-bullseye-modes-v1.mjs';
/**
 * Z&D Airsoft Arcade verified-only public leaderboard, Stage 6.
 * Separate from the existing unsigned /arcade/api/leaderboard route.
 * Only publishes nicknames and bounded competition metrics for profiles with
 * public-score consent; the server-only RPC applies privacy and moderation rules.
 */
const JSON_HEADERS={
  'content-type':'application/json; charset=utf-8',
  'x-content-type-options':'nosniff',
  'cache-control':'no-store',
  'access-control-allow-origin':'*',
};
const answer=(status,body)=>new Response(JSON.stringify(body),{status,headers:JSON_HEADERS});
function projectOrigin(value) {
  try {
    const u=new URL(value);
    return u.protocol==='https:' && !u.port && !u.username && !u.password &&
      u.pathname==='/' && !u.search && !u.hash &&
      /^[a-z0-9-]+\.supabase\.co$/.test(u.hostname) ? u.origin : null;
  }catch{return null;}
}
const integer=(v,lo,hi)=>Number.isInteger(v)&&v>=lo&&v<=hi;
const nickname=(v)=>typeof v==='string'&&/^[A-Za-z0-9][A-Za-z0-9 -]{1,15}$/.test(v);
function publicRow(entry,rank,mode,revision) {
  const extra=isExtraMode(mode,revision);
  const capped=mode==='ten-shot'?revision>=2?300:125:mode==='perfect-100'?revision===2?300:100:revision===2?7680:5120;
  if(!entry||entry.rank!==rank||!nickname(entry.nickname)||
     !integer(entry.score,0,capped)||!integer(entry.rawPoints,0,extra?5120:100)||
     !integer(entry.registeredImpacts,1,extra?512:10)||!integer(entry.centerHits,0,extra?512:10)||
     entry.centerHits>entry.registeredImpacts||!integer(entry.timeMs,0,extra?3600000:600000)||
     !integer(entry.speedBonus,0,extra?(revision===2?100:0):revision===3?85:revision===2?100:15)||
     !integer(entry.groupingBonus,extra&&revision===2?-3840:0,extra?(revision===2?2560:0):revision===3?85:revision===2?100:10)||
     !(entry.groupMeanX100===null||integer(entry.groupMeanX100,0,100000))||
     entry.rawPoints<entry.centerHits*10)throw Error('invalid_leaderboard_row');
  if(extra){
    if((revision===1 && entry.groupMeanX100!==null) ||
       (revision===2 && entry.groupMeanX100===null) ||
       !validBullseyeExtra(mode,revision,{
      raw_points:entry.rawPoints,shots:entry.registeredImpacts,main_target_hits:
      // Shape-only public check: mainTargetHits are not disclosed in this feed.
      // Atomic signed claim writer checked the actual main count.
      entry.registeredImpacts,center_hits:entry.centerHits,time_ms:entry.timeMs,
      speed_bonus:entry.speedBonus,group_bonus:entry.groupingBonus,
      ...(revision===2?{group_mean_x100:entry.groupMeanX100}:{})},entry.score,revision===2))throw Error('invalid_extra_row');
  } else {
    if(entry.registeredImpacts!==10||entry.rawPoints>100||
       (revision!==3&&entry.score!==entry.rawPoints+entry.groupingBonus+entry.speedBonus)||
       (revision===1&&(![0,5,10].includes(entry.groupingBonus)||![0,5,10,15].includes(entry.speedBonus)))||
       (entry.groupingBonus>0&&entry.groupMeanX100===null)||
       (revision===3&&!validR3Score({raw_points:entry.rawPoints,
         shots:entry.registeredImpacts,main_target_hits:entry.groupMeanX100===null?entry.centerHits:10,
         center_hits:entry.centerHits,time_ms:entry.timeMs,speed_bonus:entry.speedBonus,
         group_bonus:entry.groupingBonus,longest_streak:entry.longestStreak,
         ...(entry.groupMeanX100===null?{}:{group_mean_x100:entry.groupMeanX100})},entry.score,true))||
       (revision===2&&!validR2Score({raw_points:entry.rawPoints,
         shots:entry.registeredImpacts,main_target_hits:entry.groupMeanX100===null?entry.centerHits:10,
         center_hits:entry.centerHits,time_ms:entry.timeMs,speed_bonus:entry.speedBonus,
         group_bonus:entry.groupingBonus,...(entry.groupMeanX100===null?{}:{group_mean_x100:entry.groupMeanX100})},entry.score)))
       throw Error('invalid_tenshot_row');
  }
  return {
    rank,nickname:entry.nickname,score:entry.score,timeMs:entry.timeMs,
    centerHits:entry.centerHits,registeredImpacts:entry.registeredImpacts,
    centerHitRatePct:Math.round(100*entry.centerHits/entry.registeredImpacts),
    rawPoints:entry.rawPoints,groupMeanX100:entry.groupMeanX100,
    groupingBonus:entry.groupingBonus,speedBonus:entry.speedBonus,
    ...(revision===3?{longestStreak:entry.longestStreak,streakBonus:r3Streak(entry.longestStreak)}:{}),
  };
}
export const config={path:'/arcade/api/leaderboard-verified'};
export async function handleVerifiedLeaderboard(req,env=process.env,fetcher=fetch,now=()=>new Date()) {
  if(req.method!=='GET')return answer(405,{error:'method_not_allowed'});
  let url;
  try{url=new URL(req.url);}catch{return answer(400,{error:'invalid_request'});}
  const params=url.searchParams;
  const silhouette=params.get('game')==='silhouette-precision'&&silhouetteMode(params.get('mode'))&&params.get('rev')==='1';
  const zombie=params.get('game')==='zombie-outbreak'&&params.get('mode')==='campaign'&&params.get('rev')==='1';
  if((!zombie && !silhouette && (params.get('game')!=='bullseye-classic'||
    !supportedBullseye(params.get('mode'),params.get('rev')==='3'?3:params.get('rev')==='2'?2:1)))||
    (params.has('limit')&&!['3','50'].includes(params.get('limit')))||
    (params.has('rev')&&!['1','2','3'].includes(params.get('rev')))||
    [...params].some(([k,v])=>!['game','mode','limit','rev'].includes(k)&&(!/^utm_[a-z_]{1,30}$/.test(k)||v.length>100)))
    return answer(404,{error:'unknown_verified_leaderboard'});
  const limit=params.get('limit')==='50'?50:3;
  const revision=params.get('rev')==='3'?3:params.get('rev')==='2'?2:1;
  const mode=params.get('mode');
  if(silhouette && env.ARCADE_SILHOUETTE_R1_FEED!=='true')return answer(503,{error:'verified_rankings_unavailable'});
  if(zombie && env.ARCADE_ZOMBIE_CAMPAIGN_R1_FEED!=='true')return answer(503,{error:'verified_rankings_unavailable'});
  const project=projectOrigin(env.SUPABASE_URL);
  const secret=env.SUPABASE_SECRET_KEY;
  if(!project||typeof secret!=='string'||!/^sb_secret_[A-Za-z0-9_-]{12,}$/.test(secret))
    return answer(503,{error:'service_not_configured'});
  try {
    const upstream=await fetcher(project+'/rest/v1/rpc/'+(silhouette?'arcade_live_verified_leaderboard_silhouette_v1':zombie?'arcade_live_verified_leaderboard_zombie_campaign_v1':isExtraMode(mode,revision)?(revision===2?'arcade_live_verified_leaderboard_bullseye_modes_v2':'arcade_live_verified_leaderboard_bullseye_modes_v1'):revision===3?'arcade_live_verified_leaderboard_v3':revision===2?'arcade_live_verified_leaderboard_v2':'arcade_live_verified_leaderboard_v1'),{
      method:'POST',redirect:'error',cache:'no-store',signal:AbortSignal.timeout(8000),
      headers:{apikey:secret,'content-type':'application/json',accept:'application/json'},
      body:JSON.stringify({p_game_id:silhouette?'silhouette-precision':zombie?'zombie-outbreak':'bullseye-classic',p_mode_id:mode,p_scoring_revision:revision}),
    });
    if(!upstream.ok)return answer(503,{error:'verified_rankings_unavailable'});
    const raw=await upstream.text();
    if(raw.length>30000)throw Error('oversized_upstream');
    const data=JSON.parse(raw);
    if(data?.version!==1||data.gameId!==(silhouette?'silhouette-precision':zombie?'zombie-outbreak':'bullseye-classic')||data.modeId!==mode||
      data.scoringRevision!==revision||!Array.isArray(data.rows)||data.rows.length>50)
      throw Error('invalid_upstream_shape');
    const seen=new Set();
    const validated=data.rows.map((row,i)=>{
      const safe=silhouette?(validSilhouetteRankRow(row,i+1,mode)?{rank:row.rank,nickname:row.nickname,score:row.score,timeMs:row.timeMs,tenPointHits:row.tenPointHits,centerChestHits:row.centerChestHits}:(()=>{throw Error('invalid_silhouette_row')})()):zombie?(validZombieRankRow(row,i+1)?{rank:row.rank,nickname:row.nickname,score:row.score,timeMs:row.timeMs}:(()=>{throw Error('invalid_zombie_row')})()):publicRow(row,i+1,mode,revision);
      if(seen.has(safe.nickname.toLowerCase()))throw Error('duplicate_nickname');
      seen.add(safe.nickname.toLowerCase());
      return safe;
    });
    const current=now();
    if(!(current instanceof Date)||!Number.isFinite(current.getTime()))throw Error('invalid_clock');
    return answer(200,{
      schemaVersion:1,verified:true,gameId:silhouette?'silhouette-precision':zombie?'zombie-outbreak':'bullseye-classic',modeId:mode,
      scoringRevision:revision,generatedAtUtc:current.toISOString(),
      rankingOrder:silhouette?['score_desc','ten_point_hits_desc','center_chest_hits_desc','time_asc']:zombie?['score_desc','qualified_headshots_desc','time_asc'] : mode==='perfect-100'?(revision===2?['score_desc','shots_asc','time_asc']:['shots_asc','time_asc','center_hits_desc']):
       isExtraMode(mode,revision)?(revision===2?['score_desc','raw_points_desc','center_hits_desc','grouping_asc','shots_asc']:['score_desc','center_hits_desc','shots_asc']):
       revision>=2?['score_desc','raw_points_desc','center_hits_desc','time_asc','grouping_asc']:
        ['score_desc','raw_points_desc','center_hits_desc','grouping_asc','time_asc'],
      rows:validated.slice(0,limit),
    });
  }catch{return answer(503,{error:'verified_rankings_unavailable'});}
}
export default function handler(req){return handleVerifiedLeaderboard(req);}
