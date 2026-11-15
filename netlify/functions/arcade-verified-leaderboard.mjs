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
function publicRow(entry,rank) {
  if(!entry||entry.rank!==rank||!nickname(entry.nickname)||
    !integer(entry.score,0,125)||!integer(entry.rawPoints,0,100)||
    !integer(entry.registeredImpacts,10,10)||!integer(entry.centerHits,0,10)||
    !integer(entry.timeMs,0,600000)||
    !integer(entry.groupingBonus,0,10)||![0,5,10].includes(entry.groupingBonus)||
    ![0,5,10,15].includes(entry.speedBonus)||
    !(entry.groupMeanX100===null||integer(entry.groupMeanX100,0,100000))||
    entry.rawPoints < entry.centerHits * 10||
    entry.score!==entry.rawPoints+entry.groupingBonus+entry.speedBonus||
    (entry.groupingBonus>0 && entry.groupMeanX100===null))throw Error('invalid_leaderboard_row');
  return {
    rank, nickname:entry.nickname, score:entry.score,
    timeMs:entry.timeMs,
    centerHits:entry.centerHits,registeredImpacts:entry.registeredImpacts,
    centerHitRatePct:100*entry.centerHits/entry.registeredImpacts,
    rawPoints:entry.rawPoints,groupMeanX100:entry.groupMeanX100,
    groupingBonus:entry.groupingBonus,speedBonus:entry.speedBonus,
  };
}
export const config={path:'/arcade/api/leaderboard-verified'};
export async function handleVerifiedLeaderboard(req,env=process.env,fetcher=fetch,now=()=>new Date()) {
  if(req.method!=='GET')return answer(405,{error:'method_not_allowed'});
  let url;
  try{url=new URL(req.url);}catch{return answer(400,{error:'invalid_request'});}
  const params=url.searchParams;
  if(params.get('game')!=='bullseye-classic'||params.get('mode')!=='ten-shot'||
    (params.has('limit')&&!['3','50'].includes(params.get('limit')))||
    [...params].some(([k,v])=>!['game','mode','limit'].includes(k)&&(!/^utm_[a-z_]{1,30}$/.test(k)||v.length>100)))
    return answer(404,{error:'unknown_verified_leaderboard'});
  const limit=params.get('limit')==='50'?50:3;
  const project=projectOrigin(env.SUPABASE_URL);
  const secret=env.SUPABASE_SECRET_KEY;
  if(!project||typeof secret!=='string'||!/^sb_secret_[A-Za-z0-9_-]{12,}$/.test(secret))
    return answer(503,{error:'service_not_configured'});
  try {
    const upstream=await fetcher(project+'/rest/v1/rpc/arcade_live_verified_leaderboard_v1',{
      method:'POST',redirect:'error',cache:'no-store',signal:AbortSignal.timeout(8000),
      headers:{apikey:secret,'content-type':'application/json',accept:'application/json'},
      body:JSON.stringify({p_game_id:'bullseye-classic',p_mode_id:'ten-shot',p_scoring_revision:1}),
    });
    if(!upstream.ok)return answer(503,{error:'verified_rankings_unavailable'});
    const raw=await upstream.text();
    if(raw.length>30000)throw Error('oversized_upstream');
    const data=JSON.parse(raw);
    if(data?.version!==1||data.gameId!=='bullseye-classic'||data.modeId!=='ten-shot'||
      data.scoringRevision!==1||!Array.isArray(data.rows)||data.rows.length>50)
      throw Error('invalid_upstream_shape');
    const seen=new Set();
    const validated=data.rows.map((row,i)=>{
      const safe=publicRow(row,i+1);
      if(seen.has(safe.nickname.toLowerCase()))throw Error('duplicate_nickname');
      seen.add(safe.nickname.toLowerCase());
      return safe;
    });
    const current=now();
    if(!(current instanceof Date)||!Number.isFinite(current.getTime()))throw Error('invalid_clock');
    return answer(200,{
      schemaVersion:1,verified:true,gameId:'bullseye-classic',modeId:'ten-shot',
      scoringRevision:1,generatedAtUtc:current.toISOString(),
      rankingOrder:['score_desc','raw_points_desc','center_hits_desc','grouping_asc','time_asc'],
      rows:validated.slice(0,limit),
    });
  }catch{return answer(503,{error:'verified_rankings_unavailable'});}
}
export default function handler(req){return handleVerifiedLeaderboard(req);}
