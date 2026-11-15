/**
 * Z&D Arcade signed score ingress — Stage 5, fail-closed by default.
 * Production score claiming requires explicit activation, a server-only
 * Supabase secret key, approved events/keys, and installed restricted RPCs.
 * No direct table writes, browser-supplied profile IDs, or client-side verification.
 */
import { createPublicKey, createHash, verify as verifySignature } from 'node:crypto';

const SIGNING_DOMAIN = Buffer.from('ZDAIRSOFT_SCORE_V1\0', 'utf8');
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const KEY_ID = /^K[A-F0-9]{16}$/;
const SAFE_KEY = /^[a-z][a-z0-9_]{0,31}$/;
const METRICS = new Set(['raw_points','shots','main_target_hits','center_hits',
  'time_ms','speed_bonus','group_bonus','group_mean_x100']);
const REQUIRED_METRICS = ['raw_points','shots','main_target_hits','center_hits','time_ms','speed_bonus','group_bonus'];
const jsonHeaders = { 'content-type':'application/json; charset=utf-8',
  'cache-control':'no-store',pragma:'no-cache','x-content-type-options':'nosniff' };
const reply = (status, body) => new Response(JSON.stringify(body), { status, headers:jsonHeaders });
const deny = (status, code) => reply(status, { status: status === 503 ? 'unavailable' : 'denied', code,
  claimed:false, ranked:false });
