/** Stage 9 Bullseye mode-specific competitive scoring contracts.
 * The 300-point ten-shot score is handled by arcade-bullseye-r2.mjs.
 * No formulas are inferred from unsigned clients. The signed monitor binds mode.
 */
const int=(x,min,max)=>Number.isSafeInteger(x)&&x>=min&&x<=max;
export const EXTRA_MODES=Object.freeze(['timed-10','timed-20','timed-30','perfect-100']);
export const supportedBullseye=(mode,revision)=>mode==='ten-shot'?revision===1||revision===2:
 EXTRA_MODES.includes(mode)&&revision===1;
export const isExtraMode=(mode,rev)=>EXTRA_MODES.includes(mode)&&rev===1;
export const timedSeconds=(mode)=>mode==='timed-10'?10:mode==='timed-20'?20:mode==='timed-30'?30:0;
export function validBullseyeExtra(mode,revision,metrics,score){
 if(!isExtraMode(mode,revision)||!metrics||typeof metrics!=='object'||Array.isArray(metrics)||!int(score,0,5120))return false;
 const keys=Object.keys(metrics).sort();
 if(keys.join(',')!==['raw_points','shots','main_target_hits','center_hits','time_ms','speed_bonus','group_bonus'].sort().join(','))return false;
 const {raw_points:raw,shots,main_target_hits:main,center_hits:center,time_ms:time,
   speed_bonus:speed,group_bonus:group}=metrics;
 if(!int(shots,1,512)||!int(main,0,shots)||!int(center,0,main)||
   !int(raw,0,5120)||raw<center*10||raw>main*10||!int(time,0,3600000)||speed!==0||group!==0)return false;
 if(mode==='perfect-100')return score===100&&shots>=10&&center>=10;
 return time===timedSeconds(mode)*1000&&score===raw;
}
