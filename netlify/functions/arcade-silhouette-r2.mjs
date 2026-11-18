/** Silhouette Precision scoring Revision 2. Separate, fail-closed from Rev 1.
 * Unity owns the score; this validates a signed summary and only basic bounds.
 * Do not activate while the Timed scoring contract remains provisional.
 */
import {SILHOUETTE_MODES,silhouetteMode} from './arcade-silhouette-r1.mjs';
export {SILHOUETTE_MODES,silhouetteMode};
const uint=(v,lo,hi)=>Number.isSafeInteger(v)&&v>=lo&&v<=hi;
export function normalizeSilhouetteR2Metrics(q){
 if(!q||typeof q!=='object'||Array.isArray(q))return null;
 const keys=['s','h','t','c','m','g'];
 if(Object.keys(q).length!==6||keys.some(k=>!Object.hasOwn(q,k)))return null;
 if(!uint(q.s,0,100000)||!uint(q.h,0,100000)||!uint(q.t,0,100000)||
    !uint(q.c,0,100000)||!uint(q.m,0,86400000)||!uint(q.g,0,1000))return null;
 return {shots:q.s,hits:q.h,ten_point_hits:q.t,center_chest_hits:q.c,
         time_ms:q.m,grouping_rating:q.g};
}
export function validSilhouetteR2Metrics(mode,score,m){
 if(!silhouetteMode(mode)||!uint(score,0,300)||!m)return false;
 const n=Number(mode.split('-')[1]);
 if(!(m.center_chest_hits<=m.ten_point_hits&&m.ten_point_hits<=m.hits&&m.hits<=m.shots))return false;
 if(mode.startsWith('timed-')){
   if(m.shots<1||m.time_ms<n*1000)return false;
 }else if(m.shots!==n)return false;
 // Precision Rev2 counts BOTH head core and center chest as 10-point precision hits.
 if(mode.startsWith('precision-')&&m.hits!==m.ten_point_hits)return false;
 if(m.hits===0&&(score!==0||m.grouping_rating!==0))return false;
 return true;
}
export function validSilhouetteR2Receipt(r){
 if(!r||r.g!=='silhouette-precision'||r.rv!==2||!silhouetteMode(r.m)||
    !Number.isSafeInteger(r.e)||r.e!==2||r.d!=='01'||r.p!==1||
    !uint(r.t,1704067200,4102444800))return false;
 return validSilhouetteR2Metrics(r.m,r.s,normalizeSilhouetteR2Metrics(r.q));
}
export function validSilhouetteR2RankRow(row,rank){
 return !!row&&row.rank===rank&&typeof row.nickname==='string'&&
 /^[A-Za-z0-9][A-Za-z0-9 -]{1,15}$/.test(row.nickname)&&
 uint(row.score,0,300)&&uint(row.timeMs,0,86400000)&&
 uint(row.tenPointHits,0,100000)&&uint(row.centerChestHits,0,row.tenPointHits)&&
 uint(row.groupingRating,0,1000);
}