const positive = (n) => Number.isSafeInteger(n) && n >= 0;
function origin(raw) {
  try { const u = new URL(raw); return (u.protocol==='https:' && !u.port && !u.username &&
    !u.password && u.pathname==='/' && !u.search && !u.hash &&
    /^[a-z0-9-]+\.supabase\.co$/.test(u.hostname)) ? u.origin : null; }
  catch { return null; }
}
function b64url(s) {
  if (typeof s!=='string' || !/^[A-Za-z0-9_-]+$/.test(s)) throw Error('malformed');
  const b=Buffer.from(s,'base64url');
  if (b.toString('base64url')!==s) throw Error('malformed');
  return b;
}
/** Minimal deterministic CBOR subset: uint/bytes/text/map, no tags/arrays/negative ints. */
function decodeCbor(bytes) {
  let pos=0;
  const read=(depth=0)=>{
    if(pos>=bytes.length) throw Error('malformed');
    const initial=bytes[pos++], major=initial>>5, ai=initial&31;
    let n=ai;
    if(ai>=24){const width=ai===24?1:ai===25?2:ai===26?4:ai===27?8:0;
      if(!width || pos+width>bytes.length) throw Error('malformed');
      n=0; for(let i=0;i<width;i++) n=n*256+bytes[pos++];
      const minimum=width===1?24:width===2?256:width===4?65536:4294967296;
      if(!Number.isSafeInteger(n)||n<minimum)throw Error('malformed'); }
    if(major===0)return n;
    if(major===2||major===3){if(n>64||pos+n>bytes.length)throw Error('malformed');
      const raw=bytes.subarray(pos,pos+n);pos+=n;
      return major===2?raw:new TextDecoder('utf-8',{fatal:true}).decode(raw); }
    if(major!==5||depth>=2||n>16)throw Error('malformed');
    const map=new Map();let previous;
    for(let i=0;i<n;i++){
      const start=pos, key=read(depth+1), encoded=bytes.subarray(start,pos);
      if(typeof key!=='number'&&typeof key!=='string')throw Error('malformed');
      if(previous&&Buffer.compare(previous,encoded)>=0)throw Error('malformed');
      previous=encoded;
      if(map.has(key))throw Error('malformed');
      map.set(key,read(depth+1));
    }
    return map;
  };
  const map=read();if(pos!==bytes.length||!(map instanceof Map))throw Error('malformed');return map;
}
export function parseSignedWire(wire) {
  if(typeof wire!=='string'||wire.length>1024||!wire.startsWith('zda1:'))throw Error('malformed_receipt');
  const pieces=wire.slice(5).split('.');if(pieces.length!==2)throw Error('malformed_receipt');
  const payload=b64url(pieces[0]), signature=b64url(pieces[1]);
  if(payload.length<1||payload.length>512||signature.length!==64)throw Error('malformed_receipt');
  const m=decodeCbor(payload);
  for(const k of m.keys())if(typeof k!=='number'||k<1||k>13)throw Error('malformed_receipt');
  for(let i=1;i<=9;i++)if(!m.has(i))throw Error('malformed_receipt');
  const u=(k)=>{const n=m.get(k);if(!positive(n))throw Error('malformed_receipt');return n;};
  const id=(k,max)=>{const v=m.get(k);
    if(typeof v!=='string'||v.length>max||!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(v))throw Error('malformed_receipt');return v;};
  if(u(1)!==1||u(7)<1)throw Error('malformed_receipt');
  const uuid=m.get(2);if(!Buffer.isBuffer(uuid)||uuid.length!==16||(uuid[6]&240)!==64||(uuid[8]&192)!==128)
    throw Error('malformed_receipt');
  const h=uuid.toString('hex');const resultId=`${h.slice(0,8)}-${h.slice(8,12)}-${h.slice(12,16)}-${h.slice(16,20)}-${h.slice(20)}`;
  if(!UUID.test(resultId))throw Error('malformed_receipt');
  const receipt={ v:1,r:resultId,d:id(3,24),k:id(4,32),g:id(5,40),m:id(6,40),rv:u(7),s:u(8),t:u(9),q:{} };
  if(m.has(10)){
    const q=m.get(10);if(!(q instanceof Map)||q.size>12)throw Error('malformed_receipt');
    for(const [name,value] of q){if(typeof name!=='string'||!SAFE_KEY.test(name)||!positive(value))throw Error('malformed_receipt');
      receipt.q[name]=value;}
  }
  if(m.has(11))receipt.n=u(11);
  if(m.has(12))receipt.e=u(12);
  if(m.has(13)){ if(u(13)!==1)throw Error('malformed_receipt'); receipt.p=1; }
  return { receipt,payload,signature };
}
/** Stage 4 Bullseye bounds, same as launcher sign_round_v1. */
export function validateBullseye(receipt) {
  const q=receipt.q;
  if(receipt.g!=='bullseye-classic'||receipt.m!=='ten-shot'||receipt.rv!==1||!positive(receipt.e)||receipt.e<1||
    !/^[0-9]{2}$/.test(receipt.d)||receipt.d==='00'||!KEY_ID.test(receipt.k)||
    !positive(receipt.t)||receipt.t>4102444800||!positive(receipt.s)||receipt.s>125||
    Object.keys(q).some(k=>!METRICS.has(k))||REQUIRED_METRICS.some(k=>!Object.hasOwn(q,k)))return false;
  const {raw_points:raw,shots,main_target_hits:main,center_hits:center,time_ms:time,
    speed_bonus:speed,group_bonus:group,group_mean_x100:radius}=q;
  if(!positive(raw)||raw>100||shots!==10||!positive(main)||main>10||!positive(center)||center>main||
    raw<center*10||!positive(time)||time>600000||![0,5,10,15].includes(speed)||
    ![0,5,10].includes(group)||receipt.s!==raw+speed+group)return false;
  if(radius!==undefined&&(!positive(radius)||radius>100000||main!==10))return false;
  if(group>0&&(main!==10||radius===undefined))return false;
  return true;
}
export function verifyRegisteredReceipt(parsed, record, nowSec) {
  if(!record || !positive(nowSec))return {ok:false,code:'registry_unavailable'};
  const {receipt:r,payload,signature}=parsed;
  try {
    if(record.keyId!==r.k||record.monitorId!==r.d||record.eventId!==r.e||
      typeof record.publicKeyHex!=='string'||!/^[0-9a-fA-F]{140,320}$/.test(record.publicKeyHex))
      return {ok:false,code:'registry_mismatch'};
    const spki=Buffer.from(record.publicKeyHex,'hex');
    const publicKey=createPublicKey({key:spki,format:'der',type:'spki'});
    if(publicKey.asymmetricKeyType!=='ec'||publicKey.asymmetricKeyDetails?.namedCurve!=='prime256v1')
      return {ok:false,code:'invalid_registered_key'};
    const fp=createHash('sha256').update(spki).digest('hex');
    if(record.publicKeySha256!==fp)return {ok:false,code:'registry_fingerprint_mismatch'};
    if(!verifySignature('sha256',Buffer.concat([SIGNING_DOMAIN,payload]),
      {key:publicKey,dsaEncoding:'ieee-p1363'},signature))return {ok:false,code:'invalid_signature'};
    if(!validateBullseye(r))return {ok:false,code:'unsupported_result'};
    const start=Date.parse(record.startsAt),end=Date.parse(record.endsAt);
    if(!Number.isFinite(start)||!Number.isFinite(end)||end<=start)return {ok:false,code:'invalid_event_window'};
    if(record.keyStatus!=='active'||record.eventStatus!=='active'&&record.eventStatus!=='closed')
      return {ok:false,code:'event_or_key_pending'};
    if(nowSec*1000<start)return {ok:false,code:'event_not_started'};
    if(nowSec*1000>end+10*86400000)return {ok:false,code:'event_claim_expired'};
    return {ok:true,receipt:r,digest:createHash('sha256').update(payload).digest('hex'),
      payloadHex:payload.toString('hex'),signatureHex:signature.toString('hex'),publicKeySha256:fp};
  }catch{return {ok:false,code:'verification_unavailable'};}
}
const config = { path:'/arcade/api/claim-signed-score' };
export { config };

