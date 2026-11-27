-- Backwards-compatible Event 2 pilot OR Event 3 permanent fleet. No changes to score validation, key fingerprint, account profiles or replay detection.
-- arcade_live_signed_claim_bullseye_modes_v1
CREATE OR REPLACE FUNCTION public.arcade_live_signed_claim_bullseye_modes_v1(p_auth_user_id uuid, p_result_id uuid, p_event_id bigint, p_monitor_id text, p_key_id text, p_payload_hex text, p_signature_hex text, p_payload_sha256_hex text, p_public_key_sha256_hex text, p_game_id text, p_mode_id text, p_scoring_revision integer, p_score integer, p_device_unix_seconds bigint, p_metrics jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_profile uuid;v_claimed_at timestamptz:=clock_timestamp();
v_key record;v_event record;v_existing record;v_inserted uuid;
v_raw integer;v_shots integer;v_main integer;v_center integer;v_time integer;
v_seconds integer;v_keyname text;v_number jsonb;
BEGIN
 IF p_auth_user_id IS NULL OR p_result_id IS NULL OR (p_event_id IS NULL OR p_event_id NOT IN (2,3)) OR
 p_game_id IS DISTINCT FROM 'bullseye-classic' OR
 p_mode_id NOT IN ('timed-10','timed-20','timed-30','perfect-100') OR
 p_scoring_revision IS DISTINCT FROM 1 OR p_score IS NULL OR p_score NOT BETWEEN 0 AND 5120 OR
 p_monitor_id !~ '^[0-9]{2}$' OR p_monitor_id='00' OR p_key_id !~ '^K[0-9A-F]{16}$' OR
 p_device_unix_seconds IS NULL OR p_device_unix_seconds NOT BETWEEN 0 AND 4102444800 OR
 p_payload_hex !~ '^[0-9a-f]+$' OR length(p_payload_hex)<2 OR length(p_payload_hex)>1024 OR length(p_payload_hex)%2<>0 OR
 p_signature_hex !~ '^[0-9a-f]{128}$' OR p_payload_sha256_hex !~ '^[0-9a-f]{64}$' OR
 p_public_key_sha256_hex !~ '^[0-9a-f]{64}$' OR p_metrics IS NULL OR
 jsonb_typeof(p_metrics)<>'object' OR octet_length(p_metrics::text)>2048
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_bullseye_mode_receipt'; END IF;
 IF sha256(decode(p_payload_hex,'hex'))<>decode(p_payload_sha256_hex,'hex')
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='payload_digest_mismatch'; END IF;
 IF p_metrics - array['raw_points','shots','main_target_hits','center_hits','time_ms','speed_bonus','group_bonus']::text[] <> '{}'::jsonb
 OR NOT (p_metrics ?& array['raw_points','shots','main_target_hits','center_hits','time_ms','speed_bonus','group_bonus'])
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_bullseye_mode_metrics'; END IF;
 FOR v_keyname,v_number IN SELECT key,value FROM jsonb_each(p_metrics) LOOP
  IF jsonb_typeof(v_number)<>'number' OR v_number::text !~ '^[0-9]{1,8}$'
  THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_metric_number'; END IF;
 END LOOP;
 v_raw=(p_metrics->>'raw_points')::integer;
 v_shots=(p_metrics->>'shots')::integer;
 v_main=(p_metrics->>'main_target_hits')::integer;
 v_center=(p_metrics->>'center_hits')::integer;
 v_time=(p_metrics->>'time_ms')::integer;
 v_seconds=CASE p_mode_id WHEN 'timed-10' THEN 10 WHEN 'timed-20' THEN 20 WHEN 'timed-30' THEN 30 ELSE 0 END;
 IF v_shots NOT BETWEEN 1 AND 512 OR v_main NOT BETWEEN 0 AND v_shots OR
 v_center NOT BETWEEN 0 AND v_main OR v_raw NOT BETWEEN v_center*10 AND v_main*10 OR
 v_raw>5120 OR v_time NOT BETWEEN 0 AND 3600000 OR
 (p_metrics->>'speed_bonus')::integer<>0 OR (p_metrics->>'group_bonus')::integer<>0 OR
 (v_seconds>0 AND (v_time<>v_seconds*1000 OR p_score<>v_raw)) OR
 (v_seconds=0 AND (p_mode_id<>'perfect-100' OR v_shots<10 OR v_center<10 OR p_score<>100))
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='bullseye_mode_score_mismatch'; END IF;
 SELECT status,public_key_sha256,monitor_code INTO v_key
 FROM arcade_live_private.arcade_monitor_signing_keys WHERE key_id=p_key_id FOR SHARE;
 IF NOT FOUND OR v_key.status<>'active' OR v_key.monitor_code<>p_monitor_id OR
 v_key.public_key_sha256<>decode(p_public_key_sha256_hex,'hex')
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='monitor_key_inactive'; END IF;
 SELECT e.state,e.starts_at,e.ends_at,e.pilot_only INTO v_event
 FROM arcade_live_private.arcade_events e
 JOIN arcade_live_private.arcade_event_monitors em ON em.event_id=e.id
 WHERE e.id=p_event_id AND em.monitor_id=p_monitor_id AND em.key_id=p_key_id FOR SHARE OF e;
 IF NOT FOUND OR ((p_event_id=2 AND v_event.pilot_only IS DISTINCT FROM true) OR (p_event_id=3 AND v_event.pilot_only IS DISTINCT FROM false)) OR v_event.state NOT IN('active','closed') OR
 v_claimed_at<v_event.starts_at OR v_claimed_at>v_event.ends_at+interval '10 days'
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='event_ineligible_or_expired'; END IF;
 SELECT p.id INTO v_profile FROM public.arcade_player_profiles p
 JOIN public.arcade_adult_accounts a ON a.auth_user_id=p.owner_auth_user_id
 JOIN public.arcade_profile_permissions pm ON pm.profile_id=p.id AND pm.auth_user_id=p.owner_auth_user_id
 WHERE p.owner_auth_user_id=p_auth_user_id AND p.state='active' AND p.visibility='private' AND
 p.profile_kind='adult_self' AND pm.role='owner' AND pm.status='active' AND a.admission_state='approved_adult'
 LIMIT 1 FOR UPDATE OF p;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='player_not_authorized'; END IF;
 IF p_event_id=2 AND NOT EXISTS(SELECT 1 FROM arcade_live_private.arcade_pilot_claim_allowlist
  WHERE event_id=p_event_id AND profile_id=v_profile)
 THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='pilot_account_not_authorized'; END IF;
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_profile::text,149071));
 SELECT owner_auth_user_id,player_profile_id,encode(payload_sha256,'hex') AS digest INTO v_existing
 FROM public.arcade_receipt_claims WHERE result_id=p_result_id FOR UPDATE;
 IF FOUND THEN
  IF v_existing.owner_auth_user_id=p_auth_user_id AND v_existing.player_profile_id=v_profile AND
   v_existing.digest=p_payload_sha256_hex
  THEN RETURN jsonb_build_object('outcome','existing'); END IF;
  RETURN jsonb_build_object('outcome','conflict');
 END IF;
 INSERT INTO public.arcade_receipt_claims(result_id,owner_auth_user_id,player_profile_id,protocol_version,
 payload,signature,monitor_id,key_id,public_key_sha256,game_id,mode_id,
 scoring_revision,score,device_unix_seconds,metrics,round_counter,verifier_version,event_id)
 VALUES(p_result_id,p_auth_user_id,v_profile,1,decode(p_payload_hex,'hex'),decode(p_signature_hex,'hex'),
 p_monitor_id,p_key_id,decode(p_public_key_sha256_hex,'hex'),p_game_id,p_mode_id,
 p_scoring_revision,p_score,p_device_unix_seconds,p_metrics,NULL,'receipt-claims-v1',p_event_id)
 ON CONFLICT(result_id) DO NOTHING RETURNING result_id INTO v_inserted;
 IF v_inserted IS NULL THEN RETURN jsonb_build_object('outcome','conflict'); END IF;
 INSERT INTO arcade_live_private.arcade_signed_attempts(result_id,profile_id,owner_auth_user_id,
 game_id,mode_id,scoring_revision,score,metrics,event_id,claimed_at)
 VALUES(p_result_id,v_profile,p_auth_user_id,p_game_id,p_mode_id,p_scoring_revision,p_score,p_metrics,p_event_id,v_claimed_at);
 INSERT INTO arcade_live_private.arcade_signed_lifetime(profile_id,game_id,mode_id,scoring_revision,attempts,
 sum_scores,sum_raw_points,sum_registered_impacts,sum_center_hits,last_updated)
 VALUES(v_profile,p_game_id,p_mode_id,p_scoring_revision,1,p_score,v_raw,v_shots,v_center,v_claimed_at)
 ON CONFLICT(profile_id,game_id,mode_id,scoring_revision) DO UPDATE SET
 attempts=arcade_signed_lifetime.attempts+1,
 sum_scores=arcade_signed_lifetime.sum_scores+excluded.sum_scores,
 sum_raw_points=arcade_signed_lifetime.sum_raw_points+excluded.sum_raw_points,
 sum_registered_impacts=arcade_signed_lifetime.sum_registered_impacts+excluded.sum_registered_impacts,
 sum_center_hits=arcade_signed_lifetime.sum_center_hits+excluded.sum_center_hits,
 last_updated=excluded.last_updated;
 INSERT INTO arcade_live_private.arcade_signed_personal_bests(profile_id,game_id,mode_id,scoring_revision,
 best_result_id,score,metrics,achieved_at)
 VALUES(v_profile,p_game_id,p_mode_id,p_scoring_revision,p_result_id,p_score,p_metrics,v_claimed_at)
 ON CONFLICT(profile_id,game_id,mode_id,scoring_revision) DO UPDATE SET
 best_result_id=excluded.best_result_id,score=excluded.score,metrics=excluded.metrics,achieved_at=excluded.achieved_at
 WHERE CASE WHEN excluded.mode_id='perfect-100' THEN
 (-(excluded.metrics->>'shots')::integer,-(excluded.metrics->>'time_ms')::integer,
  (excluded.metrics->>'center_hits')::integer) >
 (-(arcade_signed_personal_bests.metrics->>'shots')::integer,
  -(arcade_signed_personal_bests.metrics->>'time_ms')::integer,
  (arcade_signed_personal_bests.metrics->>'center_hits')::integer)
 ELSE
 (excluded.score,(excluded.metrics->>'center_hits')::integer,-(excluded.metrics->>'shots')::integer) >
 (arcade_signed_personal_bests.score,
 (arcade_signed_personal_bests.metrics->>'center_hits')::integer,
 -(arcade_signed_personal_bests.metrics->>'shots')::integer)
 END;
 DELETE FROM arcade_live_private.arcade_signed_attempts a
 WHERE a.profile_id=v_profile AND a.result_id IN (
 SELECT result_id FROM arcade_live_private.arcade_signed_attempts
 WHERE profile_id=v_profile ORDER BY claimed_at DESC,result_id DESC OFFSET 50);
 RETURN jsonb_build_object('outcome','created');
END
$function$
;

