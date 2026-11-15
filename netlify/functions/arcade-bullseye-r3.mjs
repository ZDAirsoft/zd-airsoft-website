/** Ten-shot Revision 3: signed longest center streak and 300-point total. */
import {r2Speed,r2Grouping} from './arcade-bullseye-r2.mjs';
const int=(x,min,max)=>Number.isSafeInteger(x)&&x>=min&&x<=max;
export const r3Speed=(ms)=>{const n=r2Speed(ms);return n===null?null:Math.floor((n*85+50)/100);};
export const r3Group=(radius,main)=>{const n=r2Grouping(radius,main);return n===null?null:Math.floor((n*85+50)/100);};
export const r3Streak=(st)=>!int(st,0,10)?null:st<=1?0:Math.floor((30*(st-1)+4)/9);
export function plausibleStreak(center,st){
 return int(center,0,10)&&int(st,0,10)&&st<=center&&
   (center===0?st===0:st>=Math.floor(10/(11-center)));
}
export function validR3Score(q,score,normalized=false){
 if(!q||typeof q!=='object'||Array.isArray(q))return false;
 const expected=['raw_points','shots','main_target_hits','center_hits','time_ms',
   'speed_bonus','group_bonus',normalized?'longest_streak':'st'];
 const allowed=[...expected,normalized?'group_mean_x100':'gm'];
 if(Object.keys(q).some(x=>!allowed.includes(x))||expected.some(k=>!Object.hasOwn(q,k)))return false;
 const {raw_points:raw,shots,main_target_hits:main,center_hits:center,time_ms:ms,
   speed_bonus:speed,group_bonus:group}=q;
 const radius=normalized?q.group_mean_x100:q.gm;
 const streak=normalized?q.longest_streak:q.st;
 if(!int(raw,0,100)||shots!==10||!int(main,0,10)||!int(center,0,main)||
    raw<center*10||!int(ms,0,600000)||!int(speed,0,85)||!int(group,0,85)||
    !plausibleStreak(center,streak)||!int(score,0,300))return false;
 if(main===10&&!int(radius,0,100000))return false;
 if(radius!==undefined&&(!int(radius,0,100000)||main!==10))return false;
 return r3Speed(ms)===speed&&r3Group(radius,main)===group&&
    score===raw+speed+group+r3Streak(streak);
}
