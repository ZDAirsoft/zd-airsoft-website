/** Bullseye competition mode gates and integer scoring formulae.
 * Revision 1 remains immutable. Revision 2 adds quality-weighted, signed Timed
 * grouping and Perfect 100 efficiency + winning-center grouping.
 * CBOR remains unsigned only: a negative signed grouping is carried as gp
 * (positive penalty) and normalized into group_bonus < 0 by the server.
 */
const int=(x,min,max)=>Number.isSafeInteger(x)&&x>=min&&x<=max;
export const EXTRA_MODES=Object.freeze(['timed-10','timed-20','timed-30','perfect-100']);
export const supportedBullseye=(mode,revision)=>mode==='ten-shot'?revision===1||revision===2||revision===3:
 EXTRA_MODES.includes(mode)&&(revision===1||revision===2);
export const isExtraMode=(mode,rev)=>EXTRA_MODES.includes(mode)&&(rev===1||rev===2);
export const timedSeconds=(mode)=>mode==='timed-10'?10:mode==='timed-20'?20:mode==='timed-30'?30:0;
export function timedGroupAdjustment(raw,shots,radius){
 if(!int(shots,1,512)||!int(raw,0,5120)||raw>shots*10||!int(radius,0,100000))return null;
 if(raw===0)return 0;
 const accuracy=Math.min(100,Math.floor((raw*10+Math.floor(shots/2))/shots));
 const tightness=radius>=7000?0:Math.floor(((7000-radius)*100+3500)/7000);
 const grade=Math.floor((2*accuracy+tightness+1)/3);
 const percent=Math.max(-75,Math.min(50,(grade-75)*2));
 return percent<0?-Math.floor((raw*(-percent)+50)/100):Math.floor((raw*percent+50)/100);
}
export const perfectEfficiency=(shots)=>int(shots,10,512)?Math.max(0,100-(shots-10)*10):null;
export const perfectGrouping=(radius)=>!int(radius,0,100000)?null:
 radius>=3500?0:Math.floor(((3500-radius)*100+1750)/3500);
/** Accept raw CBOR metrics (gm / optional gp) or normalized SQL metrics
 * (group_mean_x100 and signed group_bonus) with the caller-specified shape. */
export function validBullseyeExtra(mode,revision,metrics,score,normalized=false){
 if(!isExtraMode(mode,revision)||!metrics||typeof metrics!=='object'||Array.isArray(metrics))return false;
 const keys=Object.keys(metrics).sort().join(',');
 const common=['raw_points','shots','main_target_hits','center_hits','time_ms','speed_bonus','group_bonus'];
 const allowed=revision===1?common:normalized?[...common,'group_mean_x100']:
   [...common,'gm',...(Object.hasOwn(metrics,'gp')?['gp']:[])];
 if(keys!==allowed.sort().join(','))return false;
 const {raw_points:raw,shots,main_target_hits:main,center_hits:center,time_ms:time,
   speed_bonus:speed,group_bonus:group}=metrics;
 if(!int(shots,1,512)||!int(main,0,shots)||!int(center,0,main)||
  !int(raw,0,5120)||raw<center*10||raw>main*10||!int(time,0,3600000))return false;
 if(revision===1){
   if(!int(score,0,5120)||speed!==0||group!==0)return false;
   if(mode==='perfect-100')return score===100&&shots>=10&&center>=10;
   return time===timedSeconds(mode)*1000&&score===raw;
 }
 const radius=normalized?metrics.group_mean_x100:metrics.gm;
 if(!int(radius,0,100000)||!int(speed,0,200)||!int(score,0,7680))return false;
 let signedGroup;
 if(normalized){if(!int(group,-3840,2560))return false;signedGroup=group;}
 else {
   if(!int(group,0,2560)||!(metrics.gp===undefined||int(metrics.gp,1,3840))||
      (metrics.gp!==undefined&&group!==0))return false;
   signedGroup=group-(metrics.gp||0);
 }
 if(mode==='perfect-100'){
   const efficiency=perfectEfficiency(shots),bonus=perfectGrouping(radius);
   return shots>=10&&center>=10&&metrics.gp===undefined&&signedGroup===bonus&&
      speed===efficiency&&score===100+efficiency+bonus;
 }
 return time===timedSeconds(mode)*1000&&speed===0&&
   signedGroup===timedGroupAdjustment(raw,shots,radius)&&score===raw+signedGroup;
}