-- arcade_live_signed_claim_bullseye_modes_v2
CREATE OR REPLACE FUNCTION public.arcade_live_signed_claim_bullseye_modes_v2(p_auth_user_id uuid, p_result_id uuid, p_event_id bigint, p_monitor_id text, p_key_id text, p_payload_hex text, p_signature_hex text, p_payload_sha256_hex text, p_public_key_sha256_hex text, p_game_id text, p_mode_id text, p_scoring_revision integer, p_score integer, p_device_unix_seconds bigint, p_metrics jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_profile uuid;v_claimed_at timestamptz:=clock_timestamp();
v_key record;v_event record;v_existing record;v_inserted uuid;
v_raw integer;v_shots integer;v_main integer;v_center integer;v_time integer;
v_seconds integer;v_keyname text;v_number jsonb; v_radius integer;v_group integer;v_eff integer;v_accuracy integer;v_tightness integer;v_grade integer;v_percent integer;v_expected integer;
BEGIN
 IF p_auth_user_id IS NULL OR p_result_id IS NULL OR (p_event_id IS NULL OR p_event_id NOT IN (2,3)) OR
 p_game_id IS DISTINCT FROM 'bullseye-classic' OR
 p_mode_id NOT IN ('timed-10','timed-20','timed-30','perfect-100') OR
 p_scoring_revision IS DISTINCT FROM 2 OR p_score IS NULL OR p_score NOT BETWEEN 0 AND 7680 OR
 p_monitor_id !~ '^[0-9]{2}$' OR p_monitor_id='00' OR p_key_id !~ '^K[0-9A-F]{16}$' OR
 p_device_unix_seconds IS NULL OR p_device_unix_seconds NOT BETWEEN 0 AND 4102444800 OR
 p_payload_hex !~ '^[0-9a-f]+$' OR length(p_payload_hex)<2 OR length(p_payload_hex)>1024 OR length(p_payload_hex)%2<>0 OR
 p_signature_hex !~ '^[0-9a-f]{128}$' OR p_payload_sha256_hex !~ '^[0-9a-f]{64}$' OR
 p_public_key_sha256_hex !~ '^[0-9a-f]{64}$' OR p_metrics IS NULL OR
 jsonb_typeof(p_metrics)<>'object' OR octet_length(p_metrics::text)>2048
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_bullseye_mode_receipt'; END IF;
 IF sha256(decode(p_payload_hex,'hex'))<>decode(p_payload_sha256_hex,'hex')
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='payload_digest_mismatch'; END IF;
 IF p_metrics - array['raw_points','shots','main_target_hits','center_hits','time_ms','speed_bonus','group_bonus','group_mean_x100']::text[] <> '{}'::jsonb
 OR NOT (p_metrics ?& array['raw_points','shots','main_target_hits','center_hits','time_ms','speed_bonus','group_bonus','group_mean_x100'])
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_bullseye_mode_metrics'; END IF;
 FOR v_keyname,v_number IN SELECT key,value FROM jsonb_each(p_metrics) LOOP
  IF jsonb_typeof(v_number)<>'number' OR (v_keyname='group_bonus' AND v_number::text !~ '^-?[0-9]{1,8}$') OR (v_keyname<>'group_bonus' AND v_number::text !~ '^[0-9]{1,8}$')
  THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_metric_number'; END IF;
 END LOOP;
 v_raw=(p_metrics->>'raw_points')::integer;
 v_shots=(p_metrics->>'shots')::integer;
 v_main=(p_metrics->>'main_target_hits')::integer;
 v_center=(p_metrics->>'center_hits')::integer;
 v_time=(p_metrics->>'time_ms')::integer;

 v_seconds=CASE p_mode_id WHEN 'timed-10' THEN 10 WHEN 'timed-20' THEN 20 WHEN 'timed-30' THEN 30 ELSE 0 END;
 v_radius=(p_metrics->>'group_mean_x100')::integer;
 v_group=(p_metrics->>'group_bonus')::integer;
 v_eff=(p_metrics->>'speed_bonus')::integer;
 IF v_shots NOT BETWEEN 1 AND 512 OR v_main NOT BETWEEN 0 AND v_shots OR
    v_center NOT BETWEEN 0 AND v_main OR v_raw NOT BETWEEN v_center*10 AND v_main*10 OR
    v_raw>5120 OR v_time NOT BETWEEN 0 AND 3600000 OR v_radius NOT BETWEEN 0 AND 100000 OR
    v_eff NOT BETWEEN 0 AND 100 OR v_group NOT BETWEEN -3840 AND 2560
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='bullseye_mode_score_mismatch'; END IF;
 IF v_seconds>0 THEN
   v_accuracy=least(100,(v_raw*10+v_shots/2)/v_shots);
   v_tightness=CASE WHEN v_radius>=7000 THEN 0 ELSE ((7000-v_radius)*100+3500)/7000 END;
   v_grade=(2*v_accuracy+v_tightness+1)/3;
   v_percent=greatest(-75,least(50,(v_grade-75)*2));
   v_expected=CASE WHEN v_percent<0 THEN -((v_raw*(-v_percent)+50)/100)
     ELSE (v_raw*v_percent+50)/100 END;
   IF v_time<>v_seconds*1000 OR v_eff<>0 OR v_group<>v_expected OR p_score<>v_raw+v_expected
   THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='timed_group_adjustment_mismatch'; END IF;
 ELSE
   v_expected=CASE WHEN v_radius>=3500 THEN 0 ELSE ((3500-v_radius)*100+1750)/3500 END;
   IF p_mode_id<>'perfect-100' OR v_shots<10 OR v_center<10 OR
      v_eff<>greatest(0,100-(v_shots-10)*10) OR v_group<>v_expected OR
      p_score<>100+v_eff+v_group
   THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='perfect_100_grouping_mismatch'; END IF;
 END IF;
  SELECT status,public_key_sha256,monitor_code INTO v_key
 FROM arcade_live_private.arcade_monitor_signing_keys WHERE key_id=p_key_id FOR SHARE;
 IF NOT FOUND OR v_key.status<>'active' OR v_key.monitor_code<>p_monitor_id OR
 v_key.public_key_sha256<>decode(p_public_key_sha256_hex,'hex')
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='monitor_key_inactive'; END IF;
 SELECT e.state,e.starts_at,e.ends_at,e.pilot_only INTO v_event
 FROM arcade_live_private.arcade_events e
 JOIN arcade_live_private.arcade_event_monitors em ON em.event_id=e.id
 WHERE e.id=p_event_id AND em.monitor_id=p_monitor_id AND em.key_id=p_key_id FOR SHARE OF e;
 IF NOT FOUND OR ((p_event_id=2 AND v_event.pilot_only IS DISTINCT FROM true) OR (p_event_id=3 AND v_event.pilot_only IS DISTINCT FROM false)) OR v_event.state NOT IN('active','closed') OR
 v_claimed_at<v_event.starts_at OR v_claimed_at>v_event.ends_at+interval '10 days'
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='event_ineligible_or_expired'; END IF;
 SELECT p.id INTO v_profile FROM public.arcade_player_profiles p
 JOIN public.arcade_adult_accounts a ON a.auth_user_id=p.owner_auth_user_id
 JOIN public.arcade_profile_permissions pm ON pm.profile_id=p.id AND pm.auth_user_id=p.owner_auth_user_id
 WHERE p.owner_auth_user_id=p_auth_user_id AND p.state='active' AND p.visibility='private' AND
 p.profile_kind='adult_self' AND pm.role='owner' AND pm.status='active' AND a.admission_state='approved_adult'
 LIMIT 1 FOR UPDATE OF p;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='player_not_authorized'; END IF;
 IF p_event_id=2 AND NOT EXISTS(SELECT 1 FROM arcade_live_private.arcade_pilot_claim_allowlist
  WHERE event_id=p_event_id AND profile_id=v_profile)
 THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='pilot_account_not_authorized'; END IF;
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_profile::text,149071));
 SELECT owner_auth_user_id,player_profile_id,encode(payload_sha256,'hex') AS digest INTO v_existing
 FROM public.arcade_receipt_claims WHERE result_id=p_result_id FOR UPDATE;
 IF FOUND THEN
  IF v_existing.owner_auth_user_id=p_auth_user_id AND v_existing.player_profile_id=v_profile AND
   v_existing.digest=p_payload_sha256_hex
  THEN RETURN jsonb_build_object('outcome','existing'); END IF;
  RETURN jsonb_build_object('outcome','conflict');
 END IF;
 INSERT INTO public.arcade_receipt_claims(result_id,owner_auth_user_id,player_profile_id,protocol_version,
 payload,signature,monitor_id,key_id,public_key_sha256,game_id,mode_id,
 scoring_revision,score,device_unix_seconds,metrics,round_counter,verifier_version,event_id)
 VALUES(p_result_id,p_auth_user_id,v_profile,1,decode(p_payload_hex,'hex'),decode(p_signature_hex,'hex'),
 p_monitor_id,p_key_id,decode(p_public_key_sha256_hex,'hex'),p_game_id,p_mode_id,
 p_scoring_revision,p_score,p_device_unix_seconds,p_metrics,NULL,'receipt-claims-v1',p_event_id)
 ON CONFLICT(result_id) DO NOTHING RETURNING result_id INTO v_inserted;
 IF v_inserted IS NULL THEN RETURN jsonb_build_object('outcome','conflict'); END IF;
 INSERT INTO arcade_live_private.arcade_signed_attempts(result_id,profile_id,owner_auth_user_id,
 game_id,mode_id,scoring_revision,score,metrics,event_id,claimed_at)
 VALUES(p_result_id,v_profile,p_auth_user_id,p_game_id,p_mode_id,p_scoring_revision,p_score,p_metrics,p_event_id,v_claimed_at);
 INSERT INTO arcade_live_private.arcade_signed_lifetime(profile_id,game_id,mode_id,scoring_revision,attempts,
 sum_scores,sum_raw_points,sum_registered_impacts,sum_center_hits,last_updated)
 VALUES(v_profile,p_game_id,p_mode_id,p_scoring_revision,1,p_score,v_raw,v_shots,v_center,v_claimed_at)
 ON CONFLICT(profile_id,game_id,mode_id,scoring_revision) DO UPDATE SET
 attempts=arcade_signed_lifetime.attempts+1,
 sum_scores=arcade_signed_lifetime.sum_scores+excluded.sum_scores,
 sum_raw_points=arcade_signed_lifetime.sum_raw_points+excluded.sum_raw_points,
 sum_registered_impacts=arcade_signed_lifetime.sum_registered_impacts+excluded.sum_registered_impacts,
 sum_center_hits=arcade_signed_lifetime.sum_center_hits+excluded.sum_center_hits,
 last_updated=excluded.last_updated;
 INSERT INTO arcade_live_private.arcade_signed_personal_bests(profile_id,game_id,mode_id,scoring_revision,
 best_result_id,score,metrics,achieved_at)
 VALUES(v_profile,p_game_id,p_mode_id,p_scoring_revision,p_result_id,p_score,p_metrics,v_claimed_at)
 ON CONFLICT(profile_id,game_id,mode_id,scoring_revision) DO UPDATE SET
 best_result_id=excluded.best_result_id,score=excluded.score,metrics=excluded.metrics,achieved_at=excluded.achieved_at

 WHERE CASE WHEN excluded.mode_id='perfect-100' THEN
   (excluded.score,-(excluded.metrics->>'shots')::integer,-(excluded.metrics->>'time_ms')::integer,
      (excluded.metrics->>'center_hits')::integer) >
   (arcade_signed_personal_bests.score,-(arcade_signed_personal_bests.metrics->>'shots')::integer,
      -(arcade_signed_personal_bests.metrics->>'time_ms')::integer,
      (arcade_signed_personal_bests.metrics->>'center_hits')::integer)
 ELSE
   (excluded.score,(excluded.metrics->>'raw_points')::integer,(excluded.metrics->>'center_hits')::integer,
      (excluded.metrics->>'group_bonus')::integer,-(excluded.metrics->>'shots')::integer) >
   (arcade_signed_personal_bests.score,(arcade_signed_personal_bests.metrics->>'raw_points')::integer,
      (arcade_signed_personal_bests.metrics->>'center_hits')::integer,
      (arcade_signed_personal_bests.metrics->>'group_bonus')::integer,
      -(arcade_signed_personal_bests.metrics->>'shots')::integer)
 END;
 DELETE FROM arcade_live_private.arcade_signed_attempts a
 WHERE a.profile_id=v_profile AND a.result_id IN (
 SELECT result_id FROM arcade_live_private.arcade_signed_attempts
 WHERE profile_id=v_profile ORDER BY claimed_at DESC,result_id DESC OFFSET 50);
 RETURN jsonb_build_object('outcome','created');
END
$function$
;

-- arcade_live_signed_claim_hostage_v3
CREATE OR REPLACE FUNCTION public.arcade_live_signed_claim_hostage_v3(p_auth_user_id uuid, p_result_id uuid, p_event_id bigint, p_monitor_id text, p_key_id text, p_payload_hex text, p_signature_hex text, p_payload_sha256_hex text, p_public_key_sha256_hex text, p_game_id text, p_mode_id text, p_scoring_revision integer, p_score integer, p_device_unix_seconds bigint, p_metrics jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
 v_profile uuid;v_key record;v_event record;v_existing record;v_inserted uuid;
 v_shots integer;v_h integer;v_p integer;v_m integer;v_c integer;v_f integer;v_t integer;v_w integer;
 v_score integer;v_fast integer;v_slow integer;v_cap integer;
 v_k text;v_value jsonb;v_now timestamptz:=clock_timestamp();
BEGIN
 IF p_auth_user_id IS NULL OR p_result_id IS NULL OR (p_event_id IS NULL OR p_event_id NOT IN (2,3))
 OR (p_monitor_id IS NULL OR p_monitor_id !~ '^[0-9]{2} OR p_game_id IS DISTINCT FROM 'hostage-rescue'
 OR p_mode_id IS NULL OR p_mode_id NOT IN (
 'classic-rescue-easy','classic-rescue-normal','classic-rescue-hard',
 'no-mistakes-easy','no-mistakes-normal','no-mistakes-hard',
 'timed-45s-easy','timed-45s-normal','timed-45s-hard')
 OR p_scoring_revision IS DISTINCT FROM 3 OR p_score IS NULL OR p_score NOT BETWEEN 0 AND 300
 OR p_key_id IS NULL OR p_key_id !~ '^K[0-9A-F]{16}$'
 OR p_device_unix_seconds IS NULL OR p_device_unix_seconds NOT BETWEEN 1704067200 AND 4102444800
 OR p_payload_hex IS NULL OR p_payload_hex !~ '^[0-9a-f]+$' OR length(p_payload_hex) NOT BETWEEN 2 AND 1024 OR length(p_payload_hex)%2<>0
 OR p_signature_hex IS NULL OR p_signature_hex !~ '^[0-9a-f]{128}$'
 OR p_payload_sha256_hex IS NULL OR p_payload_sha256_hex !~ '^[0-9a-f]{64}$'
 OR p_public_key_sha256_hex IS NULL OR p_public_key_sha256_hex !~ '^[0-9a-f]{64}$'
 OR p_metrics IS NULL OR jsonb_typeof(p_metrics)<>'object' OR octet_length(p_metrics::text)>2048
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_hostage_claim';END IF;
 IF sha256(decode(p_payload_hex,'hex'))<>decode(p_payload_sha256_hex,'hex') THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='payload_digest_mismatch';END IF;
 IF (p_metrics - ARRAY['shots','threat_hits','protected_hits','misses','correct_holds','failed_scenes','time_ms','wasted_shots']::text[])<>'{}'::jsonb
 OR NOT p_metrics ?& ARRAY['shots','threat_hits','protected_hits','misses','correct_holds','failed_scenes','time_ms','wasted_shots']
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='hostage_metric_shape';END IF;
 FOR v_k,v_value IN SELECT key,value FROM jsonb_each(p_metrics) LOOP
  IF jsonb_typeof(v_value)<>'number' OR v_value::text !~ '^[0-9]{1,10}$' OR (v_value::text)::bigint>2147483647
  THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='hostage_metric_value';END IF;
 END LOOP;
 v_shots:=(p_metrics->>'shots')::integer;v_h:=(p_metrics->>'threat_hits')::integer;
 v_p:=(p_metrics->>'protected_hits')::integer;v_m:=(p_metrics->>'misses')::integer;
 v_c:=(p_metrics->>'correct_holds')::integer;v_f:=(p_metrics->>'failed_scenes')::integer;
 v_t:=(p_metrics->>'time_ms')::integer;v_w:=(p_metrics->>'wasted_shots')::integer;
 v_cap:=CASE WHEN p_mode_id LIKE '%-easy' THEN 100 WHEN p_mode_id LIKE '%-normal' THEN 80 ELSE 60 END;
 IF v_shots>v_cap OR v_h>12 OR v_p>v_cap OR v_m>v_cap OR v_c>2 OR v_f>10
 OR v_t>86400000 OR v_w>v_m OR v_shots<>v_h+v_p+v_m
 OR (p_mode_id LIKE 'timed-45s-%' AND v_t>45000)
 OR (p_mode_id LIKE 'no-mistakes-%' AND (v_f<>0 OR v_p<>0 OR
    (p_mode_id='no-mistakes-normal' AND v_m>1) OR
    (p_mode_id='no-mistakes-hard' AND v_m>0)))
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='hostage_metric_bounds';END IF;
 IF p_mode_id LIKE 'classic-%' THEN v_fast:=15000;v_slow:=35000;
 ELSIF p_mode_id LIKE 'no-mistakes-%' THEN v_fast:=17000;v_slow:=37000;
 ELSE v_fast:=20000;v_slow:=45000;END IF;
 v_score:=floor((100::numeric*(v_h+v_c)/14)+0.5)::integer
   +greatest(0,100-40*v_p)
   +CASE WHEN v_shots=0 THEN 0 ELSE floor(50::numeric*v_h*v_h*v_h/(v_shots::numeric*v_shots*v_shots)+0.5)::integer END
   +CASE WHEN v_t<=v_fast THEN 50 WHEN v_t>=v_slow THEN 0
         ELSE floor(50::numeric*(v_slow-v_t)/(v_slow-v_fast)+0.5)::integer END;
 IF least(300,v_score)<>p_score THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='hostage_score_mismatch';END IF;
 SELECT k.status,k.public_key_sha256,k.monitor_code INTO v_key
 FROM arcade_live_private.arcade_monitor_signing_keys k WHERE k.key_id=p_key_id FOR SHARE;
 IF NOT FOUND OR v_key.status<>'active' OR v_key.monitor_code<>p_monitor_id OR
 v_key.public_key_sha256<>decode(p_public_key_sha256_hex,'hex')
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='monitor_key_inactive';END IF;
 SELECT e.state,e.starts_at,e.ends_at,e.pilot_only INTO v_event
 FROM arcade_live_private.arcade_events e
 JOIN arcade_live_private.arcade_event_monitors em ON em.event_id=e.id
 WHERE e.id=p_event_id AND em.monitor_id=p_monitor_id AND em.key_id=p_key_id FOR SHARE OF e;
 IF NOT FOUND OR v_event.state NOT IN ('active','closed') OR ((p_event_id=2 AND v_event.pilot_only IS DISTINCT FROM true) OR (p_event_id=3 AND v_event.pilot_only IS DISTINCT FROM false))
 OR v_now<v_event.starts_at OR v_now>v_event.ends_at+interval '10 days'
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='event_ineligible_or_expired';END IF;
 SELECT p.id INTO v_profile FROM public.arcade_player_profiles p
 JOIN public.arcade_adult_accounts a ON a.auth_user_id=p.owner_auth_user_id
 JOIN public.arcade_profile_permissions pm ON pm.profile_id=p.id AND pm.auth_user_id=p.owner_auth_user_id
 WHERE p.owner_auth_user_id=p_auth_user_id AND p.state='active' AND p.visibility='private'
 AND p.profile_kind='adult_self' AND pm.role='owner' AND pm.status='active'
 AND a.admission_state='approved_adult' LIMIT 1 FOR UPDATE OF p;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='player_not_authorized';END IF;
 IF p_event_id=2 AND NOT EXISTS(SELECT 1 FROM arcade_live_private.arcade_pilot_claim_allowlist al
  WHERE al.event_id=p_event_id AND al.profile_id=v_profile)
 THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='pilot_account_not_authorized';END IF;
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_profile::text,149071));
 SELECT owner_auth_user_id,player_profile_id,encode(payload_sha256,'hex') digest INTO v_existing
 FROM public.arcade_receipt_claims WHERE result_id=p_result_id FOR UPDATE;
 IF FOUND THEN
   IF v_existing.owner_auth_user_id=p_auth_user_id AND v_existing.player_profile_id=v_profile
    AND v_existing.digest=p_payload_sha256_hex THEN RETURN jsonb_build_object('outcome','existing');END IF;
   RETURN jsonb_build_object('outcome','conflict');
 END IF;
 INSERT INTO public.arcade_receipt_claims(result_id,owner_auth_user_id,player_profile_id,protocol_version,
 payload,signature,monitor_id,key_id,public_key_sha256,game_id,mode_id,scoring_revision,score,
 device_unix_seconds,metrics,round_counter,verifier_version,event_id)
 VALUES(p_result_id,p_auth_user_id,v_profile,1,decode(p_payload_hex,'hex'),decode(p_signature_hex,'hex'),
 p_monitor_id,p_key_id,decode(p_public_key_sha256_hex,'hex'),p_game_id,p_mode_id,p_scoring_revision,
 p_score,p_device_unix_seconds,p_metrics,null,'receipt-claims-v1',p_event_id)
 ON CONFLICT(result_id) DO NOTHING RETURNING result_id INTO v_inserted;
 IF v_inserted IS NULL THEN RETURN jsonb_build_object('outcome','conflict');END IF;
 INSERT INTO arcade_live_private.arcade_signed_attempts(result_id,profile_id,owner_auth_user_id,
 game_id,mode_id,scoring_revision,score,metrics,event_id,claimed_at)
 VALUES(p_result_id,v_profile,p_auth_user_id,p_game_id,p_mode_id,p_scoring_revision,p_score,p_metrics,p_event_id,v_now);
 INSERT INTO arcade_live_private.arcade_signed_lifetime(profile_id,game_id,mode_id,scoring_revision,
 attempts,sum_scores,sum_raw_points,sum_registered_impacts,sum_center_hits,last_updated)
 VALUES(v_profile,p_game_id,p_mode_id,p_scoring_revision,1,p_score,0,v_shots,v_h,v_now)
 ON CONFLICT(profile_id,game_id,mode_id,scoring_revision) DO UPDATE SET
 attempts=arcade_signed_lifetime.attempts+1,sum_scores=arcade_signed_lifetime.sum_scores+excluded.sum_scores,
 sum_raw_points=arcade_signed_lifetime.sum_raw_points+excluded.sum_raw_points,
 sum_registered_impacts=arcade_signed_lifetime.sum_registered_impacts+excluded.sum_registered_impacts,
 sum_center_hits=arcade_signed_lifetime.sum_center_hits+excluded.sum_center_hits,last_updated=excluded.last_updated;
 INSERT INTO arcade_live_private.arcade_signed_personal_bests(profile_id,game_id,mode_id,scoring_revision,
 best_result_id,score,metrics,achieved_at)
 VALUES(v_profile,p_game_id,p_mode_id,p_scoring_revision,p_result_id,p_score,p_metrics,v_now)
 ON CONFLICT(profile_id,game_id,mode_id,scoring_revision) DO UPDATE SET
 best_result_id=excluded.best_result_id,score=excluded.score,metrics=excluded.metrics,achieved_at=excluded.achieved_at
 WHERE (excluded.score,-(excluded.metrics->>'protected_hits')::integer,
 -(excluded.metrics->>'misses')::integer,-(excluded.metrics->>'time_ms')::integer)>
 (arcade_signed_personal_bests.score,-(arcade_signed_personal_bests.metrics->>'protected_hits')::integer,
 -(arcade_signed_personal_bests.metrics->>'misses')::integer,-(arcade_signed_personal_bests.metrics->>'time_ms')::integer);
 DELETE FROM arcade_live_private.arcade_signed_attempts s WHERE s.profile_id=v_profile AND s.result_id IN
 (SELECT result_id FROM arcade_live_private.arcade_signed_attempts WHERE profile_id=v_profile
 ORDER BY claimed_at DESC,result_id DESC OFFSET 50);
 RETURN jsonb_build_object('outcome','created');
