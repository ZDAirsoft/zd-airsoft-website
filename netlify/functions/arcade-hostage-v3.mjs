/** Hostage Rescue rev3 contract, shared with central claim and public rankings.
 * Structural consistency alone does not prove physical shots or natural ten-scene completion.
 */
export const HOSTAGE_MODES=Object.freeze([
 'classic-rescue-easy','classic-rescue-normal','classic-rescue-hard',
 'no-mistakes-easy','no-mistakes-normal','no-mistakes-hard',
 'timed-45s-easy','timed-45s-normal','timed-45s-hard']);
export const HOSTAGE_PUBLIC_BOARDS=Object.freeze(['classic-rescue-hard','timed-45s-hard']);
const integer=(n,min,max)=>Number.isSafeInteger(n)&&n>=min&&n<=max;
export const hostageModeInfo=(mode)=>{
 const idx=HOSTAGE_MODES.indexOf(mode);
 return idx<0?null:{index:idx,difficulty:['easy','normal','hard'][idx%3],
  category:idx<3?'classic':idx<6?'no-mistakes':'timed',shotCap:[100,80,60][idx%3],publicBoard:HOSTAGE_PUBLIC_BOARDS.includes(mode)};
};
export const hostageBoardForScreen=(mode)=>{
 const info=hostageModeInfo(mode);
 return !info||info.category==='no-mistakes'?null:info.category==='classic'?'classic-rescue-hard':'timed-45s-hard';
};
export function normalizeHostageMetrics(q){
 if(!q||typeof q!=='object'||Array.isArray(q)||Object.keys(q).sort().join(',')!=='c,f,h,m,p,s,t,w')return null;
 if(!Object.values(q).every(v=>integer(v,0,86400000)))return null;
 return {shots:q.s,threat_hits:q.h,protected_hits:q.p,misses:q.m,
   correct_holds:q.c,failed_scenes:q.f,time_ms:q.t,wasted_shots:q.w};
}
const halfUp=(num,den)=>Math.floor(num/den+0.5);
export function computeHostageScore(mode,metrics){
 const info=hostageModeInfo(mode);
 if(!info||!metrics)return null;
 const {shots,threat_hits:h,protected_hits:p,misses,correct_holds:c,failed_scenes:f,time_ms:t,wasted_shots:w}=metrics;
 if(![shots,h,p,misses,c,f,t,w].every(v=>integer(v,0,86400000))||shots>info.shotCap||
  h>12||p>info.shotCap||misses>info.shotCap||c>2||f>10||w>misses||
  shots!==h+p+misses|| (info.category==='timed'&&t>45000) ||
  (info.category==='no-mistakes'&&(f!==0||p!==0||
   (info.difficulty==='normal'&&misses>1)||(info.difficulty==='hard'&&misses>0))))return null;
 const effectiveness=halfUp(100*(h+c),14);
 const judgment=Math.max(0,100-40*p);
 const discipline=shots===0?0:halfUp(50*Math.pow(h/shots,3),1);
 const [fast,slow]=info.category==='classic'?[15000,35000]:info.category==='no-mistakes'?[17000,37000]:[20000,45000];
 const pace=t<=fast?50:t>=slow?0:halfUp(50*(slow-t),slow-fast);
 return Math.min(300,effectiveness+judgment+discipline+pace);
}
export function validHostageReceipt(r){
 if(!r||r.g!=='hostage-rescue'||r.rv!==3||!integer(r.s,0,300)||
    !integer(r.t,1,4102444800)||!/^[0-9]{2}$/.test(r.d||'')||r.d==='00'||
    !/^K[A-F0-9]{16}$/.test(r.k||'')||!integer(r.e,1,999999))return false;
 const q=normalizeHostageMetrics(r.q);
 return q!==null&&computeHostageScore(r.m,q)===r.s;
}
export const validHostageRankRow=(r,rank)=>r&&r.rank===rank&&
 /^[A-Za-z0-9][A-Za-z0-9 -]{1,15}$/.test(r.nickname||'')&&
 integer(r.score,0,300)&&integer(r.timeMs,0,86400000);
