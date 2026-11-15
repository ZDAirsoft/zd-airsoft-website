/** Deterministic r2 300-point scoring; integer and replay-safe. */
export const R2_REVISION=2;
export function r2Speed(ms){
 if(!Number.isSafeInteger(ms)||ms<0||ms>600000)return null;
 return ms<=3000?100:ms>=15000?0:Math.floor(((15000-ms)*100+6000)/12000);
}
export function r2Grouping(radius,main){
 if(!Number.isSafeInteger(main)||main<0||main>10)return null;
 if(radius===undefined||radius===null)return main<10?0:null;
 if(!Number.isSafeInteger(radius)||radius<0||radius>100000||main!==10)return null;
 return radius>=3500?0:Math.floor(((3500-radius)*100+1750)/3500);
}
export function validR2Score(q,score){
 if(!q||typeof q!=='object'||Array.isArray(q)||Object.keys(q).some(x=>
 !['raw_points','shots','main_target_hits','center_hits','time_ms','speed_bonus','group_bonus','group_mean_x100','gm'].includes(x)))return false;
 const {raw_points:raw,shots,main_target_hits:main,center_hits:center,time_ms:time,
 speed_bonus:speed,group_bonus:group,group_mean_x100:radius}=q;
 if(!Number.isInteger(raw)||raw<0||raw>100||shots!==10||!Number.isInteger(main)||main<0||main>10||
 !Number.isInteger(center)||center<0||center>main||raw<center*10||
 !Number.isInteger(speed)||!Number.isInteger(group)||speed<0||speed>100||group<0||group>100||
 !Number.isInteger(score)||score<0||score>300)return false;
 if(radius!==undefined && q.gm!==undefined)return false;
 const computedGroup=r2Grouping(q.gm===undefined?radius:q.gm,main);
 return r2Speed(time)===speed&&computedGroup===group&&score===raw+speed+group;
}