END $function$
 OR p_monitor_id='00' OR (p_event_id=2 AND p_monitor_id<>'01')) OR p_game_id IS DISTINCT FROM 'hostage-rescue'
 OR p_mode_id IS NULL OR p_mode_id NOT IN (
 'classic-rescue-easy','classic-rescue-normal','classic-rescue-hard',
 'no-mistakes-easy','no-mistakes-normal','no-mistakes-hard',
 'timed-45s-easy','timed-45s-normal','timed-45s-hard')
 OR p_scoring_revision IS DISTINCT FROM 3 OR p_score IS NULL OR p_score NOT BETWEEN 0 AND 300
 OR p_key_id IS NULL OR p_key_id !~ '^K[0-9A-F]{16}$'
 OR p_device_unix_seconds IS NULL OR p_device_unix_seconds NOT BETWEEN 1704067200 AND 4102444800
 OR p_payload_hex IS NULL OR p_payload_hex !~ '^[0-9a-f]+$' OR length(p_payload_hex) NOT BETWEEN 2 AND 1024 OR length(p_payload_hex)%2<>0
 OR p_signature_hex IS NULL OR p_signature_hex !~ '^[0-9a-f]{128}$'
 OR p_payload_sha256_hex IS NULL OR p_payload_sha256_hex !~ '^[0-9a-f]{64}$'
 OR p_public_key_sha256_hex IS NULL OR p_public_key_sha256_hex !~ '^[0-9a-f]{64}$'
 OR p_metrics IS NULL OR jsonb_typeof(p_metrics)<>'object' OR octet_length(p_metrics::text)>2048
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_hostage_claim';END IF;
 IF sha256(decode(p_payload_hex,'hex'))<>decode(p_payload_sha256_hex,'hex') THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='payload_digest_mismatch';END IF;
 IF (p_metrics - ARRAY['shots','threat_hits','protected_hits','misses','correct_holds','failed_scenes','time_ms','wasted_shots']::text[])<>'{}'::jsonb
 OR NOT p_metrics ?& ARRAY['shots','threat_hits','protected_hits','misses','correct_holds','failed_scenes','time_ms','wasted_shots']
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='hostage_metric_shape';END IF;
 FOR v_k,v_value IN SELECT key,value FROM jsonb_each(p_metrics) LOOP
  IF jsonb_typeof(v_value)<>'number' OR v_value::text !~ '^[0-9]{1,10}$' OR (v_value::text)::bigint>2147483647
  THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='hostage_metric_value';END IF;
 END LOOP;
 v_shots:=(p_metrics->>'shots')::integer;v_h:=(p_metrics->>'threat_hits')::integer;
 v_p:=(p_metrics->>'protected_hits')::integer;v_m:=(p_metrics->>'misses')::integer;
 v_c:=(p_metrics->>'correct_holds')::integer;v_f:=(p_metrics->>'failed_scenes')::integer;
 v_t:=(p_metrics->>'time_ms')::integer;v_w:=(p_metrics->>'wasted_shots')::integer;
 v_cap:=CASE WHEN p_mode_id LIKE '%-easy' THEN 100 WHEN p_mode_id LIKE '%-normal' THEN 80 ELSE 60 END;
 IF v_shots>v_cap OR v_h>12 OR v_p>v_cap OR v_m>v_cap OR v_c>2 OR v_f>10
 OR v_t>86400000 OR v_w>v_m OR v_shots<>v_h+v_p+v_m
 OR (p_mode_id LIKE 'timed-45s-%' AND v_t>45000)
 OR (p_mode_id LIKE 'no-mistakes-%' AND (v_f<>0 OR v_p<>0 OR
    (p_mode_id='no-mistakes-normal' AND v_m>1) OR
    (p_mode_id='no-mistakes-hard' AND v_m>0)))
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='hostage_metric_bounds';END IF;
 IF p_mode_id LIKE 'classic-%' THEN v_fast:=15000;v_slow:=35000;
 ELSIF p_mode_id LIKE 'no-mistakes-%' THEN v_fast:=17000;v_slow:=37000;
 ELSE v_fast:=20000;v_slow:=45000;END IF;
 v_score:=floor((100::numeric*(v_h+v_c)/14)+0.5)::integer
   +greatest(0,100-40*v_p)
   +CASE WHEN v_shots=0 THEN 0 ELSE floor(50::numeric*v_h*v_h*v_h/(v_shots::numeric*v_shots*v_shots)+0.5)::integer END
   +CASE WHEN v_t<=v_fast THEN 50 WHEN v_t>=v_slow THEN 0
         ELSE floor(50::numeric*(v_slow-v_t)/(v_slow-v_fast)+0.5)::integer END;
 IF least(300,v_score)<>p_score THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='hostage_score_mismatch';END IF;
 SELECT k.status,k.public_key_sha256,k.monitor_code INTO v_key
 FROM arcade_live_private.arcade_monitor_signing_keys k WHERE k.key_id=p_key_id FOR SHARE;
 IF NOT FOUND OR v_key.status<>'active' OR v_key.monitor_code<>p_monitor_id OR
 v_key.public_key_sha256<>decode(p_public_key_sha256_hex,'hex')
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='monitor_key_inactive';END IF;
 SELECT e.state,e.starts_at,e.ends_at,e.pilot_only INTO v_event
 FROM arcade_live_private.arcade_events e
 JOIN arcade_live_private.arcade_event_monitors em ON em.event_id=e.id
 WHERE e.id=p_event_id AND em.monitor_id=p_monitor_id AND em.key_id=p_key_id FOR SHARE OF e;
 IF NOT FOUND OR v_event.state NOT IN ('active','closed') OR ((p_event_id=2 AND v_event.pilot_only IS DISTINCT FROM true) OR (p_event_id=3 AND v_event.pilot_only IS DISTINCT FROM false))
 OR v_now<v_event.starts_at OR v_now>v_event.ends_at+interval '10 days'
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='event_ineligible_or_expired';END IF;
 SELECT p.id INTO v_profile FROM public.arcade_player_profiles p
 JOIN public.arcade_adult_accounts a ON a.auth_user_id=p.owner_auth_user_id
 JOIN public.arcade_profile_permissions pm ON pm.profile_id=p.id AND pm.auth_user_id=p.owner_auth_user_id
 WHERE p.owner_auth_user_id=p_auth_user_id AND p.state='active' AND p.visibility='private'
 AND p.profile_kind='adult_self' AND pm.role='owner' AND pm.status='active'
 AND a.admission_state='approved_adult' LIMIT 1 FOR UPDATE OF p;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='player_not_authorized';END IF;
 IF p_event_id=2 AND NOT EXISTS(SELECT 1 FROM arcade_live_private.arcade_pilot_claim_allowlist al
  WHERE al.event_id=p_event_id AND al.profile_id=v_profile)
 THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='pilot_account_not_authorized';END IF;
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_profile::text,149071));
 SELECT owner_auth_user_id,player_profile_id,encode(payload_sha256,'hex') digest INTO v_existing
 FROM public.arcade_receipt_claims WHERE result_id=p_result_id FOR UPDATE;
 IF FOUND THEN
   IF v_existing.owner_auth_user_id=p_auth_user_id AND v_existing.player_profile_id=v_profile
    AND v_existing.digest=p_payload_sha256_hex THEN RETURN jsonb_build_object('outcome','existing');END IF;
   RETURN jsonb_build_object('outcome','conflict');
 END IF;
 INSERT INTO public.arcade_receipt_claims(result_id,owner_auth_user_id,player_profile_id,protocol_version,
 payload,signature,monitor_id,key_id,public_key_sha256,game_id,mode_id,scoring_revision,score,
 device_unix_seconds,metrics,round_counter,verifier_version,event_id)
 VALUES(p_result_id,p_auth_user_id,v_profile,1,decode(p_payload_hex,'hex'),decode(p_signature_hex,'hex'),
 p_monitor_id,p_key_id,decode(p_public_key_sha256_hex,'hex'),p_game_id,p_mode_id,p_scoring_revision,
 p_score,p_device_unix_seconds,p_metrics,null,'receipt-claims-v1',p_event_id)
 ON CONFLICT(result_id) DO NOTHING RETURNING result_id INTO v_inserted;
 IF v_inserted IS NULL THEN RETURN jsonb_build_object('outcome','conflict');END IF;
 INSERT INTO arcade_live_private.arcade_signed_attempts(result_id,profile_id,owner_auth_user_id,
 game_id,mode_id,scoring_revision,score,metrics,event_id,claimed_at)
 VALUES(p_result_id,v_profile,p_auth_user_id,p_game_id,p_mode_id,p_scoring_revision,p_score,p_metrics,p_event_id,v_now);
 INSERT INTO arcade_live_private.arcade_signed_lifetime(profile_id,game_id,mode_id,scoring_revision,
 attempts,sum_scores,sum_raw_points,sum_registered_impacts,sum_center_hits,last_updated)
 VALUES(v_profile,p_game_id,p_mode_id,p_scoring_revision,1,p_score,0,v_shots,v_h,v_now)
 ON CONFLICT(profile_id,game_id,mode_id,scoring_revision) DO UPDATE SET
 attempts=arcade_signed_lifetime.attempts+1,sum_scores=arcade_signed_lifetime.sum_scores+excluded.sum_scores,
 sum_raw_points=arcade_signed_lifetime.sum_raw_points+excluded.sum_raw_points,
 sum_registered_impacts=arcade_signed_lifetime.sum_registered_impacts+excluded.sum_registered_impacts,
 sum_center_hits=arcade_signed_lifetime.sum_center_hits+excluded.sum_center_hits,last_updated=excluded.last_updated;
 INSERT INTO arcade_live_private.arcade_signed_personal_bests(profile_id,game_id,mode_id,scoring_revision,
 best_result_id,score,metrics,achieved_at)
 VALUES(v_profile,p_game_id,p_mode_id,p_scoring_revision,p_result_id,p_score,p_metrics,v_now)
 ON CONFLICT(profile_id,game_id,mode_id,scoring_revision) DO UPDATE SET
 best_result_id=excluded.best_result_id,score=excluded.score,metrics=excluded.metrics,achieved_at=excluded.achieved_at
 WHERE (excluded.score,-(excluded.metrics->>'protected_hits')::integer,
 -(excluded.metrics->>'misses')::integer,-(excluded.metrics->>'time_ms')::integer)>
 (arcade_signed_personal_bests.score,-(arcade_signed_personal_bests.metrics->>'protected_hits')::integer,
 -(arcade_signed_personal_bests.metrics->>'misses')::integer,-(arcade_signed_personal_bests.metrics->>'time_ms')::integer);
 DELETE FROM arcade_live_private.arcade_signed_attempts s WHERE s.profile_id=v_profile AND s.result_id IN
 (SELECT result_id FROM arcade_live_private.arcade_signed_attempts WHERE profile_id=v_profile
 ORDER BY claimed_at DESC,result_id DESC OFFSET 50);
 RETURN jsonb_build_object('outcome','created');
END $function$
;

