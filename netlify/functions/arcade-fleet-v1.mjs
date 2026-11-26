import { createPublicKey, createHash, verify as verifySignature } from 'node:crypto';

/** Restricted fleet identity pairing. Does not sign scores or activate claims.
 * Existing score receipts use the original sign_round_v1/zda1 infrastructure.
 * Feature OFF unless ARCADE_FLEET_ENROLLMENT_V1 === 'true'.
 */
const domain=Buffer.from('ZDAIRSOFT_FLEET_ENROLL_V1\0','utf8');
const KEY=/^K[0-9A-F]{16}$/;
const HEX=/^[0-9a-f]+$/;
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const headers={'content-type':'application/json; charset=utf-8','cache-control':'no-store','x-content-type-options':'nosniff'};
const answer=(status,data)=>new Response(JSON.stringify(data),{status,headers});
const error=(status,code)=>answer(status,{ok:false,code});
function projectOrigin(raw){try{const u=new URL(raw);return u.protocol==='https:'&&!u.port&&!u.username&&!u.password&&u.pathname==='/'&&!u.search&&!u.hash&&/^[a-z0-9-]+\.supabase\.co$/.test(u.hostname)?u.origin:null}catch{return null}}
function hex(s,min,max){return typeof s==='string'&&s.length>=min&&s.length<=max&&s.length%2===0&&HEX.test(s)}
export function verifyFleetEnrollmentProof(body,challenge){
  if(!body||!challenge||!KEY.test(body.keyId)||!UUID.test(body.challengeId)||
    !hex(body.publicKeyHex,140,320)||!hex(body.signatureHex,120,160)||
    challenge.keyId!==body.keyId||challenge.challengeId!==body.challengeId||
    !hex(challenge.nonceHex,64,64))return false;
  try{
    const spki=Buffer.from(body.publicKeyHex,'hex');
    const key=createPublicKey({key:spki,format:'der',type:'spki'});
    if(key.asymmetricKeyType!=='ec'||key.asymmetricKeyDetails?.namedCurve!=='prime256v1')return false;
    const keyId='K'+createHash('sha256').update(spki).digest('hex').slice(0,16).toUpperCase();
    if(keyId!==body.keyId)return false;
    // Android SHA256withECDSA returns DER. Never use the existing score-signing domain.
    const message=Buffer.concat([domain,Buffer.from(body.challengeId+':'+challenge.nonceHex+':'+body.keyId,'ascii')]);
    return verifySignature('sha256',message,{key,dsaEncoding:'der'},Buffer.from(body.signatureHex,'hex'));
  }catch{return false}
}
export const config={path:'/arcade/api/fleet-v1'};
export async function handleFleetV1(request,env=process.env,fetcher=fetch){
  if(request.method!=='POST')return error(405,'method_not_allowed');
  if(env.ARCADE_FLEET_ENROLLMENT_V1!=='true')return error(503,'fleet_enrollment_disabled');
  const base=projectOrigin(env.SUPABASE_URL),secret=env.SUPABASE_SECRET_KEY,pub=env.SUPABASE_PUBLISHABLE_KEY;
  if(!base||typeof secret!=='string'||!/^sb_secret_[A-Za-z0-9_-]{12,}$/.test(secret)||
     typeof pub!=='string'||!/^sb_publishable_[A-Za-z0-9_-]{12,}$/.test(pub))return error(503,'service_not_configured');
  let body;
  try{if(Number(request.headers.get('content-length')||0)>2048)return error(413,'oversized');
      const raw=await request.text();if(raw.length>2048)return error(413,'oversized');
      body=JSON.parse(raw);}catch{return error(400,'invalid_json')}
  if(!body||typeof body!=='object'||Array.isArray(body)||typeof body.action!=='string')return error(400,'invalid_request');
  const rpc=async(name,payload)=>{
    const r=await fetcher(base+'/rest/v1/rpc/'+name,{method:'POST',cache:'no-store',redirect:'error',
      headers:{apikey:secret,'content-type':'application/json',accept:'application/json'},
      body:JSON.stringify(payload),signal:AbortSignal.timeout(8000)});
    if(!r.ok)throw Error('rpc_unavailable');
    const t=await r.text();if(t.length>12000)throw Error('rpc_oversize');return JSON.parse(t);
  };
  try{
    if(['challenge','prove','status'].includes(body.action)){
      if(!KEY.test(body.keyId))return error(422,'invalid_key_id');
      if(body.action==='challenge'){
        if(Object.keys(body).sort().join(',')!=='action,keyId')return error(400,'invalid_fields');
        const out=await rpc('arcade_fleet_begin_challenge_v1',{p_key_id:body.keyId});
        return answer(200,{ok:true,...out});
      }
      if(body.action==='status'){
        if(Object.keys(body).sort().join(',')!=='action,keyId')return error(400,'invalid_fields');
        const out=await rpc('arcade_fleet_status_v1',{p_key_id:body.keyId});
        return answer(200,{ok:true,...out});
      }
      if(Object.keys(body).sort().join(',')!=='action,challengeId,keyId,publicKeyHex,signatureHex'||
        !UUID.test(body.challengeId)||!hex(body.publicKeyHex,140,320)||!hex(body.signatureHex,120,160))
        return error(422,'invalid_proof_fields');
      const challenge=await rpc('arcade_fleet_challenge_check_v1',{p_challenge_id:body.challengeId,p_key_id:body.keyId});
      if(!verifyFleetEnrollmentProof(body,challenge))return error(422,'invalid_proof');
      const out=await rpc('arcade_fleet_record_proof_v1',{p_challenge_id:body.challengeId,p_key_id:body.keyId,p_public_spki_hex:body.publicKeyHex});
      // Z&D owns five private monitors. Successful cryptographic proof is sufficient
      // for automatic admission while the five-station capacity has room.
      // Server-only RPC assigns 01..05, enforces capacity and preserves revocations.
      const admission=await rpc('arcade_fleet_autoadmit_v1',{p_key_id:body.keyId});
      return answer(200,{ok:true,...admission});
    }
    if(!['pending','approve','revoke'].includes(body.action))return error(400,'unknown_action');
    if(body.action==='pending'&&Object.keys(body).sort().join(',')!=='action')return error(400,'invalid_fields');
    if(body.action!=='pending'&&(Object.keys(body).sort().join(',')!=='action,keyId'||!KEY.test(body.keyId)))return error(400,'invalid_fields');
    const jwt=(request.headers.get('authorization')||'').match(/^Bearer ([A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)$/)?.[1];
    if(!jwt)return error(401,'authentication_required');
    const auth=await fetcher(base+'/auth/v1/user',{method:'GET',redirect:'error',cache:'no-store',
      headers:{apikey:pub,authorization:'Bearer '+jwt},signal:AbortSignal.timeout(8000)});
    if(!auth.ok)return error(401,'invalid_session');
    const user=await auth.json();
    if(typeof user?.id!=='string'||!UUID.test(user.id))return error(401,'invalid_session');
    if(body.action==='pending'){
      const pending=await rpc('arcade_fleet_pending_v1',{p_admin_auth_user_id:user.id});
      return answer(200,{ok:true,pending});
    }
    const out=await rpc(body.action==='approve'?'arcade_fleet_approve_v1':'arcade_fleet_revoke_v1',
      {p_admin_auth_user_id:user.id,p_key_id:body.keyId});
    return answer(200,{ok:true,...out});
  }catch{return error(503,'fleet_service_unavailable')}
}
export default function handler(request){return handleFleetV1(request)}
