import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {validSilhouetteReceipt} from '../netlify/functions/arcade-silhouette-r1.mjs';
import {validSilhouetteR2Receipt} from '../netlify/functions/arcade-silhouette-r2.mjs';

const basic={g:'silhouette-precision',m:'standard-10',rv:1,s:100,t:1795743000,
 e:2,d:'01',p:1,q:{s:10,h:10,t:10,c:10,m:4970,a:0,b:0,d:0,e:0,f:10}};
const modern={g:'silhouette-precision',m:'standard-10',rv:2,s:259,t:1795743000,
 e:3,d:'02',q:{s:10,h:10,t:10,c:10,m:4970,g:657}};
test('Silhouette revision 1 accepts pilot and fleet receipts',()=>{
 assert.equal(validSilhouetteReceipt(basic),true);
 assert.equal(validSilhouetteReceipt({...basic,e:3,d:'02',p:undefined}),true);
 assert.equal(validSilhouetteReceipt({...basic,e:3,d:'02'}),false);
 assert.equal(validSilhouetteReceipt({...basic,e:2,d:'02'}),false);
 assert.equal(validSilhouetteReceipt({...basic,e:1}),false);
});
test('Silhouette revision 2 recognizes real 259-point fleet scoring shape',()=>{
 assert.equal(validSilhouetteR2Receipt(modern),true);
 assert.equal(validSilhouetteR2Receipt({...modern,e:2,d:'01',p:1}),true);
 assert.equal(validSilhouetteR2Receipt({...modern,e:3,p:1}),false);
 assert.equal(validSilhouetteR2Receipt({...modern,d:'00'}),false);
 assert.equal(validSilhouetteR2Receipt({...modern,e:9}),false);
});
test('SQL migration keeps event-2 pilot checks and adds scope-3 compatible claims for all games',()=>{
 const sql=readFileSync(new URL('../docs/arcade/fleet-claim-v1-migration.sql',import.meta.url),'utf8');
 for(const name of ['bullseye_modes_v1','bullseye_modes_v2','hostage_v3',
  'silhouette_v1','silhouette_v2','wildhunt_v1','zombie_campaign_v1']){
  const start=sql.indexOf('-- arcade_live_signed_claim_'+name+'\n');
  assert.notEqual(start,-1,name);
  const end=sql.indexOf('-- arcade_live_signed_claim_',start+3);
  const part=sql.slice(start,end<0?undefined:end);
  assert.match(part,/p_event_id NOT IN \(2,3\)/);
  assert.match(part,/p_event_id=3 AND v_event.pilot_only IS DISTINCT FROM false/);
  assert.match(part,/IF p_event_id=2 AND NOT EXISTS/);
  assert.match(part,/monitor_key_inactive/);
  assert.match(part,/payload_digest_mismatch/);
 }
});