-- arcade_live_signed_claim_silhouette_v1
CREATE OR REPLACE FUNCTION public.arcade_live_signed_claim_silhouette_v1(p_auth_user_id uuid, p_result_id uuid, p_event_id bigint, p_monitor_id text, p_key_id text, p_payload_hex text, p_signature_hex text, p_payload_sha256_hex text, p_public_key_sha256_hex text, p_game_id text, p_mode_id text, p_scoring_revision integer, p_score integer, p_device_unix_seconds bigint, p_metrics jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
 v_profile uuid; v_key record;v_event record;v_existing record;v_inserted uuid;
 v_n integer;v_shots integer;v_hits integer;v_tens integer;v_chest integer;v_ms integer;
 v_b0 integer;v_b5 integer;v_b8 integer;v_b9 integer;v_b10 integer;
 v_k text;v_value jsonb;v_now timestamptz:=clock_timestamp();
BEGIN
 IF p_auth_user_id IS NULL OR p_result_id IS NULL OR (p_event_id IS NULL OR p_event_id NOT IN (2,3))
 OR (p_monitor_id IS NULL OR p_monitor_id !~ '^[0-9]{2} OR p_game_id IS DISTINCT FROM 'silhouette-precision'
 OR p_mode_id IS NULL OR p_mode_id NOT IN ('standard-10','standard-20','standard-30','timed-10','timed-20','timed-30','precision-10','precision-20','precision-30')
 OR p_scoring_revision IS DISTINCT FROM 1 OR p_score IS NULL OR p_score NOT BETWEEN 0 AND 1000000
 OR p_key_id IS NULL OR p_key_id !~ '^K[0-9A-F]{16}$'
 OR p_device_unix_seconds IS NULL OR p_device_unix_seconds NOT BETWEEN 1704067200 AND 4102444800
 OR p_payload_hex IS NULL OR p_payload_hex !~ '^[0-9a-f]+$' OR length(p_payload_hex) NOT BETWEEN 2 AND 1024 OR length(p_payload_hex)%2<>0
 OR p_signature_hex IS NULL OR p_signature_hex !~ '^[0-9a-f]{128}$'
 OR p_payload_sha256_hex IS NULL OR p_payload_sha256_hex !~ '^[0-9a-f]{64}$'
 OR p_public_key_sha256_hex IS NULL OR p_public_key_sha256_hex !~ '^[0-9a-f]{64}$'
 OR p_metrics IS NULL OR jsonb_typeof(p_metrics)<>'object' OR octet_length(p_metrics::text)>2048
 THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='invalid_silhouette_claim'; END IF;
 IF sha256(decode(p_payload_hex,'hex'))<>decode(p_payload_sha256_hex,'hex')
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='payload_digest_mismatch'; END IF;
 IF (p_metrics - ARRAY['shots','hits','ten_point_hits','center_chest_hits','time_ms','bucket0','bucket5','bucket8','bucket9','bucket10']::text[]) <> '{}'::jsonb
 OR NOT p_metrics ?& ARRAY['shots','hits','ten_point_hits','center_chest_hits','time_ms','bucket0','bucket5','bucket8','bucket9','bucket10']
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='silhouette_metric_shape'; END IF;
 FOR v_k,v_value IN SELECT key,value FROM jsonb_each(p_metrics) LOOP
   IF jsonb_typeof(v_value)<>'number' OR v_value::text !~ '^[0-9]{1,10}$' OR (v_value::text)::bigint>2147483647
   THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='silhouette_metric_value'; END IF;
 END LOOP;
 v_shots:=(p_metrics->>'shots')::integer;v_hits:=(p_metrics->>'hits')::integer;
 v_tens:=(p_metrics->>'ten_point_hits')::integer;v_chest:=(p_metrics->>'center_chest_hits')::integer;
 v_ms:=(p_metrics->>'time_ms')::integer;
 v_b0:=(p_metrics->>'bucket0')::integer;v_b5:=(p_metrics->>'bucket5')::integer;
 v_b8:=(p_metrics->>'bucket8')::integer;v_b9:=(p_metrics->>'bucket9')::integer;
 v_b10:=(p_metrics->>'bucket10')::integer;
 v_n:=split_part(p_mode_id,'-',2)::integer;
 IF v_ms>86400000 OR v_shots>100000 OR v_hits>v_shots OR v_tens>v_hits OR v_chest>v_tens
 OR v_shots <> (v_b0::bigint+v_b5+v_b8+v_b9+v_b10)
 OR v_hits<>v_shots-v_b0 OR v_tens<>v_b10
 OR p_score<>(5::bigint*v_b5+8::bigint*v_b8+9::bigint*v_b9+10::bigint*v_b10)
 OR (p_mode_id NOT LIKE 'timed-%' AND (v_shots<>v_n OR p_score>10*v_n))
 OR (p_mode_id LIKE 'timed-%' AND (v_shots<1 OR v_ms<v_n*1000))
 OR (p_mode_id LIKE 'precision-%' AND (v_b5<>0 OR v_b8<>0 OR v_b9<>0 OR v_tens<>v_chest OR v_chest<>v_hits))
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='silhouette_score_mismatch'; END IF;
 -- Signature and registered-key fingerprint have been checked by Netlify;
 -- independently check key state, event binding, and account eligibility here.
 SELECT k.status,k.public_key_sha256,k.monitor_code INTO v_key
 FROM arcade_live_private.arcade_monitor_signing_keys k WHERE k.key_id=p_key_id FOR SHARE;
 IF NOT FOUND OR v_key.status<>'active' OR v_key.monitor_code<>p_monitor_id
 OR v_key.public_key_sha256<>decode(p_public_key_sha256_hex,'hex')
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='monitor_key_inactive'; END IF;
 SELECT e.state,e.starts_at,e.ends_at,e.pilot_only INTO v_event
 FROM arcade_live_private.arcade_events e
 JOIN arcade_live_private.arcade_event_monitors em ON em.event_id=e.id
 WHERE e.id=p_event_id AND em.monitor_id=p_monitor_id AND em.key_id=p_key_id FOR SHARE OF e;
 IF NOT FOUND OR v_event.state NOT IN ('active','closed') OR ((p_event_id=2 AND v_event.pilot_only IS DISTINCT FROM true) OR (p_event_id=3 AND v_event.pilot_only IS DISTINCT FROM false))
 OR v_now<v_event.starts_at OR v_now>v_event.ends_at+interval '10 days'
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='event_ineligible_or_expired'; END IF;
 SELECT p.id INTO v_profile
 FROM public.arcade_player_profiles p
 JOIN public.arcade_adult_accounts a ON a.auth_user_id=p.owner_auth_user_id
 JOIN public.arcade_profile_permissions pm ON pm.profile_id=p.id AND pm.auth_user_id=p.owner_auth_user_id
 WHERE p.owner_auth_user_id=p_auth_user_id AND p.state='active' AND p.visibility='private'
 AND p.profile_kind='adult_self' AND pm.role='owner' AND pm.status='active'
 AND a.admission_state='approved_adult' LIMIT 1 FOR UPDATE OF p;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='player_not_authorized'; END IF;
 IF p_event_id=2 AND NOT EXISTS(SELECT 1 FROM arcade_live_private.arcade_pilot_claim_allowlist al WHERE al.event_id=p_event_id AND al.profile_id=v_profile)
 THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='pilot_account_not_authorized'; END IF;
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_profile::text,149071));
 SELECT owner_auth_user_id,player_profile_id,encode(payload_sha256,'hex') digest INTO v_existing
 FROM public.arcade_receipt_claims WHERE result_id=p_result_id FOR UPDATE;
 IF FOUND THEN
   IF v_existing.owner_auth_user_id=p_auth_user_id AND v_existing.player_profile_id=v_profile
     AND v_existing.digest=p_payload_sha256_hex THEN RETURN jsonb_build_object('outcome','existing'); END IF;
   RETURN jsonb_build_object('outcome','conflict');
 END IF;
 INSERT INTO public.arcade_receipt_claims(result_id,owner_auth_user_id,player_profile_id,protocol_version,
 payload,signature,monitor_id,key_id,public_key_sha256,game_id,mode_id,scoring_revision,score,
 device_unix_seconds,metrics,round_counter,verifier_version,event_id)
 VALUES(p_result_id,p_auth_user_id,v_profile,1,decode(p_payload_hex,'hex'),decode(p_signature_hex,'hex'),
 p_monitor_id,p_key_id,decode(p_public_key_sha256_hex,'hex'),p_game_id,p_mode_id,p_scoring_revision,
 p_score,p_device_unix_seconds,p_metrics,null,'receipt-claims-v1',p_event_id)
 ON CONFLICT(result_id) DO NOTHING RETURNING result_id INTO v_inserted;
 IF v_inserted IS NULL THEN RETURN jsonb_build_object('outcome','conflict'); END IF;
 INSERT INTO arcade_live_private.arcade_signed_attempts(result_id,profile_id,owner_auth_user_id,
 game_id,mode_id,scoring_revision,score,metrics,event_id,claimed_at)
 VALUES(p_result_id,v_profile,p_auth_user_id,p_game_id,p_mode_id,p_scoring_revision,p_score,p_metrics,p_event_id,v_now);
 INSERT INTO arcade_live_private.arcade_signed_lifetime(profile_id,game_id,mode_id,scoring_revision,
 attempts,sum_scores,sum_raw_points,sum_registered_impacts,sum_center_hits,last_updated)
 VALUES(v_profile,p_game_id,p_mode_id,p_scoring_revision,1,p_score,p_score,v_shots,v_chest,v_now)
 ON CONFLICT(profile_id,game_id,mode_id,scoring_revision) DO UPDATE SET
 attempts=arcade_signed_lifetime.attempts+1,sum_scores=arcade_signed_lifetime.sum_scores+excluded.sum_scores,
 sum_raw_points=arcade_signed_lifetime.sum_raw_points+excluded.sum_raw_points,
 sum_registered_impacts=arcade_signed_lifetime.sum_registered_impacts+excluded.sum_registered_impacts,
 sum_center_hits=arcade_signed_lifetime.sum_center_hits+excluded.sum_center_hits,last_updated=excluded.last_updated;
 INSERT INTO arcade_live_private.arcade_signed_personal_bests(profile_id,game_id,mode_id,scoring_revision,
 best_result_id,score,metrics,achieved_at)
 VALUES(v_profile,p_game_id,p_mode_id,p_scoring_revision,p_result_id,p_score,p_metrics,v_now)
 ON CONFLICT(profile_id,game_id,mode_id,scoring_revision) DO UPDATE SET
 best_result_id=excluded.best_result_id,score=excluded.score,metrics=excluded.metrics,achieved_at=excluded.achieved_at
 WHERE (excluded.score,(excluded.metrics->>'ten_point_hits')::integer,
 (excluded.metrics->>'center_chest_hits')::integer,-(excluded.metrics->>'time_ms')::integer) >
 (arcade_signed_personal_bests.score,(arcade_signed_personal_bests.metrics->>'ten_point_hits')::integer,
 (arcade_signed_personal_bests.metrics->>'center_chest_hits')::integer,-(arcade_signed_personal_bests.metrics->>'time_ms')::integer);
 DELETE FROM arcade_live_private.arcade_signed_attempts s WHERE s.profile_id=v_profile AND s.result_id IN
 (SELECT result_id FROM arcade_live_private.arcade_signed_attempts WHERE profile_id=v_profile
 ORDER BY claimed_at DESC,result_id DESC OFFSET 50);
 RETURN jsonb_build_object('outcome','created');
END $function$
 OR p_monitor_id='00' OR (p_event_id=2 AND p_monitor_id<>'01')) OR p_game_id IS DISTINCT FROM 'silhouette-precision'
 OR p_mode_id IS NULL OR p_mode_id NOT IN ('standard-10','standard-20','standard-30','timed-10','timed-20','timed-30','precision-10','precision-20','precision-30')
 OR p_scoring_revision IS DISTINCT FROM 1 OR p_score IS NULL OR p_score NOT BETWEEN 0 AND 1000000
 OR p_key_id IS NULL OR p_key_id !~ '^K[0-9A-F]{16}$'
 OR p_device_unix_seconds IS NULL OR p_device_unix_seconds NOT BETWEEN 1704067200 AND 4102444800
 OR p_payload_hex IS NULL OR p_payload_hex !~ '^[0-9a-f]+$' OR length(p_payload_hex) NOT BETWEEN 2 AND 1024 OR length(p_payload_hex)%2<>0
 OR p_signature_hex IS NULL OR p_signature_hex !~ '^[0-9a-f]{128}$'
 OR p_payload_sha256_hex IS NULL OR p_payload_sha256_hex !~ '^[0-9a-f]{64}$'
 OR p_public_key_sha256_hex IS NULL OR p_public_key_sha256_hex !~ '^[0-9a-f]{64}$'
 OR p_metrics IS NULL OR jsonb_typeof(p_metrics)<>'object' OR octet_length(p_metrics::text)>2048
 THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='invalid_silhouette_claim'; END IF;
 IF sha256(decode(p_payload_hex,'hex'))<>decode(p_payload_sha256_hex,'hex')
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='payload_digest_mismatch'; END IF;
 IF (p_metrics - ARRAY['shots','hits','ten_point_hits','center_chest_hits','time_ms','bucket0','bucket5','bucket8','bucket9','bucket10']::text[]) <> '{}'::jsonb
 OR NOT p_metrics ?& ARRAY['shots','hits','ten_point_hits','center_chest_hits','time_ms','bucket0','bucket5','bucket8','bucket9','bucket10']
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='silhouette_metric_shape'; END IF;
 FOR v_k,v_value IN SELECT key,value FROM jsonb_each(p_metrics) LOOP
   IF jsonb_typeof(v_value)<>'number' OR v_value::text !~ '^[0-9]{1,10}$' OR (v_value::text)::bigint>2147483647
   THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='silhouette_metric_value'; END IF;
 END LOOP;
 v_shots:=(p_metrics->>'shots')::integer;v_hits:=(p_metrics->>'hits')::integer;
 v_tens:=(p_metrics->>'ten_point_hits')::integer;v_chest:=(p_metrics->>'center_chest_hits')::integer;
 v_ms:=(p_metrics->>'time_ms')::integer;
 v_b0:=(p_metrics->>'bucket0')::integer;v_b5:=(p_metrics->>'bucket5')::integer;
 v_b8:=(p_metrics->>'bucket8')::integer;v_b9:=(p_metrics->>'bucket9')::integer;
 v_b10:=(p_metrics->>'bucket10')::integer;
 v_n:=split_part(p_mode_id,'-',2)::integer;
 IF v_ms>86400000 OR v_shots>100000 OR v_hits>v_shots OR v_tens>v_hits OR v_chest>v_tens
 OR v_shots <> (v_b0::bigint+v_b5+v_b8+v_b9+v_b10)
 OR v_hits<>v_shots-v_b0 OR v_tens<>v_b10
 OR p_score<>(5::bigint*v_b5+8::bigint*v_b8+9::bigint*v_b9+10::bigint*v_b10)
 OR (p_mode_id NOT LIKE 'timed-%' AND (v_shots<>v_n OR p_score>10*v_n))
 OR (p_mode_id LIKE 'timed-%' AND (v_shots<1 OR v_ms<v_n*1000))
 OR (p_mode_id LIKE 'precision-%' AND (v_b5<>0 OR v_b8<>0 OR v_b9<>0 OR v_tens<>v_chest OR v_chest<>v_hits))
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='silhouette_score_mismatch'; END IF;
 -- Signature and registered-key fingerprint have been checked by Netlify;
 -- independently check key state, event binding, and account eligibility here.
 SELECT k.status,k.public_key_sha256,k.monitor_code INTO v_key
 FROM arcade_live_private.arcade_monitor_signing_keys k WHERE k.key_id=p_key_id FOR SHARE;
 IF NOT FOUND OR v_key.status<>'active' OR v_key.monitor_code<>p_monitor_id
 OR v_key.public_key_sha256<>decode(p_public_key_sha256_hex,'hex')
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='monitor_key_inactive'; END IF;
 SELECT e.state,e.starts_at,e.ends_at,e.pilot_only INTO v_event
 FROM arcade_live_private.arcade_events e
 JOIN arcade_live_private.arcade_event_monitors em ON em.event_id=e.id
 WHERE e.id=p_event_id AND em.monitor_id=p_monitor_id AND em.key_id=p_key_id FOR SHARE OF e;
 IF NOT FOUND OR v_event.state NOT IN ('active','closed') OR ((p_event_id=2 AND v_event.pilot_only IS DISTINCT FROM true) OR (p_event_id=3 AND v_event.pilot_only IS DISTINCT FROM false))
 OR v_now<v_event.starts_at OR v_now>v_event.ends_at+interval '10 days'
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='event_ineligible_or_expired'; END IF;
 SELECT p.id INTO v_profile
 FROM public.arcade_player_profiles p
 JOIN public.arcade_adult_accounts a ON a.auth_user_id=p.owner_auth_user_id
 JOIN public.arcade_profile_permissions pm ON pm.profile_id=p.id AND pm.auth_user_id=p.owner_auth_user_id
 WHERE p.owner_auth_user_id=p_auth_user_id AND p.state='active' AND p.visibility='private'
 AND p.profile_kind='adult_self' AND pm.role='owner' AND pm.status='active'
 AND a.admission_state='approved_adult' LIMIT 1 FOR UPDATE OF p;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='player_not_authorized'; END IF;
 IF p_event_id=2 AND NOT EXISTS(SELECT 1 FROM arcade_live_private.arcade_pilot_claim_allowlist al WHERE al.event_id=p_event_id AND al.profile_id=v_profile)
 THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='pilot_account_not_authorized'; END IF;
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_profile::text,149071));
 SELECT owner_auth_user_id,player_profile_id,encode(payload_sha256,'hex') digest INTO v_existing
 FROM public.arcade_receipt_claims WHERE result_id=p_result_id FOR UPDATE;
 IF FOUND THEN
   IF v_existing.owner_auth_user_id=p_auth_user_id AND v_existing.player_profile_id=v_profile
     AND v_existing.digest=p_payload_sha256_hex THEN RETURN jsonb_build_object('outcome','existing'); END IF;
   RETURN jsonb_build_object('outcome','conflict');
 END IF;
 INSERT INTO public.arcade_receipt_claims(result_id,owner_auth_user_id,player_profile_id,protocol_version,
 payload,signature,monitor_id,key_id,public_key_sha256,game_id,mode_id,scoring_revision,score,
 device_unix_seconds,metrics,round_counter,verifier_version,event_id)
 VALUES(p_result_id,p_auth_user_id,v_profile,1,decode(p_payload_hex,'hex'),decode(p_signature_hex,'hex'),
 p_monitor_id,p_key_id,decode(p_public_key_sha256_hex,'hex'),p_game_id,p_mode_id,p_scoring_revision,
 p_score,p_device_unix_seconds,p_metrics,null,'receipt-claims-v1',p_event_id)
 ON CONFLICT(result_id) DO NOTHING RETURNING result_id INTO v_inserted;
 IF v_inserted IS NULL THEN RETURN jsonb_build_object('outcome','conflict'); END IF;
 INSERT INTO arcade_live_private.arcade_signed_attempts(result_id,profile_id,owner_auth_user_id,
 game_id,mode_id,scoring_revision,score,metrics,event_id,claimed_at)
 VALUES(p_result_id,v_profile,p_auth_user_id,p_game_id,p_mode_id,p_scoring_revision,p_score,p_metrics,p_event_id,v_now);
 INSERT INTO arcade_live_private.arcade_signed_lifetime(profile_id,game_id,mode_id,scoring_revision,
 attempts,sum_scores,sum_raw_points,sum_registered_impacts,sum_center_hits,last_updated)
 VALUES(v_profile,p_game_id,p_mode_id,p_scoring_revision,1,p_score,p_score,v_shots,v_chest,v_now)
 ON CONFLICT(profile_id,game_id,mode_id,scoring_revision) DO UPDATE SET
 attempts=arcade_signed_lifetime.attempts+1,sum_scores=arcade_signed_lifetime.sum_scores+excluded.sum_scores,
 sum_raw_points=arcade_signed_lifetime.sum_raw_points+excluded.sum_raw_points,
 sum_registered_impacts=arcade_signed_lifetime.sum_registered_impacts+excluded.sum_registered_impacts,
 sum_center_hits=arcade_signed_lifetime.sum_center_hits+excluded.sum_center_hits,last_updated=excluded.last_updated;
 INSERT INTO arcade_live_private.arcade_signed_personal_bests(profile_id,game_id,mode_id,scoring_revision,
 best_result_id,score,metrics,achieved_at)
 VALUES(v_profile,p_game_id,p_mode_id,p_scoring_revision,p_result_id,p_score,p_metrics,v_now)
 ON CONFLICT(profile_id,game_id,mode_id,scoring_revision) DO UPDATE SET
 best_result_id=excluded.best_result_id,score=excluded.score,metrics=excluded.metrics,achieved_at=excluded.achieved_at
 WHERE (excluded.score,(excluded.metrics->>'ten_point_hits')::integer,
 (excluded.metrics->>'center_chest_hits')::integer,-(excluded.metrics->>'time_ms')::integer) >
 (arcade_signed_personal_bests.score,(arcade_signed_personal_bests.metrics->>'ten_point_hits')::integer,
 (arcade_signed_personal_bests.metrics->>'center_chest_hits')::integer,-(arcade_signed_personal_bests.metrics->>'time_ms')::integer);
 DELETE FROM arcade_live_private.arcade_signed_attempts s WHERE s.profile_id=v_profile AND s.result_id IN
 (SELECT result_id FROM arcade_live_private.arcade_signed_attempts WHERE profile_id=v_profile
 ORDER BY claimed_at DESC,result_id DESC OFFSET 50);
 RETURN jsonb_build_object('outcome','created');
