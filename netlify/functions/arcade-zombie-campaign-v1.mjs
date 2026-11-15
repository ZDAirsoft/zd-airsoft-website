/** Zombie Outbreak Campaign Revision 1: strictly validated victory-only signed receipt. */
const int=(v,min,max)=>Number.isSafeInteger(v)&&v>=min&&v<=max;
const ALIASES=['sh','hit','hd','ki','sc','cl','ms'];
export function validZombieCampaignV1(receipt) {
  if(!receipt||receipt.g!=='zombie-outbreak'||receipt.m!=='campaign'||receipt.rv!==1 ||
     !int(receipt.s,0,1000000)||!receipt.q||typeof receipt.q!=='object'||Array.isArray(receipt.q))return false;
  const q=receipt.q;
  if(Object.keys(q).length!==ALIASES.length||ALIASES.some(k=>!Object.hasOwn(q,k)))return false;
  if(!int(q.sh,50,100000)||!int(q.hit,50,q.sh)||!int(q.hd,0,q.hit)||
     q.ki!==50||q.sc!==5||q.cl!==5||!int(q.ms,1000,86400000))return false;
  return receipt.s===q.hit*25+q.hd*150+q.ki*75;
}
export function normalizedZombieMetrics(q) {
  return { shots:q.sh,target_hits:q.hit,qualified_headshots:q.hd,kills:q.ki,
    highest_scene:q.sc,scenes_cleared:q.cl,time_ms:q.ms,completed:1 };
}
export function validZombieRankRow(row,rank) {
  return !!row&&row.rank===rank&&typeof row.nickname==='string'&&
   /^[A-Za-z0-9][A-Za-z0-9 -]{1,15}$/.test(row.nickname)&&
   int(row.score,0,1000000)&&int(row.timeMs,1000,86400000);
}
