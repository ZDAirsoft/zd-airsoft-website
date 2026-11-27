/** Silhouette Precision Revision 1: public leaderboard shape and source scoring invariants.
 * Preparation stage only: no receipt/claim authorization or database RPC is deployed here.
 */
export const SILHOUETTE_MODES=Object.freeze([
  'standard-10','standard-20','standard-30',
  'timed-10','timed-20','timed-30',
  'precision-10','precision-20','precision-30',
]);
const modes=new Set(SILHOUETTE_MODES);
export const silhouetteMode=(id)=>typeof id==='string'&&modes.has(id);
const integer=(n,lo,hi)=>Number.isSafeInteger(n)&&n>=lo&&n<=hi;
export function validSilhouetteMetrics(mode,score,m){
  if(!silhouetteMode(mode)||!integer(score,0,1000000)||!m||typeof m!=='object'||Array.isArray(m))return false;
  const expected=['shots','hits','ten_point_hits','center_chest_hits','time_ms','bucket0','bucket5','bucket8','bucket9','bucket10'];
  if(Object.keys(m).length!==expected.length || expected.some(k=>!Object.hasOwn(m,k)))return false;
  if(expected.some(k=>!integer(m[k],0,k==='time_ms'?86400000:100000)))return false;
  const n=Number(mode.split('-')[1]),kind=mode.split('-')[0];
  if(kind!=='timed'&&m.shots!==n)return false;
  if(kind==='timed' && (m.shots<1||m.time_ms<n*1000))return false;
  if(kind!=='timed'&&score>10*n)return false;
  const sum=m.bucket0+m.bucket5+m.bucket8+m.bucket9+m.bucket10;
  return sum===m.shots && m.hits===m.shots-m.bucket0 && m.ten_point_hits===m.bucket10 &&
    m.center_chest_hits<=m.ten_point_hits &&
    score===5*m.bucket5+8*m.bucket8+9*m.bucket9+10*m.bucket10 &&
    (kind!=='precision'||(m.bucket5===0&&m.bucket8===0&&m.bucket9===0&&m.center_chest_hits===m.hits));
}
export function validSilhouetteRankRow(row,rank,mode){
  const max=mode.startsWith('timed-')?1000000:10*Number(mode.split('-')[1]);
  return !!row&&row.rank===rank&&typeof row.nickname==='string'&&
    /^[A-Za-z0-9][A-Za-z0-9 -]{1,15}$/.test(row.nickname)&&
    integer(row.score,0,max)&&integer(row.timeMs,0,86400000)&&
    integer(row.tenPointHits,0,100000)&&integer(row.centerChestHits,0,row.tenPointHits);
}

/** Exact proposed compact signed metric map; rejects unknown keys, missing keys and
 * non-integer metric values BEFORE any SQL request. Keep synchronized with the signer. */
export function normalizedSilhouetteMetrics(q){
  if(!q||typeof q!=='object'||Array.isArray(q))return null;
  const keys=['s','h','t','c','m','a','b','d','e','f'];
  if(Object.keys(q).length!==keys.length||keys.some(k=>!Object.hasOwn(q,k)||
      !Number.isSafeInteger(q[k])||q[k]<0))return null;
  return {shots:q.s,hits:q.h,ten_point_hits:q.t,center_chest_hits:q.c,
    time_ms:q.m,bucket0:q.a,bucket5:q.b,bucket8:q.d,bucket9:q.e,bucket10:q.f};
}
export function validSilhouetteReceipt(receipt){
  if(!receipt||receipt.g!=='silhouette-precision'||receipt.rv!==1||
    !silhouetteMode(receipt.m)||!((receipt.e===2&&receipt.d==='01'&&receipt.p===1)||
      (receipt.e===3&&/^[0-9]{2}$/.test(receipt.d||'')&&receipt.d!=='00'&&receipt.p===undefined))||
    !Number.isSafeInteger(receipt.t)||receipt.t<1704067200||receipt.t>4102444800)return false;
  const metrics=normalizedSilhouetteMetrics(receipt.q);
  return metrics!==null&&validSilhouetteMetrics(receipt.m,receipt.s,metrics);
}