END $function$
;

-- arcade_live_signed_claim_silhouette_v2
CREATE OR REPLACE FUNCTION public.arcade_live_signed_claim_silhouette_v2(p_auth_user_id uuid, p_result_id uuid, p_event_id bigint, p_monitor_id text, p_key_id text, p_payload_hex text, p_signature_hex text, p_payload_sha256_hex text, p_public_key_sha256_hex text, p_game_id text, p_mode_id text, p_scoring_revision integer, p_score integer, p_device_unix_seconds bigint, p_metrics jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
 v_profile uuid; v_key record;v_event record;v_existing record;v_inserted uuid;
 v_n integer;v_shots integer;v_hits integer;v_tens integer;v_chest integer;v_ms integer;
 v_group integer;
 v_k text;v_value jsonb;v_now timestamptz:=clock_timestamp();
BEGIN
 IF p_auth_user_id IS NULL OR p_result_id IS NULL OR (p_event_id IS NULL OR p_event_id NOT IN (2,3))
 OR (p_monitor_id IS NULL OR p_monitor_id !~ '^[0-9]{2} OR p_game_id IS DISTINCT FROM 'silhouette-precision'
 OR p_mode_id IS NULL OR p_mode_id NOT IN ('standard-10','standard-20','standard-30','timed-10','timed-20','timed-30','precision-10','precision-20','precision-30')
 OR p_scoring_revision IS DISTINCT FROM 2 OR p_score IS NULL OR p_score NOT BETWEEN 0 AND 300
 OR p_key_id IS NULL OR p_key_id !~ '^K[0-9A-F]{16}$'
 OR p_device_unix_seconds IS NULL OR p_device_unix_seconds NOT BETWEEN 1704067200 AND 4102444800
 OR p_payload_hex IS NULL OR p_payload_hex !~ '^[0-9a-f]+$' OR length(p_payload_hex) NOT BETWEEN 2 AND 1024 OR length(p_payload_hex)%2<>0
 OR p_signature_hex IS NULL OR p_signature_hex !~ '^[0-9a-f]{128}$'
 OR p_payload_sha256_hex IS NULL OR p_payload_sha256_hex !~ '^[0-9a-f]{64}$'
 OR p_public_key_sha256_hex IS NULL OR p_public_key_sha256_hex !~ '^[0-9a-f]{64}$'
 OR p_metrics IS NULL OR jsonb_typeof(p_metrics)<>'object' OR octet_length(p_metrics::text)>2048
 THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='invalid_silhouette_claim'; END IF;
 IF sha256(decode(p_payload_hex,'hex'))<>decode(p_payload_sha256_hex,'hex')
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='payload_digest_mismatch'; END IF;
 IF (p_metrics - ARRAY['shots','hits','ten_point_hits','center_chest_hits','time_ms','grouping_rating']::text[]) <> '{}'::jsonb
 OR NOT p_metrics ?& ARRAY['shots','hits','ten_point_hits','center_chest_hits','time_ms','grouping_rating']
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='silhouette_r2_metric_shape'; END IF;
 FOR v_k,v_value IN SELECT key,value FROM jsonb_each(p_metrics) LOOP
   IF jsonb_typeof(v_value)<>'number' OR v_value::text !~ '^[0-9]{1,10}$' OR (v_value::text)::bigint>2147483647
   THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='silhouette_r2_metric_value'; END IF;
 END LOOP;
 v_shots:=(p_metrics->>'shots')::integer;v_hits:=(p_metrics->>'hits')::integer;
 v_tens:=(p_metrics->>'ten_point_hits')::integer;v_chest:=(p_metrics->>'center_chest_hits')::integer;
 v_ms:=(p_metrics->>'time_ms')::integer; v_group:=(p_metrics->>'grouping_rating')::integer;
 v_n:=split_part(p_mode_id,'-',2)::integer;
 IF v_ms>86400000 OR v_shots>100000 OR v_hits>v_shots OR v_tens>v_hits OR v_chest>v_tens
 OR v_group>1000 OR p_score>300
 OR (p_mode_id NOT LIKE 'timed-%' AND v_shots<>v_n)
 OR (p_mode_id LIKE 'timed-%' AND (v_shots<1 OR v_ms<v_n*1000))
 OR (p_mode_id LIKE 'precision-%' AND v_tens<>v_hits)
 OR (v_hits=0 AND (p_score<>0 OR v_group<>0))
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='silhouette_r2_metric_bounds'; END IF;
 -- Signature and registered-key fingerprint have been checked by Netlify;
 -- independently check key state, event binding, and account eligibility here.
 SELECT k.status,k.public_key_sha256,k.monitor_code INTO v_key
 FROM arcade_live_private.arcade_monitor_signing_keys k WHERE k.key_id=p_key_id FOR SHARE;
 IF NOT FOUND OR v_key.status<>'active' OR v_key.monitor_code<>p_monitor_id
 OR v_key.public_key_sha256<>decode(p_public_key_sha256_hex,'hex')
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='monitor_key_inactive'; END IF;
 SELECT e.state,e.starts_at,e.ends_at,e.pilot_only INTO v_event
 FROM arcade_live_private.arcade_events e
 JOIN arcade_live_private.arcade_event_monitors em ON em.event_id=e.id
 WHERE e.id=p_event_id AND em.monitor_id=p_monitor_id AND em.key_id=p_key_id FOR SHARE OF e;
 IF NOT FOUND OR v_event.state NOT IN ('active','closed') OR ((p_event_id=2 AND v_event.pilot_only IS DISTINCT FROM true) OR (p_event_id=3 AND v_event.pilot_only IS DISTINCT FROM false))
 OR v_now<v_event.starts_at OR v_now>v_event.ends_at+interval '10 days'
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='event_ineligible_or_expired'; END IF;
 SELECT p.id INTO v_profile
 FROM public.arcade_player_profiles p
 JOIN public.arcade_adult_accounts a ON a.auth_user_id=p.owner_auth_user_id
 JOIN public.arcade_profile_permissions pm ON pm.profile_id=p.id AND pm.auth_user_id=p.owner_auth_user_id
 WHERE p.owner_auth_user_id=p_auth_user_id AND p.state='active' AND p.visibility='private'
 AND p.profile_kind='adult_self' AND pm.role='owner' AND pm.status='active'
 AND a.admission_state='approved_adult' LIMIT 1 FOR UPDATE OF p;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='player_not_authorized'; END IF;
 IF p_event_id=2 AND NOT EXISTS(SELECT 1 FROM arcade_live_private.arcade_pilot_claim_allowlist al WHERE al.event_id=p_event_id AND al.profile_id=v_profile)
 THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='pilot_account_not_authorized'; END IF;
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_profile::text,149071));
 SELECT owner_auth_user_id,player_profile_id,encode(payload_sha256,'hex') digest INTO v_existing
 FROM public.arcade_receipt_claims WHERE result_id=p_result_id FOR UPDATE;
 IF FOUND THEN
   IF v_existing.owner_auth_user_id=p_auth_user_id AND v_existing.player_profile_id=v_profile
     AND v_existing.digest=p_payload_sha256_hex THEN RETURN jsonb_build_object('outcome','existing'); END IF;
   RETURN jsonb_build_object('outcome','conflict');
 END IF;
 INSERT INTO public.arcade_receipt_claims(result_id,owner_auth_user_id,player_profile_id,protocol_version,
 payload,signature,monitor_id,key_id,public_key_sha256,game_id,mode_id,scoring_revision,score,
 device_unix_seconds,metrics,round_counter,verifier_version,event_id)
 VALUES(p_result_id,p_auth_user_id,v_profile,1,decode(p_payload_hex,'hex'),decode(p_signature_hex,'hex'),
 p_monitor_id,p_key_id,decode(p_public_key_sha256_hex,'hex'),p_game_id,p_mode_id,p_scoring_revision,
 p_score,p_device_unix_seconds,p_metrics,null,'receipt-claims-v1',p_event_id)
 ON CONFLICT(result_id) DO NOTHING RETURNING result_id INTO v_inserted;
 IF v_inserted IS NULL THEN RETURN jsonb_build_object('outcome','conflict'); END IF;
 INSERT INTO arcade_live_private.arcade_signed_attempts(result_id,profile_id,owner_auth_user_id,
 game_id,mode_id,scoring_revision,score,metrics,event_id,claimed_at)
 VALUES(p_result_id,v_profile,p_auth_user_id,p_game_id,p_mode_id,p_scoring_revision,p_score,p_metrics,p_event_id,v_now);
 INSERT INTO arcade_live_private.arcade_signed_lifetime(profile_id,game_id,mode_id,scoring_revision,
 attempts,sum_scores,sum_raw_points,sum_registered_impacts,sum_center_hits,last_updated)
 VALUES(v_profile,p_game_id,p_mode_id,p_scoring_revision,1,p_score,0,v_shots,v_chest,v_now)
 ON CONFLICT(profile_id,game_id,mode_id,scoring_revision) DO UPDATE SET
 attempts=arcade_signed_lifetime.attempts+1,sum_scores=arcade_signed_lifetime.sum_scores+excluded.sum_scores,
 sum_raw_points=arcade_signed_lifetime.sum_raw_points+excluded.sum_raw_points,
 sum_registered_impacts=arcade_signed_lifetime.sum_registered_impacts+excluded.sum_registered_impacts,
 sum_center_hits=arcade_signed_lifetime.sum_center_hits+excluded.sum_center_hits,last_updated=excluded.last_updated;
 INSERT INTO arcade_live_private.arcade_signed_personal_bests(profile_id,game_id,mode_id,scoring_revision,
 best_result_id,score,metrics,achieved_at)
 VALUES(v_profile,p_game_id,p_mode_id,p_scoring_revision,p_result_id,p_score,p_metrics,v_now)
 ON CONFLICT(profile_id,game_id,mode_id,scoring_revision) DO UPDATE SET
 best_result_id=excluded.best_result_id,score=excluded.score,metrics=excluded.metrics,achieved_at=excluded.achieved_at
 WHERE (excluded.score,(excluded.metrics->>'ten_point_hits')::integer,
 (excluded.metrics->>'center_chest_hits')::integer,(excluded.metrics->>'grouping_rating')::integer,-(excluded.metrics->>'time_ms')::integer) >
 (arcade_signed_personal_bests.score,(arcade_signed_personal_bests.metrics->>'ten_point_hits')::integer,
 (arcade_signed_personal_bests.metrics->>'center_chest_hits')::integer,
 (arcade_signed_personal_bests.metrics->>'grouping_rating')::integer,-(arcade_signed_personal_bests.metrics->>'time_ms')::integer);
 DELETE FROM arcade_live_private.arcade_signed_attempts s WHERE s.profile_id=v_profile AND s.result_id IN
 (SELECT result_id FROM arcade_live_private.arcade_signed_attempts WHERE profile_id=v_profile
 ORDER BY claimed_at DESC,result_id DESC OFFSET 50);
 RETURN jsonb_build_object('outcome','created');
