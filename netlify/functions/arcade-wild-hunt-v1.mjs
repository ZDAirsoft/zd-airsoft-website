/** Wild Hunt R1: signed completed victories in all three modes; Hard public only. */
export const WILD_HUNT_METRIC_KEYS=Object.freeze(['imp','hit','vital','pro','miss','stage','win','time','har','cov','base','sq']);
const int=(v,lo,hi)=>Number.isSafeInteger(v)&&v>=lo&&v<=hi;
const MODES=new Set(['easy','medium','hard']);
export function validWildHuntReceipt(r) {
 if(!r||r.g!=='wild-hunt'||r.rv!==1||!MODES.has(r.m)||
    !int(r.s,0,r.m==='hard'?100000:2147483647)||!r.q||
    typeof r.q!=='object'||Array.isArray(r.q))return false;
 const q=r.q,keys=Object.keys(q);
 if(keys.length!==12||keys.some(k=>!WILD_HUNT_METRIC_KEYS.includes(k))||
    WILD_HUNT_METRIC_KEYS.some(k=>!int(q[k],0,2147483647)))return false;
 const goal=r.m==='hard'?50:25,cap=r.m==='easy'?250:r.m==='medium'?125:100;
 return q.win===1&&q.stage===5&&q.har===goal&&int(q.imp,goal,cap)&&
 q.hit<=q.imp&&q.vital<=q.hit&&q.har<=q.hit&&
 q.imp===q.hit+q.miss+q.cov+q.pro&&
 (r.m!=='hard'||(q.base<=56700&&q.sq<=42578))&&
 r.s===q.base+q.sq-150*q.pro&&
 (r.m!=='hard'||(q.imp>=50&&q.imp<=100&&q.hit>=50&&q.har===50));
}
/** Preserve the exact 12 signed keys as canonical database metric names. */
export function normalizeWildHuntMetrics(q){
 const m={};for(const key of WILD_HUNT_METRIC_KEYS)m[key]=q[key];return m;
}
export const wildHuntPublicBoard=(game,mode,revision)=>game==='wild-hunt'&&mode==='hard'&&revision===1;
export function validWildHuntRankRow(row,position,previousRow) {
 if(!row||!int(row.rank,1,50)||!int(row.score,0,100000)||
    typeof row.nickname!=='string'||!/^[A-Za-z0-9][A-Za-z0-9 -]{1,15}$/.test(row.nickname))return false;
 if(position===0)return row.rank===1;
 if(!previousRow||row.score>previousRow.score)return false;
 return row.rank===(row.score===previousRow.score?previousRow.rank:position+1);
}