const endpoint = '/rest/v1/rpc/';
function isSafeResponse(d) { return !!d&&typeof d==='object'&&!Array.isArray(d); }
export async function handleSignedClaim(request, env=process.env, fetcher=fetch, now=()=>Date.now()) {
  if(request.method!=='POST')return deny(405,'method_not_allowed');
  const length=Number(request.headers.get('content-length')||0);
  if(!Number.isFinite(length)||length>4096)return deny(413,'request_too_large');
  const jwt=(request.headers.get('authorization')||'').match(/^Bearer ([A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)$/i)?.[1];
  if(!jwt)return deny(401,'authentication_required');
  if(!(request.headers.get('content-type')||'').toLowerCase().startsWith('application/json'))return deny(415,'json_required');
  const project=origin(env.SUPABASE_URL);
  const pk=env.SUPABASE_PUBLISHABLE_KEY;
  const sk=env.SUPABASE_SECRET_KEY;
  if(!project||!/^sb_publishable_[A-Za-z0-9_-]{12,}$/.test(pk||'')||
     !/^sb_secret_[A-Za-z0-9_-]{12,}$/.test(sk||''))return deny(503,'server_not_configured');
  let body;
  try {const raw=await request.text();if(raw.length>4096)return deny(413,'request_too_large');body=JSON.parse(raw);}catch{return deny(400,'invalid_json');}
  if(!isSafeResponse(body)||Object.keys(body).sort().join(',')!=='mode,wire'||
    (body.mode!=='verify'&&body.mode!=='claim'))return deny(400,'invalid_request');
  let parsed;
  try {parsed=parseSignedWire(body.wire);}catch{return deny(422,'malformed_receipt');}
  if(!validateBullseye(parsed.receipt))return deny(422,'unsupported_result');
  const fetchJson=async(path,key,method='POST',data)=>{
    const response=await fetcher(project+path,{method,redirect:'error',cache:'no-store',
      headers:{apikey:key,'content-type':'application/json',accept:'application/json',
        ...(path==='/auth/v1/user'?{authorization:`Bearer ${jwt}`}:{})},
      ...(method==='POST'?{body:JSON.stringify(data)}:{}),signal:AbortSignal.timeout(8000)});
    const raw=await response.text();if(raw.length>16000)throw Error('large_upstream');
    return {ok:response.ok,status:response.status,data:JSON.parse(raw)};
  };
  try {
    const auth=await fetchJson('/auth/v1/user',pk,'GET');
    if(!auth.ok||!UUID.test(auth.data?.id))return deny(auth.status===401?401:403,'invalid_session');
    const pre=await fetchJson(endpoint+'arcade_live_signed_preflight_v1',sk,'POST',{
      p_key_id:parsed.receipt.k,p_event_id:parsed.receipt.e});
    if(!pre.ok||!isSafeResponse(pre.data)||!pre.data.keyId)return deny(503,'registry_unavailable');
    const verified=verifyRegisteredReceipt(parsed,pre.data,Math.floor(now()/1000));
    if(!verified.ok) {
      if(body.mode==='verify'&&verified.code==='event_or_key_pending')
        return reply(200,{status:'signed_preview_only',signatureValid:true,claimable:false,
          gameId:parsed.receipt.g,modeId:parsed.receipt.m,score:parsed.receipt.s,
          metrics:parsed.receipt.q,code:'event_or_key_pending'});
      return deny(verified.code==='verification_unavailable'?503:422,verified.code);
    }
    // Pilot claims are intentionally scoped to one server-approved event.
    // Merely setting the main flag must never enable arbitrary future events.
    const pilotEnabled=env.ARCADE_SIGNED_CLAIMS_ENABLED==='true' &&
      env.ARCADE_SIGNED_TEST_EVENT_ID==='2' && verified.receipt.e===2 && verified.receipt.p===1;
    if(body.mode==='verify')return reply(200,{status:'verified_only',signatureValid:true,claimable:pilotEnabled,
      gameId:verified.receipt.g,modeId:verified.receipt.m,score:verified.receipt.s,metrics:verified.receipt.q});
    if(!pilotEnabled)return deny(503,'signed_claims_not_activated');
    const result=await fetchJson(endpoint+'arcade_live_signed_claim_v1',sk,'POST',{
      p_auth_user_id:auth.data.id,p_result_id:verified.receipt.r,p_event_id:verified.receipt.e,
      p_monitor_id:verified.receipt.d,p_key_id:verified.receipt.k,
      p_payload_hex:verified.payloadHex,p_signature_hex:verified.signatureHex,
      p_payload_sha256_hex:verified.digest,p_public_key_sha256_hex:verified.publicKeySha256,
      p_game_id:verified.receipt.g,p_mode_id:verified.receipt.m,
      p_scoring_revision:verified.receipt.rv,p_score:verified.receipt.s,
      p_device_unix_seconds:verified.receipt.t,p_metrics:verified.receipt.q});
    if(!result.ok) {
      // PostgreSQL's pilot allowlist/ownership denial is an authorization result,
      // not an outage. Never echo raw upstream SQL text to the client.
      if(result.status===403 && isSafeResponse(result.data) && result.data.code==='42501') {
        if(result.data.message==='pilot_account_not_authorized')return deny(403,'pilot_account_not_authorized');
        if(result.data.message==='player_not_authorized')return deny(403,'account_not_eligible');
        return deny(403,'account_not_eligible');
      }
      if(result.status===409)return deny(409,'receipt_already_claimed');
      // An RPC-side validation rejection is distinct from a temporary outage.
      if(result.status===400 && isSafeResponse(result.data) && result.data.code==='22023')
        return deny(422,'claim_rejected');
      return deny(503,'claim_unconfirmed');
    }
    if(!isSafeResponse(result.data))return deny(503,'claim_unconfirmed');
    if(result.data.outcome==='conflict')return deny(409,'receipt_already_claimed');
    if(result.data.outcome==='created'||result.data.outcome==='existing')
      return reply(result.data.outcome==='created'?201:200,{status:result.data.outcome==='created'?'claimed':'already_claimed',
        claimed:true,ranked:false,resultId:verified.receipt.r,gameId:verified.receipt.g,score:verified.receipt.s});
    return deny(503,'claim_unconfirmed');
  }catch{return deny(503,'upstream_unavailable');}
}
export default function handler(request){return handleSignedClaim(request);}