END $function$
 OR p_monitor_id='00' OR (p_event_id=2 AND p_monitor_id<>'01')) OR p_game_id IS DISTINCT FROM 'silhouette-precision'
 OR p_mode_id IS NULL OR p_mode_id NOT IN ('standard-10','standard-20','standard-30','timed-10','timed-20','timed-30','precision-10','precision-20','precision-30')
 OR p_scoring_revision IS DISTINCT FROM 2 OR p_score IS NULL OR p_score NOT BETWEEN 0 AND 300
 OR p_key_id IS NULL OR p_key_id !~ '^K[0-9A-F]{16}$'
 OR p_device_unix_seconds IS NULL OR p_device_unix_seconds NOT BETWEEN 1704067200 AND 4102444800
 OR p_payload_hex IS NULL OR p_payload_hex !~ '^[0-9a-f]+$' OR length(p_payload_hex) NOT BETWEEN 2 AND 1024 OR length(p_payload_hex)%2<>0
 OR p_signature_hex IS NULL OR p_signature_hex !~ '^[0-9a-f]{128}$'
 OR p_payload_sha256_hex IS NULL OR p_payload_sha256_hex !~ '^[0-9a-f]{64}$'
 OR p_public_key_sha256_hex IS NULL OR p_public_key_sha256_hex !~ '^[0-9a-f]{64}$'
 OR p_metrics IS NULL OR jsonb_typeof(p_metrics)<>'object' OR octet_length(p_metrics::text)>2048
 THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='invalid_silhouette_claim'; END IF;
 IF sha256(decode(p_payload_hex,'hex'))<>decode(p_payload_sha256_hex,'hex')
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='payload_digest_mismatch'; END IF;
 IF (p_metrics - ARRAY['shots','hits','ten_point_hits','center_chest_hits','time_ms','grouping_rating']::text[]) <> '{}'::jsonb
 OR NOT p_metrics ?& ARRAY['shots','hits','ten_point_hits','center_chest_hits','time_ms','grouping_rating']
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='silhouette_r2_metric_shape'; END IF;
 FOR v_k,v_value IN SELECT key,value FROM jsonb_each(p_metrics) LOOP
   IF jsonb_typeof(v_value)<>'number' OR v_value::text !~ '^[0-9]{1,10}$' OR (v_value::text)::bigint>2147483647
   THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='silhouette_r2_metric_value'; END IF;
 END LOOP;
 v_shots:=(p_metrics->>'shots')::integer;v_hits:=(p_metrics->>'hits')::integer;
 v_tens:=(p_metrics->>'ten_point_hits')::integer;v_chest:=(p_metrics->>'center_chest_hits')::integer;
 v_ms:=(p_metrics->>'time_ms')::integer; v_group:=(p_metrics->>'grouping_rating')::integer;
 v_n:=split_part(p_mode_id,'-',2)::integer;
 IF v_ms>86400000 OR v_shots>100000 OR v_hits>v_shots OR v_tens>v_hits OR v_chest>v_tens
 OR v_group>1000 OR p_score>300
 OR (p_mode_id NOT LIKE 'timed-%' AND v_shots<>v_n)
 OR (p_mode_id LIKE 'timed-%' AND (v_shots<1 OR v_ms<v_n*1000))
 OR (p_mode_id LIKE 'precision-%' AND v_tens<>v_hits)
 OR (v_hits=0 AND (p_score<>0 OR v_group<>0))
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='silhouette_r2_metric_bounds'; END IF;
 -- Signature and registered-key fingerprint have been checked by Netlify;
 -- independently check key state, event binding, and account eligibility here.
 SELECT k.status,k.public_key_sha256,k.monitor_code INTO v_key
 FROM arcade_live_private.arcade_monitor_signing_keys k WHERE k.key_id=p_key_id FOR SHARE;
 IF NOT FOUND OR v_key.status<>'active' OR v_key.monitor_code<>p_monitor_id
 OR v_key.public_key_sha256<>decode(p_public_key_sha256_hex,'hex')
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='monitor_key_inactive'; END IF;
 SELECT e.state,e.starts_at,e.ends_at,e.pilot_only INTO v_event
 FROM arcade_live_private.arcade_events e
 JOIN arcade_live_private.arcade_event_monitors em ON em.event_id=e.id
 WHERE e.id=p_event_id AND em.monitor_id=p_monitor_id AND em.key_id=p_key_id FOR SHARE OF e;
 IF NOT FOUND OR v_event.state NOT IN ('active','closed') OR ((p_event_id=2 AND v_event.pilot_only IS DISTINCT FROM true) OR (p_event_id=3 AND v_event.pilot_only IS DISTINCT FROM false))
 OR v_now<v_event.starts_at OR v_now>v_event.ends_at+interval '10 days'
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='event_ineligible_or_expired'; END IF;
 SELECT p.id INTO v_profile
 FROM public.arcade_player_profiles p
 JOIN public.arcade_adult_accounts a ON a.auth_user_id=p.owner_auth_user_id
 JOIN public.arcade_profile_permissions pm ON pm.profile_id=p.id AND pm.auth_user_id=p.owner_auth_user_id
 WHERE p.owner_auth_user_id=p_auth_user_id AND p.state='active' AND p.visibility='private'
 AND p.profile_kind='adult_self' AND pm.role='owner' AND pm.status='active'
 AND a.admission_state='approved_adult' LIMIT 1 FOR UPDATE OF p;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='player_not_authorized'; END IF;
 IF p_event_id=2 AND NOT EXISTS(SELECT 1 FROM arcade_live_private.arcade_pilot_claim_allowlist al WHERE al.event_id=p_event_id AND al.profile_id=v_profile)
 THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='pilot_account_not_authorized'; END IF;
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_profile::text,149071));
 SELECT owner_auth_user_id,player_profile_id,encode(payload_sha256,'hex') digest INTO v_existing
 FROM public.arcade_receipt_claims WHERE result_id=p_result_id FOR UPDATE;
 IF FOUND THEN
   IF v_existing.owner_auth_user_id=p_auth_user_id AND v_existing.player_profile_id=v_profile
     AND v_existing.digest=p_payload_sha256_hex THEN RETURN jsonb_build_object('outcome','existing'); END IF;
   RETURN jsonb_build_object('outcome','conflict');
 END IF;
 INSERT INTO public.arcade_receipt_claims(result_id,owner_auth_user_id,player_profile_id,protocol_version,
 payload,signature,monitor_id,key_id,public_key_sha256,game_id,mode_id,scoring_revision,score,
 device_unix_seconds,metrics,round_counter,verifier_version,event_id)
 VALUES(p_result_id,p_auth_user_id,v_profile,1,decode(p_payload_hex,'hex'),decode(p_signature_hex,'hex'),
 p_monitor_id,p_key_id,decode(p_public_key_sha256_hex,'hex'),p_game_id,p_mode_id,p_scoring_revision,
 p_score,p_device_unix_seconds,p_metrics,null,'receipt-claims-v1',p_event_id)
 ON CONFLICT(result_id) DO NOTHING RETURNING result_id INTO v_inserted;
 IF v_inserted IS NULL THEN RETURN jsonb_build_object('outcome','conflict'); END IF;
 INSERT INTO arcade_live_private.arcade_signed_attempts(result_id,profile_id,owner_auth_user_id,
 game_id,mode_id,scoring_revision,score,metrics,event_id,claimed_at)
 VALUES(p_result_id,v_profile,p_auth_user_id,p_game_id,p_mode_id,p_scoring_revision,p_score,p_metrics,p_event_id,v_now);
 INSERT INTO arcade_live_private.arcade_signed_lifetime(profile_id,game_id,mode_id,scoring_revision,
 attempts,sum_scores,sum_raw_points,sum_registered_impacts,sum_center_hits,last_updated)
 VALUES(v_profile,p_game_id,p_mode_id,p_scoring_revision,1,p_score,0,v_shots,v_chest,v_now)
 ON CONFLICT(profile_id,game_id,mode_id,scoring_revision) DO UPDATE SET
 attempts=arcade_signed_lifetime.attempts+1,sum_scores=arcade_signed_lifetime.sum_scores+excluded.sum_scores,
 sum_raw_points=arcade_signed_lifetime.sum_raw_points+excluded.sum_raw_points,
 sum_registered_impacts=arcade_signed_lifetime.sum_registered_impacts+excluded.sum_registered_impacts,
 sum_center_hits=arcade_signed_lifetime.sum_center_hits+excluded.sum_center_hits,last_updated=excluded.last_updated;
 INSERT INTO arcade_live_private.arcade_signed_personal_bests(profile_id,game_id,mode_id,scoring_revision,
 best_result_id,score,metrics,achieved_at)
 VALUES(v_profile,p_game_id,p_mode_id,p_scoring_revision,p_result_id,p_score,p_metrics,v_now)
 ON CONFLICT(profile_id,game_id,mode_id,scoring_revision) DO UPDATE SET
 best_result_id=excluded.best_result_id,score=excluded.score,metrics=excluded.metrics,achieved_at=excluded.achieved_at
 WHERE (excluded.score,(excluded.metrics->>'ten_point_hits')::integer,
 (excluded.metrics->>'center_chest_hits')::integer,(excluded.metrics->>'grouping_rating')::integer,-(excluded.metrics->>'time_ms')::integer) >
 (arcade_signed_personal_bests.score,(arcade_signed_personal_bests.metrics->>'ten_point_hits')::integer,
 (arcade_signed_personal_bests.metrics->>'center_chest_hits')::integer,
 (arcade_signed_personal_bests.metrics->>'grouping_rating')::integer,-(arcade_signed_personal_bests.metrics->>'time_ms')::integer);
 DELETE FROM arcade_live_private.arcade_signed_attempts s WHERE s.profile_id=v_profile AND s.result_id IN
 (SELECT result_id FROM arcade_live_private.arcade_signed_attempts WHERE profile_id=v_profile
 ORDER BY claimed_at DESC,result_id DESC OFFSET 50);
 RETURN jsonb_build_object('outcome','created');
END $function$
;

-- arcade_live_signed_claim_wildhunt_v1
CREATE OR REPLACE FUNCTION public.arcade_live_signed_claim_wildhunt_v1(p_auth_user_id uuid, p_result_id uuid, p_event_id bigint, p_monitor_id text, p_key_id text, p_payload_hex text, p_signature_hex text, p_payload_sha256_hex text, p_public_key_sha256_hex text, p_game_id text, p_mode_id text, p_scoring_revision integer, p_score integer, p_device_unix_seconds bigint, p_metrics jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_profile uuid;v_key record;v_event record;v_existing record;v_inserted uuid;
 v_imp integer;v_hit integer;v_vital integer;v_pro integer;v_miss integer;
 v_stage integer;v_win integer;v_time integer;v_har integer;v_cov integer;
 v_base integer;v_sq integer;v_cap integer;v_harvest_goal integer;v_now timestamptz:=clock_timestamp();
 v_k text;v_val jsonb;
BEGIN
 IF p_auth_user_id IS NULL OR p_result_id IS NULL OR (p_event_id IS NULL OR p_event_id NOT IN (2,3))
 OR (p_monitor_id IS NULL OR p_monitor_id !~ '^[0-9]{2} OR p_game_id IS DISTINCT FROM 'wild-hunt'
 OR p_mode_id IS NULL OR p_mode_id NOT IN ('easy','medium','hard')
 OR p_scoring_revision IS DISTINCT FROM 1
 OR p_score IS NULL OR p_score<0 OR
 (p_mode_id='hard' AND p_score>100000)
 OR p_key_id IS NULL OR p_key_id !~ '^K[0-9A-F]{16}$'
 OR p_device_unix_seconds IS NULL OR p_device_unix_seconds NOT BETWEEN 1704067200 AND 4102444800
 OR p_payload_hex IS NULL OR p_payload_hex !~ '^[0-9a-f]+$'
 OR length(p_payload_hex) NOT BETWEEN 2 AND 1024 OR length(p_payload_hex)%2<>0
 OR p_signature_hex IS NULL OR p_signature_hex !~ '^[0-9a-f]{128}$'
 OR p_payload_sha256_hex IS NULL OR p_payload_sha256_hex !~ '^[0-9a-f]{64}$'
 OR p_public_key_sha256_hex IS NULL OR p_public_key_sha256_hex !~ '^[0-9a-f]{64}$'
 OR p_metrics IS NULL OR jsonb_typeof(p_metrics)<>'object' OR octet_length(p_metrics::text)>2048
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_wildhunt_claim';END IF;
 IF pg_catalog.sha256(pg_catalog.decode(p_payload_hex,'hex'))<>pg_catalog.decode(p_payload_sha256_hex,'hex')
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='payload_digest_mismatch';END IF;
 IF (p_metrics-ARRAY['imp','hit','vital','pro','miss','stage','win','time','har','cov','base','sq']::text[])<>'{}'::jsonb
 OR NOT p_metrics ?& ARRAY['imp','hit','vital','pro','miss','stage','win','time','har','cov','base','sq']

 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='wildhunt_metric_shape';END IF;
 FOR v_k,v_val IN SELECT key,value FROM jsonb_each(p_metrics) LOOP
   IF jsonb_typeof(v_val)<>'number' OR v_val::text !~ '^[0-9]{1,10}$' OR (v_val::text)::bigint>2147483647
   THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='wildhunt_metric_value';END IF;
 END LOOP;
 v_imp:=(p_metrics->>'imp')::integer;v_hit:=(p_metrics->>'hit')::integer;
 v_vital:=(p_metrics->>'vital')::integer;v_pro:=(p_metrics->>'pro')::integer;
 v_miss:=(p_metrics->>'miss')::integer;v_stage:=(p_metrics->>'stage')::integer;
 v_win:=(p_metrics->>'win')::integer;v_time:=(p_metrics->>'time')::integer;
 v_har:=(p_metrics->>'har')::integer;v_cov:=(p_metrics->>'cov')::integer;
 v_base:=(p_metrics->>'base')::integer;v_sq:=(p_metrics->>'sq')::integer;
 v_cap:=CASE p_mode_id WHEN 'easy' THEN 250 WHEN 'medium' THEN 125 ELSE 100 END;
 v_harvest_goal:=CASE WHEN p_mode_id='hard' THEN 50 ELSE 25 END;
 IF v_imp NOT BETWEEN v_harvest_goal AND v_cap OR
   v_hit>v_imp OR v_vital>v_hit OR v_har>v_hit OR
   v_imp::bigint<>v_hit::bigint+v_pro+v_miss+v_cov OR
   v_stage<>5 OR v_win<>1 OR v_har<>v_harvest_goal OR
   v_time>2147483647 OR
   p_score::bigint<>v_base::bigint+v_sq::bigint-(150::bigint*v_pro) OR
   (p_mode_id='hard' AND (v_imp NOT BETWEEN 50 AND 100 OR v_hit<50 OR v_har<>50))
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='wildhunt_metric_bounds';END IF;
 SELECT status,public_key_sha256,monitor_code INTO v_key
 FROM arcade_live_private.arcade_monitor_signing_keys WHERE key_id=p_key_id FOR SHARE;
 IF NOT FOUND OR v_key.status<>'active' OR v_key.monitor_code<>p_monitor_id OR
 v_key.public_key_sha256<>pg_catalog.decode(p_public_key_sha256_hex,'hex')
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='monitor_key_inactive';END IF;
 SELECT e.state,e.starts_at,e.ends_at,e.pilot_only INTO v_event
 FROM arcade_live_private.arcade_events e JOIN arcade_live_private.arcade_event_monitors em
 ON em.event_id=e.id WHERE e.id=p_event_id AND em.monitor_id=p_monitor_id AND em.key_id=p_key_id
 FOR SHARE OF e;
 IF NOT FOUND OR v_event.state NOT IN ('active','closed') OR ((p_event_id=2 AND v_event.pilot_only IS DISTINCT FROM true) OR (p_event_id=3 AND v_event.pilot_only IS DISTINCT FROM false)) OR
 v_now<v_event.starts_at OR v_now>v_event.ends_at+interval '10 days'
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='event_ineligible_or_expired';END IF;
 SELECT p.id INTO v_profile FROM public.arcade_player_profiles p
 JOIN public.arcade_adult_accounts a ON a.auth_user_id=p.owner_auth_user_id
 JOIN public.arcade_profile_permissions pm ON pm.profile_id=p.id AND pm.auth_user_id=p.owner_auth_user_id
 WHERE p.owner_auth_user_id=p_auth_user_id AND p.state='active' AND p.visibility='private'
 AND p.profile_kind='adult_self' AND pm.role='owner' AND pm.status='active'
 AND a.admission_state='approved_adult' LIMIT 1 FOR UPDATE OF p;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='player_not_authorized';END IF;
 IF p_event_id=2 AND NOT EXISTS(SELECT 1 FROM arcade_live_private.arcade_pilot_claim_allowlist al
   WHERE al.event_id=p_event_id AND al.profile_id=v_profile)
 THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='pilot_account_not_authorized';END IF;
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_profile::text,149071));
 SELECT owner_auth_user_id,player_profile_id,pg_catalog.encode(payload_sha256,'hex') digest
 INTO v_existing FROM public.arcade_receipt_claims WHERE result_id=p_result_id FOR UPDATE;
 IF FOUND THEN
   IF v_existing.owner_auth_user_id=p_auth_user_id AND v_existing.player_profile_id=v_profile AND
      v_existing.digest=p_payload_sha256_hex THEN RETURN jsonb_build_object('outcome','existing');END IF;
   RETURN jsonb_build_object('outcome','conflict');
 END IF;
 INSERT INTO public.arcade_receipt_claims(result_id,owner_auth_user_id,player_profile_id,protocol_version,
 payload,signature,monitor_id,key_id,public_key_sha256,game_id,mode_id,scoring_revision,
 score,device_unix_seconds,metrics,round_counter,verifier_version,event_id)
 VALUES(p_result_id,p_auth_user_id,v_profile,1,pg_catalog.decode(p_payload_hex,'hex'),pg_catalog.decode(p_signature_hex,'hex'),
 p_monitor_id,p_key_id,pg_catalog.decode(p_public_key_sha256_hex,'hex'),p_game_id,p_mode_id,p_scoring_revision,
 p_score,p_device_unix_seconds,p_metrics,NULL,'receipt-claims-v1',p_event_id)
 ON CONFLICT(result_id) DO NOTHING RETURNING result_id INTO v_inserted;
 IF v_inserted IS NULL THEN RETURN jsonb_build_object('outcome','conflict');END IF;
 INSERT INTO arcade_live_private.arcade_signed_attempts(result_id,profile_id,owner_auth_user_id,game_id,mode_id,
 scoring_revision,score,metrics,event_id,claimed_at)
 VALUES(p_result_id,v_profile,p_auth_user_id,p_game_id,p_mode_id,p_scoring_revision,p_score,p_metrics,p_event_id,v_now);
 INSERT INTO arcade_live_private.arcade_signed_lifetime(profile_id,game_id,mode_id,scoring_revision,
 attempts,sum_scores,sum_raw_points,sum_registered_impacts,sum_center_hits,last_updated)
 VALUES(v_profile,p_game_id,p_mode_id,p_scoring_revision,1,p_score,0,v_imp,v_vital,v_now)
 ON CONFLICT(profile_id,game_id,mode_id,scoring_revision) DO UPDATE SET
 attempts=arcade_signed_lifetime.attempts+1,sum_scores=arcade_signed_lifetime.sum_scores+excluded.sum_scores,
 sum_raw_points=arcade_signed_lifetime.sum_raw_points+excluded.sum_raw_points,
 sum_registered_impacts=arcade_signed_lifetime.sum_registered_impacts+excluded.sum_registered_impacts,
 sum_center_hits=arcade_signed_lifetime.sum_center_hits+excluded.sum_center_hits,last_updated=excluded.last_updated;
 INSERT INTO arcade_live_private.arcade_signed_personal_bests(profile_id,game_id,mode_id,scoring_revision,
 best_result_id,score,metrics,achieved_at)
 VALUES(v_profile,p_game_id,p_mode_id,p_scoring_revision,p_result_id,p_score,p_metrics,v_now)
 ON CONFLICT(profile_id,game_id,mode_id,scoring_revision) DO UPDATE SET
 best_result_id=excluded.best_result_id,score=excluded.score,metrics=excluded.metrics,achieved_at=excluded.achieved_at
 WHERE excluded.score>arcade_signed_personal_bests.score;
 DELETE FROM arcade_live_private.arcade_signed_attempts a WHERE a.profile_id=v_profile AND a.result_id IN
 (SELECT result_id FROM arcade_live_private.arcade_signed_attempts WHERE profile_id=v_profile
 ORDER BY claimed_at DESC,result_id DESC OFFSET 50);
 RETURN jsonb_build_object('outcome','created');
