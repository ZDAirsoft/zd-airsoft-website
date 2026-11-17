/** Authenticated private signed-score history. No public reads or arbitrary profile IDs.
 * The user's Supabase JWT is validated with Supabase Auth before querying a
 * server-only, ownership-checked SQL function. Does not change rankings.
 */
export const config={path:'/arcade/api/my-verified-scores'};
const HEADERS={'content-type':'application/json; charset=utf-8','cache-control':'private, no-store',
  pragma:'no-cache','x-content-type-options':'nosniff'};
const answer=(status,value)=>new Response(JSON.stringify(value),{status,headers:HEADERS});
const uuid=/^[a-f0-9]{8}-[a-f0-9]{4}-[1-8][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i;
const jwtPattern=/^Bearer ([A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)$/;
function origin(value){try{const u=new URL(value);return u.protocol==='https:'&&!u.port&&!u.username&&!u.password&&
  u.pathname==='/'&&!u.search&&!u.hash&&/^[a-z0-9-]+\.supabase\.co$/.test(u.hostname)?u.origin:null;}catch{return null;}}
const isObject=(v)=>v&&typeof v==='object'&&!Array.isArray(v);
const integer=(v,min,max)=>Number.isSafeInteger(v)&&v>=min&&v<=max;
function safeReport(doc){
  if(!isObject(doc)||doc.version!==1||doc.maxRecent!==50||!Array.isArray(doc.recent)||
    !Array.isArray(doc.personalBests)||!Array.isArray(doc.lifetimeByMode)||
    doc.recent.length>50||doc.personalBests.length>50||doc.lifetimeByMode.length>50)throw Error('shape');
  const silhouette=(r)=>isObject(r)&&r.gameId==='silhouette-precision'&&r.scoringRevision===1&&
    ['standard-10','standard-20','standard-30','timed-10','timed-20','timed-30','precision-10','precision-20','precision-30'].includes(r.modeId);
  const silhouetteMetrics=(r,withImpacts)=>integer(r.score,0,1000000)&&
    integer(r.timeMs,0,86400000)&&integer(r.tenPointHits,0,100000)&&
    integer(r.centerHits,0,r.tenPointHits)&&
    (!withImpacts||integer(r.registeredImpacts,1,100000));
  const zombie=(r)=>isObject(r)&&r.gameId==='zombie-outbreak'&&r.modeId==='campaign'&&r.scoringRevision===1;
  const zombieMetrics=(r)=>integer(r.kills,50,50)&&integer(r.targetHits,50,10000)&&
    integer(r.qualifiedHeadshots,0,r.targetHits)&&integer(r.highestScene,5,5)&&
    integer(r.scenesCleared,5,5)&&r.completed===1&&integer(r.timeMs,1,3600000)&&
    r.score===25*r.targetHits+150*r.qualifiedHeadshots+75*r.kills;
  const legitMode=(r)=>isObject(r)&&r.gameId==='bullseye-classic'&&(
    (r.modeId==='ten-shot'&&[1,2,3].includes(r.scoringRevision))||
    (['timed-10','timed-20','timed-30','perfect-100'].includes(r.modeId)&&[1,2].includes(r.scoringRevision)));
  const scoreMax=(r)=>r.modeId==='ten-shot'?(r.scoringRevision>=2?300:125):r.modeId==='perfect-100'?(r.scoringRevision===2?300:100):(r.scoringRevision===2?7680:5120);
  const rawMax=(r)=>r.modeId==='ten-shot'?100:5120;
  const impactsMax=(r)=>r.modeId==='ten-shot'?10:512;
  const timeMax=(r)=>r.modeId==='ten-shot'?600000:3600000;
  const recent=doc.recent.map(r=>{
    if(silhouette(r)){
      if(!silhouetteMetrics(r,true)||!integer(r.eventId,1,999999)||
        typeof r.claimedAt!=='string'||!Number.isFinite(Date.parse(r.claimedAt)))throw Error('silhouette_recent');
      return {gameId:r.gameId,modeId:r.modeId,scoringRevision:1,score:r.score,eventId:r.eventId,
        claimedAt:r.claimedAt,registeredImpacts:r.registeredImpacts,timeMs:r.timeMs,
        tenPointHits:r.tenPointHits,centerHits:r.centerHits};
    }
    if(zombie(r)){
      if(!integer(r.eventId,1,999999)||typeof r.claimedAt!=='string'||!Number.isFinite(Date.parse(r.claimedAt))||
        !integer(r.score,0,1000000)||!integer(r.registeredImpacts,1,10000)||
        r.targetHits>r.registeredImpacts||!zombieMetrics(r))throw Error('zombie_recent');
      return {gameId:r.gameId,modeId:r.modeId,scoringRevision:1,score:r.score,eventId:r.eventId,claimedAt:r.claimedAt,
        registeredImpacts:r.registeredImpacts,timeMs:r.timeMs,kills:r.kills,targetHits:r.targetHits,
        qualifiedHeadshots:r.qualifiedHeadshots,highestScene:r.highestScene,scenesCleared:r.scenesCleared,completed:r.completed};
    }
    if(!legitMode(r)||!integer(r.score,0,scoreMax(r))||!integer(r.eventId,1,999999)||
      typeof r.claimedAt!=='string'||!Number.isFinite(Date.parse(r.claimedAt))||
      !integer(r.rawPoints,0,rawMax(r))||!integer(r.registeredImpacts,1,impactsMax(r))||
      !integer(r.centerHits,0,r.registeredImpacts)||!integer(r.timeMs,0,timeMax(r))||
      (r.modeId!=='ten-shot'?(r.scoringRevision===1?(r.groupingBonus!==0||r.speedBonus!==0):
        (r.modeId==='perfect-100'?!integer(r.groupingBonus,0,100)||!integer(r.speedBonus,0,100):
          !integer(r.groupingBonus,-3840,2560)||r.speedBonus!==0)):
        r.scoringRevision===1?(![0,5,10].includes(r.groupingBonus)||![0,5,10,15].includes(r.speedBonus)):
        (!integer(r.groupingBonus,0,r.scoringRevision===3?85:100)||!integer(r.speedBonus,0,r.scoringRevision===3?85:100))))throw Error('recent');
    return {gameId:r.gameId,modeId:r.modeId,scoringRevision:r.scoringRevision,score:r.score,eventId:r.eventId,claimedAt:r.claimedAt,
      rawPoints:r.rawPoints,registeredImpacts:r.registeredImpacts,centerHits:r.centerHits,
      timeMs:r.timeMs,groupingBonus:r.groupingBonus,speedBonus:r.speedBonus};
  });
  const personalBests=doc.personalBests.map(r=>{
    if(silhouette(r)){
      if(!silhouetteMetrics(r,false)||typeof r.achievedAt!=='string'||!Number.isFinite(Date.parse(r.achievedAt)))
        throw Error('silhouette_best');
      return {gameId:r.gameId,modeId:r.modeId,scoringRevision:1,score:r.score,achievedAt:r.achievedAt,
        timeMs:r.timeMs,tenPointHits:r.tenPointHits,centerHits:r.centerHits};
    }
    if(zombie(r)){
      if(!integer(r.score,0,1000000)||typeof r.achievedAt!=='string'||!Number.isFinite(Date.parse(r.achievedAt))||
        !zombieMetrics(r))throw Error('zombie_best');
      return {gameId:r.gameId,modeId:r.modeId,scoringRevision:1,score:r.score,achievedAt:r.achievedAt,
        timeMs:r.timeMs,kills:r.kills,targetHits:r.targetHits,qualifiedHeadshots:r.qualifiedHeadshots,
        highestScene:r.highestScene,scenesCleared:r.scenesCleared,completed:r.completed};
    }
    if(!legitMode(r)||!integer(r.score,0,scoreMax(r))||typeof r.hiddenFromPublic!=='boolean'||
      !Number.isFinite(Date.parse(r.achievedAt))||!integer(r.rawPoints,0,rawMax(r))||
      !integer(r.centerHits,0,impactsMax(r))||!integer(r.timeMs,0,timeMax(r)))throw Error('bests');
    return {gameId:r.gameId,modeId:r.modeId,scoringRevision:r.scoringRevision,score:r.score,achievedAt:r.achievedAt,
      rawPoints:r.rawPoints,centerHits:r.centerHits,timeMs:r.timeMs};
  });
  const lifetimeByMode=doc.lifetimeByMode.map(r=>{
    if(silhouette(r)){
      if(!integer(r.attempts,0,Number.MAX_SAFE_INTEGER)||!integer(r.totalScore,0,Number.MAX_SAFE_INTEGER)||
        !integer(r.totalRawPoints,0,Number.MAX_SAFE_INTEGER)||!integer(r.registeredImpacts,0,Number.MAX_SAFE_INTEGER)||
        !integer(r.centerHits,0,Number.MAX_SAFE_INTEGER))throw Error('silhouette_lifetime');
      return {gameId:r.gameId,modeId:r.modeId,scoringRevision:1,attempts:r.attempts,totalScore:r.totalScore,
        totalRawPoints:r.totalRawPoints,registeredImpacts:r.registeredImpacts,centerHits:r.centerHits};
    }
    if(zombie(r)){
      if(!integer(r.attempts,0,Number.MAX_SAFE_INTEGER)||!integer(r.totalScore,0,Number.MAX_SAFE_INTEGER)||
        !integer(r.totalRawPoints,0,Number.MAX_SAFE_INTEGER)||
        !integer(r.registeredImpacts,0,Number.MAX_SAFE_INTEGER)||
        !integer(r.centerHits,0,Number.MAX_SAFE_INTEGER))throw Error('zombie_lifetime');
      return {gameId:r.gameId,modeId:r.modeId,scoringRevision:1,attempts:r.attempts,totalScore:r.totalScore,
        totalRawPoints:r.totalRawPoints,registeredImpacts:r.registeredImpacts,centerHits:r.centerHits};
    }
    if(!legitMode(r)||!integer(r.attempts,0,Number.MAX_SAFE_INTEGER)||
      !integer(r.totalScore,0,Number.MAX_SAFE_INTEGER)||!integer(r.totalRawPoints,0,Number.MAX_SAFE_INTEGER)||
      !integer(r.registeredImpacts,0,Number.MAX_SAFE_INTEGER)||!integer(r.centerHits,0,Number.MAX_SAFE_INTEGER))throw Error('lifetime');
    return {gameId:r.gameId,modeId:r.modeId,scoringRevision:r.scoringRevision,attempts:r.attempts,
      totalScore:r.totalScore,totalRawPoints:r.totalRawPoints,
      registeredImpacts:r.registeredImpacts,centerHits:r.centerHits};
  });
  return {schemaVersion:1,maxRecent:50,recent,personalBests,lifetimeByMode};
}
export async function handleMyVerifiedScores(req,env=process.env,fetcher=fetch){
  if(req.method!=='GET')return answer(405,{error:'method_not_allowed'});
  const token=(req.headers.get('authorization')||'').match(jwtPattern)?.[1];
  if(!token)return answer(401,{error:'authentication_required'});
  const project=origin(env.SUPABASE_URL),pk=env.SUPABASE_PUBLISHABLE_KEY,sk=env.SUPABASE_SECRET_KEY;
  if(!project||!/^sb_publishable_[A-Za-z0-9_-]{12,}$/.test(pk||'')||
    !/^sb_secret_[A-Za-z0-9_-]{12,}$/.test(sk||''))return answer(503,{error:'service_not_configured'});
  try{
    const load=async(path,apikey,method='GET',value)=>{
      const res=await fetcher(project+path,{method,cache:'no-store',redirect:'error',
        signal:AbortSignal.timeout(8000),headers:{apikey,'content-type':'application/json',accept:'application/json',
          ...(path==='/auth/v1/user'?{authorization:'Bearer '+token}:{})},
        ...(method==='POST'?{body:JSON.stringify(value)}:{})});
      const raw=await res.text();if(raw.length>30000)throw Error('large_result');
      return {ok:res.ok,status:res.status,json:JSON.parse(raw)};
    };
    const auth=await load('/auth/v1/user',pk);
    if(!auth.ok||!uuid.test(auth.json?.id))return answer(401,{error:'invalid_session'});
    const result=await load('/rest/v1/rpc/arcade_live_my_verified_scorecard_v3',sk,'POST',{
      p_auth_user_id:auth.json.id,
    });
    if(!result.ok)return answer(result.status===403?403:503,{error:'private_history_unavailable'});
    return answer(200,safeReport(result.json));
  }catch{return answer(503,{error:'private_history_unavailable'});}
}
export default function handler(req){return handleMyVerifiedScores(req);}