END $function$
 OR p_monitor_id='00' OR (p_event_id=2 AND p_monitor_id<>'01')) OR p_game_id IS DISTINCT FROM 'wild-hunt'
 OR p_mode_id IS NULL OR p_mode_id NOT IN ('easy','medium','hard')
 OR p_scoring_revision IS DISTINCT FROM 1
 OR p_score IS NULL OR p_score<0 OR
 (p_mode_id='hard' AND p_score>100000)
 OR p_key_id IS NULL OR p_key_id !~ '^K[0-9A-F]{16}$'
 OR p_device_unix_seconds IS NULL OR p_device_unix_seconds NOT BETWEEN 1704067200 AND 4102444800
 OR p_payload_hex IS NULL OR p_payload_hex !~ '^[0-9a-f]+$'
 OR length(p_payload_hex) NOT BETWEEN 2 AND 1024 OR length(p_payload_hex)%2<>0
 OR p_signature_hex IS NULL OR p_signature_hex !~ '^[0-9a-f]{128}$'
 OR p_payload_sha256_hex IS NULL OR p_payload_sha256_hex !~ '^[0-9a-f]{64}$'
 OR p_public_key_sha256_hex IS NULL OR p_public_key_sha256_hex !~ '^[0-9a-f]{64}$'
 OR p_metrics IS NULL OR jsonb_typeof(p_metrics)<>'object' OR octet_length(p_metrics::text)>2048
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_wildhunt_claim';END IF;
 IF pg_catalog.sha256(pg_catalog.decode(p_payload_hex,'hex'))<>pg_catalog.decode(p_payload_sha256_hex,'hex')
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='payload_digest_mismatch';END IF;
 IF (p_metrics-ARRAY['imp','hit','vital','pro','miss','stage','win','time','har','cov','base','sq']::text[])<>'{}'::jsonb
 OR NOT p_metrics ?& ARRAY['imp','hit','vital','pro','miss','stage','win','time','har','cov','base','sq']

 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='wildhunt_metric_shape';END IF;
 FOR v_k,v_val IN SELECT key,value FROM jsonb_each(p_metrics) LOOP
   IF jsonb_typeof(v_val)<>'number' OR v_val::text !~ '^[0-9]{1,10}$' OR (v_val::text)::bigint>2147483647
   THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='wildhunt_metric_value';END IF;
 END LOOP;
 v_imp:=(p_metrics->>'imp')::integer;v_hit:=(p_metrics->>'hit')::integer;
 v_vital:=(p_metrics->>'vital')::integer;v_pro:=(p_metrics->>'pro')::integer;
 v_miss:=(p_metrics->>'miss')::integer;v_stage:=(p_metrics->>'stage')::integer;
 v_win:=(p_metrics->>'win')::integer;v_time:=(p_metrics->>'time')::integer;
 v_har:=(p_metrics->>'har')::integer;v_cov:=(p_metrics->>'cov')::integer;
 v_base:=(p_metrics->>'base')::integer;v_sq:=(p_metrics->>'sq')::integer;
 v_cap:=CASE p_mode_id WHEN 'easy' THEN 250 WHEN 'medium' THEN 125 ELSE 100 END;
 v_harvest_goal:=CASE WHEN p_mode_id='hard' THEN 50 ELSE 25 END;
 IF v_imp NOT BETWEEN v_harvest_goal AND v_cap OR
   v_hit>v_imp OR v_vital>v_hit OR v_har>v_hit OR
   v_imp::bigint<>v_hit::bigint+v_pro+v_miss+v_cov OR
   v_stage<>5 OR v_win<>1 OR v_har<>v_harvest_goal OR
   v_time>2147483647 OR
   p_score::bigint<>v_base::bigint+v_sq::bigint-(150::bigint*v_pro) OR
   (p_mode_id='hard' AND (v_imp NOT BETWEEN 50 AND 100 OR v_hit<50 OR v_har<>50))
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='wildhunt_metric_bounds';END IF;
 SELECT status,public_key_sha256,monitor_code INTO v_key
 FROM arcade_live_private.arcade_monitor_signing_keys WHERE key_id=p_key_id FOR SHARE;
 IF NOT FOUND OR v_key.status<>'active' OR v_key.monitor_code<>p_monitor_id OR
 v_key.public_key_sha256<>pg_catalog.decode(p_public_key_sha256_hex,'hex')
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='monitor_key_inactive';END IF;
 SELECT e.state,e.starts_at,e.ends_at,e.pilot_only INTO v_event
 FROM arcade_live_private.arcade_events e JOIN arcade_live_private.arcade_event_monitors em
 ON em.event_id=e.id WHERE e.id=p_event_id AND em.monitor_id=p_monitor_id AND em.key_id=p_key_id
 FOR SHARE OF e;
 IF NOT FOUND OR v_event.state NOT IN ('active','closed') OR ((p_event_id=2 AND v_event.pilot_only IS DISTINCT FROM true) OR (p_event_id=3 AND v_event.pilot_only IS DISTINCT FROM false)) OR
 v_now<v_event.starts_at OR v_now>v_event.ends_at+interval '10 days'
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='event_ineligible_or_expired';END IF;
 SELECT p.id INTO v_profile FROM public.arcade_player_profiles p
 JOIN public.arcade_adult_accounts a ON a.auth_user_id=p.owner_auth_user_id
 JOIN public.arcade_profile_permissions pm ON pm.profile_id=p.id AND pm.auth_user_id=p.owner_auth_user_id
 WHERE p.owner_auth_user_id=p_auth_user_id AND p.state='active' AND p.visibility='private'
 AND p.profile_kind='adult_self' AND pm.role='owner' AND pm.status='active'
 AND a.admission_state='approved_adult' LIMIT 1 FOR UPDATE OF p;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='player_not_authorized';END IF;
 IF p_event_id=2 AND NOT EXISTS(SELECT 1 FROM arcade_live_private.arcade_pilot_claim_allowlist al
   WHERE al.event_id=p_event_id AND al.profile_id=v_profile)
 THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='pilot_account_not_authorized';END IF;
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_profile::text,149071));
 SELECT owner_auth_user_id,player_profile_id,pg_catalog.encode(payload_sha256,'hex') digest
 INTO v_existing FROM public.arcade_receipt_claims WHERE result_id=p_result_id FOR UPDATE;
 IF FOUND THEN
   IF v_existing.owner_auth_user_id=p_auth_user_id AND v_existing.player_profile_id=v_profile AND
      v_existing.digest=p_payload_sha256_hex THEN RETURN jsonb_build_object('outcome','existing');END IF;
   RETURN jsonb_build_object('outcome','conflict');
 END IF;
 INSERT INTO public.arcade_receipt_claims(result_id,owner_auth_user_id,player_profile_id,protocol_version,
 payload,signature,monitor_id,key_id,public_key_sha256,game_id,mode_id,scoring_revision,
 score,device_unix_seconds,metrics,round_counter,verifier_version,event_id)
 VALUES(p_result_id,p_auth_user_id,v_profile,1,pg_catalog.decode(p_payload_hex,'hex'),pg_catalog.decode(p_signature_hex,'hex'),
 p_monitor_id,p_key_id,pg_catalog.decode(p_public_key_sha256_hex,'hex'),p_game_id,p_mode_id,p_scoring_revision,
 p_score,p_device_unix_seconds,p_metrics,NULL,'receipt-claims-v1',p_event_id)
 ON CONFLICT(result_id) DO NOTHING RETURNING result_id INTO v_inserted;
 IF v_inserted IS NULL THEN RETURN jsonb_build_object('outcome','conflict');END IF;
 INSERT INTO arcade_live_private.arcade_signed_attempts(result_id,profile_id,owner_auth_user_id,game_id,mode_id,
 scoring_revision,score,metrics,event_id,claimed_at)
 VALUES(p_result_id,v_profile,p_auth_user_id,p_game_id,p_mode_id,p_scoring_revision,p_score,p_metrics,p_event_id,v_now);
 INSERT INTO arcade_live_private.arcade_signed_lifetime(profile_id,game_id,mode_id,scoring_revision,
 attempts,sum_scores,sum_raw_points,sum_registered_impacts,sum_center_hits,last_updated)
 VALUES(v_profile,p_game_id,p_mode_id,p_scoring_revision,1,p_score,0,v_imp,v_vital,v_now)
 ON CONFLICT(profile_id,game_id,mode_id,scoring_revision) DO UPDATE SET
 attempts=arcade_signed_lifetime.attempts+1,sum_scores=arcade_signed_lifetime.sum_scores+excluded.sum_scores,
 sum_raw_points=arcade_signed_lifetime.sum_raw_points+excluded.sum_raw_points,
 sum_registered_impacts=arcade_signed_lifetime.sum_registered_impacts+excluded.sum_registered_impacts,
 sum_center_hits=arcade_signed_lifetime.sum_center_hits+excluded.sum_center_hits,last_updated=excluded.last_updated;
 INSERT INTO arcade_live_private.arcade_signed_personal_bests(profile_id,game_id,mode_id,scoring_revision,
 best_result_id,score,metrics,achieved_at)
 VALUES(v_profile,p_game_id,p_mode_id,p_scoring_revision,p_result_id,p_score,p_metrics,v_now)
 ON CONFLICT(profile_id,game_id,mode_id,scoring_revision) DO UPDATE SET
 best_result_id=excluded.best_result_id,score=excluded.score,metrics=excluded.metrics,achieved_at=excluded.achieved_at
 WHERE excluded.score>arcade_signed_personal_bests.score;
 DELETE FROM arcade_live_private.arcade_signed_attempts a WHERE a.profile_id=v_profile AND a.result_id IN
 (SELECT result_id FROM arcade_live_private.arcade_signed_attempts WHERE profile_id=v_profile
 ORDER BY claimed_at DESC,result_id DESC OFFSET 50);
 RETURN jsonb_build_object('outcome','created');
END $function$
;

-- arcade_live_signed_claim_zombie_campaign_v1
CREATE OR REPLACE FUNCTION public.arcade_live_signed_claim_zombie_campaign_v1(p_auth_user_id uuid, p_result_id uuid, p_event_id bigint, p_monitor_id text, p_key_id text, p_payload_hex text, p_signature_hex text, p_payload_sha256_hex text, p_public_key_sha256_hex text, p_game_id text, p_mode_id text, p_scoring_revision integer, p_score integer, p_device_unix_seconds bigint, p_metrics jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_profile uuid;
 v_key record;
 v_event record;
 v_preexisting record;
 v_inserted uuid;
 v_shots integer;
 v_hits integer;
 v_heads integer;
 v_kills integer;
 v_time integer;
 v_metric text;
 v_value jsonb;
 v_claimed_at timestamptz := clock_timestamp();
begin
 -- Server-only RPC called after Netlify verifies raw ECDSA signature and key/event registry.
 if p_auth_user_id is null or p_result_id is null or (p_event_id IS NULL OR p_event_id NOT IN (2,3))
   or p_game_id is distinct from 'zombie-outbreak'
   or p_mode_id is distinct from 'campaign' or p_scoring_revision is distinct from 1
   or (p_monitor_id IS NULL OR p_monitor_id !~ '^[0-9]{2}
   or p_key_id is null or p_key_id !~ '^K[0-9A-F]{16}$'
   or p_score is null or p_score < 0 or p_score > 1000000
   or p_device_unix_seconds is null or p_device_unix_seconds < 1 or p_device_unix_seconds > 4102444800
   or p_payload_hex is null or p_payload_hex !~ '^[0-9a-f]+$' or length(p_payload_hex) < 2
   or length(p_payload_hex) > 1024 or length(p_payload_hex) % 2 <> 0
   or p_signature_hex is null or p_signature_hex !~ '^[0-9a-f]{128}$'
   or p_payload_sha256_hex is null or p_payload_sha256_hex !~ '^[0-9a-f]{64}$'
   or p_public_key_sha256_hex is null or p_public_key_sha256_hex !~ '^[0-9a-f]{64}$'
   or p_metrics is null or jsonb_typeof(p_metrics) <> 'object'
   or octet_length(p_metrics::text)>2048
 then raise exception using errcode='22023', message='invalid_zombie_claim'; end if;
 if decode(p_payload_sha256_hex,'hex') <> sha256(decode(p_payload_hex,'hex'))
 then raise exception using errcode='22023',message='payload_digest_mismatch'; end if;
 if p_metrics - array['shots','target_hits','qualified_headshots','kills',
      'highest_scene','scenes_cleared','time_ms','completed']::text[] <> '{}'::jsonb
    or not p_metrics ?& array['shots','target_hits','qualified_headshots',
      'kills','highest_scene','scenes_cleared','time_ms','completed']
 then raise exception using errcode='22023',message='invalid_zombie_metric_shape'; end if;
 for v_metric,v_value in select key,value from jsonb_each(p_metrics) loop
   if jsonb_typeof(v_value)<>'number' or v_value::text !~ '^[0-9]{1,8}$'
   then raise exception using errcode='22023',message='invalid_zombie_metric'; end if;
 end loop;
 v_shots := (p_metrics->>'shots')::integer;
 v_hits := (p_metrics->>'target_hits')::integer;
 v_heads := (p_metrics->>'qualified_headshots')::integer;
 v_kills := (p_metrics->>'kills')::integer;
 v_time := (p_metrics->>'time_ms')::integer;
 if v_shots not between 50 and 100000 or v_hits not between 50 and v_shots
   or v_heads not between 0 and v_hits or v_kills<>50
   or (p_metrics->>'highest_scene')::integer<>5
   or (p_metrics->>'scenes_cleared')::integer<>5
   or (p_metrics->>'completed')::integer<>1
   or v_time not between 1000 and 86400000
   or p_score <> v_hits*25+v_heads*150+v_kills*75
 then raise exception using errcode='22023',message='zombie_score_mismatch'; end if;

 select k.status,k.public_key_sha256,k.monitor_code into v_key
 from arcade_live_private.arcade_monitor_signing_keys k
 where k.key_id=p_key_id for share;
 if not found or v_key.status<>'active' or v_key.monitor_code<>p_monitor_id
 or v_key.public_key_sha256<>decode(p_public_key_sha256_hex,'hex')
 then raise exception using errcode='22023',message='monitor_key_inactive'; end if;
 select e.state,e.starts_at,e.ends_at,e.pilot_only into v_event
 from arcade_live_private.arcade_events e
 join arcade_live_private.arcade_event_monitors em on em.event_id=e.id
 where e.id=p_event_id and em.monitor_id=p_monitor_id and em.key_id=p_key_id
 for share of e;
 if not found or v_event.state not in ('active','closed')
   or v_claimed_at<v_event.starts_at or v_claimed_at>v_event.ends_at+interval '10 days'
   or ((p_event_id=2 AND v_event.pilot_only IS DISTINCT FROM true) OR (p_event_id=3 AND v_event.pilot_only IS DISTINCT FROM false))
 then raise exception using errcode='22023',message='event_ineligible_or_expired'; end if;
 select p.id into v_profile
 from public.arcade_player_profiles p
 join public.arcade_adult_accounts a on a.auth_user_id=p.owner_auth_user_id
 join public.arcade_profile_permissions pm
   on pm.profile_id=p.id and pm.auth_user_id=p.owner_auth_user_id
 where p.owner_auth_user_id=p_auth_user_id and p.state='active'
   and p.visibility='private' and p.profile_kind='adult_self'
   and pm.role='owner' and pm.status='active'
   and a.admission_state='approved_adult'
 limit 1 for update of p;
 if not found then raise exception using errcode='42501',message='player_not_authorized'; end if;
 IF p_event_id=2 AND NOT EXISTS(SELECT 1 FROM arcade_live_private.arcade_pilot_claim_allowlist allowlist
 where allowlist.event_id=p_event_id and allowlist.profile_id=v_profile)
 then raise exception using errcode='42501',message='pilot_account_not_authorized'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_profile::text,149071));
 select owner_auth_user_id,player_profile_id,encode(payload_sha256,'hex') as digest
 into v_preexisting from public.arcade_receipt_claims
 where result_id=p_result_id for update;
 if found then
   if v_preexisting.owner_auth_user_id=p_auth_user_id
     and v_preexisting.player_profile_id=v_profile
     and v_preexisting.digest=p_payload_sha256_hex
     then return jsonb_build_object('outcome','existing'); end if;
   return jsonb_build_object('outcome','conflict');
 end if;
 insert into public.arcade_receipt_claims(
 result_id,owner_auth_user_id,player_profile_id,protocol_version,
 payload,signature,monitor_id,key_id,public_key_sha256,game_id,mode_id,
 scoring_revision,score,device_unix_seconds,metrics,round_counter,verifier_version,event_id
 ) values (p_result_id,p_auth_user_id,v_profile,1,
 decode(p_payload_hex,'hex'),decode(p_signature_hex,'hex'),p_monitor_id,p_key_id,
 decode(p_public_key_sha256_hex,'hex'),p_game_id,p_mode_id,p_scoring_revision,
 p_score,p_device_unix_seconds,p_metrics,null,'receipt-claims-v1',p_event_id)
 on conflict (result_id) do nothing returning result_id into v_inserted;
 if v_inserted is null then return jsonb_build_object('outcome','conflict'); end if;
 insert into arcade_live_private.arcade_signed_attempts(
 result_id,profile_id,owner_auth_user_id,game_id,mode_id,scoring_revision,score,metrics,event_id,claimed_at)
 values(p_result_id,v_profile,p_auth_user_id,p_game_id,p_mode_id,p_scoring_revision,p_score,p_metrics,p_event_id,v_claimed_at);
 insert into arcade_live_private.arcade_signed_lifetime(
 profile_id,game_id,mode_id,scoring_revision,attempts,sum_scores,sum_raw_points,
 sum_registered_impacts,sum_center_hits,last_updated)
 values(v_profile,p_game_id,p_mode_id,p_scoring_revision,1,p_score,p_score,v_shots,v_heads,v_claimed_at)
 on conflict(profile_id,game_id,mode_id,scoring_revision) do update set
 attempts=arcade_signed_lifetime.attempts+1,
 sum_scores=arcade_signed_lifetime.sum_scores+excluded.sum_scores,
 sum_raw_points=arcade_signed_lifetime.sum_raw_points+excluded.sum_raw_points,
 sum_registered_impacts=arcade_signed_lifetime.sum_registered_impacts+excluded.sum_registered_impacts,
 sum_center_hits=arcade_signed_lifetime.sum_center_hits+excluded.sum_center_hits,
 last_updated=excluded.last_updated;
 insert into arcade_live_private.arcade_signed_personal_bests(
 profile_id,game_id,mode_id,scoring_revision,best_result_id,score,metrics,achieved_at)
 values(v_profile,p_game_id,p_mode_id,p_scoring_revision,p_result_id,p_score,p_metrics,v_claimed_at)
 on conflict(profile_id,game_id,mode_id,scoring_revision) do update set
 best_result_id=excluded.best_result_id,score=excluded.score,
 metrics=excluded.metrics,achieved_at=excluded.achieved_at
 where (excluded.score,(excluded.metrics->>'qualified_headshots')::integer,
       -(excluded.metrics->>'time_ms')::integer) >
       (arcade_signed_personal_bests.score,
        (arcade_signed_personal_bests.metrics->>'qualified_headshots')::integer,
        -(arcade_signed_personal_bests.metrics->>'time_ms')::integer);
 delete from arcade_live_private.arcade_signed_attempts s
 where s.profile_id=v_profile and s.result_id in (
   select result_id from arcade_live_private.arcade_signed_attempts
   where profile_id=v_profile order by claimed_at desc,result_id desc offset 50);
 return jsonb_build_object('outcome','created');
end $function$
 OR p_monitor_id='00' OR (p_event_id=2 AND p_monitor_id<>'01'))
   or p_key_id is null or p_key_id !~ '^K[0-9A-F]{16}$'
   or p_score is null or p_score < 0 or p_score > 1000000
   or p_device_unix_seconds is null or p_device_unix_seconds < 1 or p_device_unix_seconds > 4102444800
   or p_payload_hex is null or p_payload_hex !~ '^[0-9a-f]+$' or length(p_payload_hex) < 2
   or length(p_payload_hex) > 1024 or length(p_payload_hex) % 2 <> 0
   or p_signature_hex is null or p_signature_hex !~ '^[0-9a-f]{128}$'
   or p_payload_sha256_hex is null or p_payload_sha256_hex !~ '^[0-9a-f]{64}$'
   or p_public_key_sha256_hex is null or p_public_key_sha256_hex !~ '^[0-9a-f]{64}$'
   or p_metrics is null or jsonb_typeof(p_metrics) <> 'object'
   or octet_length(p_metrics::text)>2048
 then raise exception using errcode='22023', message='invalid_zombie_claim'; end if;
 if decode(p_payload_sha256_hex,'hex') <> sha256(decode(p_payload_hex,'hex'))
 then raise exception using errcode='22023',message='payload_digest_mismatch'; end if;
 if p_metrics - array['shots','target_hits','qualified_headshots','kills',
      'highest_scene','scenes_cleared','time_ms','completed']::text[] <> '{}'::jsonb
    or not p_metrics ?& array['shots','target_hits','qualified_headshots',
      'kills','highest_scene','scenes_cleared','time_ms','completed']
 then raise exception using errcode='22023',message='invalid_zombie_metric_shape'; end if;
 for v_metric,v_value in select key,value from jsonb_each(p_metrics) loop
   if jsonb_typeof(v_value)<>'number' or v_value::text !~ '^[0-9]{1,8}$'
   then raise exception using errcode='22023',message='invalid_zombie_metric'; end if;
 end loop;
 v_shots := (p_metrics->>'shots')::integer;
 v_hits := (p_metrics->>'target_hits')::integer;
 v_heads := (p_metrics->>'qualified_headshots')::integer;
 v_kills := (p_metrics->>'kills')::integer;
 v_time := (p_metrics->>'time_ms')::integer;
 if v_shots not between 50 and 100000 or v_hits not between 50 and v_shots
   or v_heads not between 0 and v_hits or v_kills<>50
   or (p_metrics->>'highest_scene')::integer<>5
   or (p_metrics->>'scenes_cleared')::integer<>5
   or (p_metrics->>'completed')::integer<>1
   or v_time not between 1000 and 86400000
   or p_score <> v_hits*25+v_heads*150+v_kills*75
 then raise exception using errcode='22023',message='zombie_score_mismatch'; end if;

 select k.status,k.public_key_sha256,k.monitor_code into v_key
 from arcade_live_private.arcade_monitor_signing_keys k
 where k.key_id=p_key_id for share;
 if not found or v_key.status<>'active' or v_key.monitor_code<>p_monitor_id
 or v_key.public_key_sha256<>decode(p_public_key_sha256_hex,'hex')
 then raise exception using errcode='22023',message='monitor_key_inactive'; end if;
 select e.state,e.starts_at,e.ends_at,e.pilot_only into v_event
 from arcade_live_private.arcade_events e
 join arcade_live_private.arcade_event_monitors em on em.event_id=e.id
 where e.id=p_event_id and em.monitor_id=p_monitor_id and em.key_id=p_key_id
 for share of e;
 if not found or v_event.state not in ('active','closed')
   or v_claimed_at<v_event.starts_at or v_claimed_at>v_event.ends_at+interval '10 days'
   or ((p_event_id=2 AND v_event.pilot_only IS DISTINCT FROM true) OR (p_event_id=3 AND v_event.pilot_only IS DISTINCT FROM false))
 then raise exception using errcode='22023',message='event_ineligible_or_expired'; end if;
 select p.id into v_profile
 from public.arcade_player_profiles p
 join public.arcade_adult_accounts a on a.auth_user_id=p.owner_auth_user_id
 join public.arcade_profile_permissions pm
   on pm.profile_id=p.id and pm.auth_user_id=p.owner_auth_user_id
 where p.owner_auth_user_id=p_auth_user_id and p.state='active'
   and p.visibility='private' and p.profile_kind='adult_self'
   and pm.role='owner' and pm.status='active'
   and a.admission_state='approved_adult'
 limit 1 for update of p;
 if not found then raise exception using errcode='42501',message='player_not_authorized'; end if;
 IF p_event_id=2 AND NOT EXISTS(SELECT 1 FROM arcade_live_private.arcade_pilot_claim_allowlist allowlist
 where allowlist.event_id=p_event_id and allowlist.profile_id=v_profile)
 then raise exception using errcode='42501',message='pilot_account_not_authorized'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_profile::text,149071));
 select owner_auth_user_id,player_profile_id,encode(payload_sha256,'hex') as digest
 into v_preexisting from public.arcade_receipt_claims
 where result_id=p_result_id for update;
 if found then
   if v_preexisting.owner_auth_user_id=p_auth_user_id
     and v_preexisting.player_profile_id=v_profile
     and v_preexisting.digest=p_payload_sha256_hex
     then return jsonb_build_object('outcome','existing'); end if;
   return jsonb_build_object('outcome','conflict');
 end if;
 insert into public.arcade_receipt_claims(
 result_id,owner_auth_user_id,player_profile_id,protocol_version,
 payload,signature,monitor_id,key_id,public_key_sha256,game_id,mode_id,
 scoring_revision,score,device_unix_seconds,metrics,round_counter,verifier_version,event_id
 ) values (p_result_id,p_auth_user_id,v_profile,1,
 decode(p_payload_hex,'hex'),decode(p_signature_hex,'hex'),p_monitor_id,p_key_id,
 decode(p_public_key_sha256_hex,'hex'),p_game_id,p_mode_id,p_scoring_revision,
 p_score,p_device_unix_seconds,p_metrics,null,'receipt-claims-v1',p_event_id)
 on conflict (result_id) do nothing returning result_id into v_inserted;
 if v_inserted is null then return jsonb_build_object('outcome','conflict'); end if;
 insert into arcade_live_private.arcade_signed_attempts(
 result_id,profile_id,owner_auth_user_id,game_id,mode_id,scoring_revision,score,metrics,event_id,claimed_at)
 values(p_result_id,v_profile,p_auth_user_id,p_game_id,p_mode_id,p_scoring_revision,p_score,p_metrics,p_event_id,v_claimed_at);
 insert into arcade_live_private.arcade_signed_lifetime(
 profile_id,game_id,mode_id,scoring_revision,attempts,sum_scores,sum_raw_points,
 sum_registered_impacts,sum_center_hits,last_updated)
 values(v_profile,p_game_id,p_mode_id,p_scoring_revision,1,p_score,p_score,v_shots,v_heads,v_claimed_at)
 on conflict(profile_id,game_id,mode_id,scoring_revision) do update set
 attempts=arcade_signed_lifetime.attempts+1,
 sum_scores=arcade_signed_lifetime.sum_scores+excluded.sum_scores,
 sum_raw_points=arcade_signed_lifetime.sum_raw_points+excluded.sum_raw_points,
 sum_registered_impacts=arcade_signed_lifetime.sum_registered_impacts+excluded.sum_registered_impacts,
 sum_center_hits=arcade_signed_lifetime.sum_center_hits+excluded.sum_center_hits,
 last_updated=excluded.last_updated;
 insert into arcade_live_private.arcade_signed_personal_bests(
 profile_id,game_id,mode_id,scoring_revision,best_result_id,score,metrics,achieved_at)
 values(v_profile,p_game_id,p_mode_id,p_scoring_revision,p_result_id,p_score,p_metrics,v_claimed_at)
 on conflict(profile_id,game_id,mode_id,scoring_revision) do update set
 best_result_id=excluded.best_result_id,score=excluded.score,
 metrics=excluded.metrics,achieved_at=excluded.achieved_at
 where (excluded.score,(excluded.metrics->>'qualified_headshots')::integer,
       -(excluded.metrics->>'time_ms')::integer) >
       (arcade_signed_personal_bests.score,
        (arcade_signed_personal_bests.metrics->>'qualified_headshots')::integer,
        -(arcade_signed_personal_bests.metrics->>'time_ms')::integer);
 delete from arcade_live_private.arcade_signed_attempts s
 where s.profile_id=v_profile and s.result_id in (
   select result_id from arcade_live_private.arcade_signed_attempts
   where profile_id=v_profile order by claimed_at desc,result_id desc offset 50);
 return jsonb_build_object('outcome','created');
end $function$
;
