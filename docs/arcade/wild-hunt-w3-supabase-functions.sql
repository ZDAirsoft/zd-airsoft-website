-- Wild Hunt W3.2 — updated snapshots of live Supabase function definitions
-- Updated 2026-11-23; includes staff removal compatibility change.
-- This is a backup, not a permission to enable wild-hunt signing.

-- public.arcade_live_signed_claim_wildhunt_v1(uuid,uuid,bigint,text,text,text,text,text,text,text,text,integer,integer,bigint,jsonb)
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
 IF p_auth_user_id IS NULL OR p_result_id IS NULL OR p_event_id IS DISTINCT FROM 2
 OR p_monitor_id IS DISTINCT FROM '01' OR p_game_id IS DISTINCT FROM 'wild-hunt'
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
 IF NOT FOUND OR v_event.state NOT IN ('active','closed') OR v_event.pilot_only IS DISTINCT FROM true OR
 v_now<v_event.starts_at OR v_now>v_event.ends_at+interval '10 days'
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='event_ineligible_or_expired';END IF;
 SELECT p.id INTO v_profile FROM public.arcade_player_profiles p
 JOIN public.arcade_adult_accounts a ON a.auth_user_id=p.owner_auth_user_id
 JOIN public.arcade_profile_permissions pm ON pm.profile_id=p.id AND pm.auth_user_id=p.owner_auth_user_id
 WHERE p.owner_auth_user_id=p_auth_user_id AND p.state='active' AND p.visibility='private'
 AND p.profile_kind='adult_self' AND pm.role='owner' AND pm.status='active'
 AND a.admission_state='approved_adult' LIMIT 1 FOR UPDATE OF p;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='player_not_authorized';END IF;
 IF NOT EXISTS(SELECT 1 FROM arcade_live_private.arcade_pilot_claim_allowlist al
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
END $function$;


-- public.arcade_live_verified_leaderboard_wildhunt_v1(text,text,integer)
CREATE OR REPLACE FUNCTION public.arcade_live_verified_leaderboard_wildhunt_v1(p_game_id text, p_mode_id text, p_scoring_revision integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_rows jsonb;
BEGIN
 IF p_game_id IS DISTINCT FROM 'wild-hunt' OR p_mode_id IS DISTINCT FROM 'hard'
 OR p_scoring_revision IS DISTINCT FROM 1 THEN
 RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='unsupported_verified_leaderboard'; END IF;
 WITH eligible AS (
 SELECT p.nickname,b.score,b.achieved_at,b.best_result_id
 FROM arcade_live_private.arcade_signed_personal_bests b
 JOIN public.arcade_player_profiles p ON p.id=b.profile_id AND p.state='active'
   AND p.profile_kind='adult_self' AND p.visibility='private'
 JOIN public.arcade_adult_accounts a ON a.auth_user_id=p.owner_auth_user_id AND a.admission_state='approved_adult'
 JOIN public.arcade_profile_permissions pm ON pm.profile_id=p.id AND pm.auth_user_id=p.owner_auth_user_id
   AND pm.role='owner' AND pm.status='active'
 JOIN arcade_live_private.publication pub ON pub.profile_id=p.id AND pub.public_scores=true
 LEFT JOIN arcade_live_private.restrictions r ON r.profile_id=p.id
 WHERE b.game_id='wild-hunt' AND b.mode_id='hard' AND b.scoring_revision=1
   AND b.hidden=false AND COALESCE(r.suspended,false)=false
 ), ranked AS (
 SELECT rank() OVER (ORDER BY score DESC)::integer rank,
  row_number() OVER (ORDER BY score DESC, achieved_at ASC,best_result_id ASC) as row_n,
  nickname,score
 FROM eligible
 ) SELECT coalesce(jsonb_agg(jsonb_build_object('rank',rank,'nickname',nickname,'score',score)
 ORDER BY row_n),'[]'::jsonb) INTO v_rows FROM (SELECT * FROM ranked WHERE row_n<=50) top_fifty;
 RETURN jsonb_build_object('version',1,'gameId','wild-hunt','modeId','hard','scoringRevision',1,'rows',v_rows);
END $function$;

-- public.arcade_live_my_verified_scorecard_v6(uuid)
CREATE OR REPLACE FUNCTION public.arcade_live_my_verified_scorecard_v6(p_auth_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_profile uuid;v_recent jsonb;v_bests jsonb;v_lifetime jsonb;
BEGIN
 IF p_auth_user_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='not_authorized'; END IF;
 SELECT p.id INTO v_profile FROM public.arcade_player_profiles p
 JOIN public.arcade_adult_accounts a ON a.auth_user_id=p.owner_auth_user_id AND a.admission_state='approved_adult'
 JOIN public.arcade_profile_permissions pm ON pm.profile_id=p.id AND pm.auth_user_id=p.owner_auth_user_id
  AND pm.role='owner' AND pm.status='active'
 WHERE p.owner_auth_user_id=p_auth_user_id AND p.state='active'
  AND p.profile_kind='adult_self' AND p.visibility='private' LIMIT 1;
 IF v_profile IS NULL THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='not_authorized'; END IF;
 WITH recent AS (
  SELECT game_id,mode_id,scoring_revision,score,claimed_at,event_id,metrics
  FROM arcade_live_private.arcade_signed_attempts WHERE profile_id=v_profile
  ORDER BY claimed_at DESC,result_id DESC LIMIT 50
 ) SELECT coalesce(jsonb_agg(jsonb_build_object(
  'gameId',game_id,'modeId',mode_id,'scoringRevision',scoring_revision,
  'score',score,'claimedAt',claimed_at,'eventId',event_id,
  'rawPoints',CASE WHEN game_id='silhouette-precision' AND scoring_revision=2 THEN NULL
                    WHEN game_id='silhouette-precision' THEN score WHEN game_id IN ('hostage-rescue','wild-hunt') THEN NULL ELSE (metrics->>'raw_points')::integer END,
  'registeredImpacts',CASE WHEN game_id='wild-hunt' THEN (metrics->>'imp')::integer ELSE (metrics->>'shots')::integer END,
  'centerHits',CASE WHEN game_id='silhouette-precision' THEN (metrics->>'center_chest_hits')::integer
                    WHEN game_id='hostage-rescue' THEN (metrics->>'threat_hits')::integer WHEN game_id='wild-hunt' THEN (metrics->>'vital')::integer ELSE (metrics->>'center_hits')::integer END,
  'tenPointHits',(metrics->>'ten_point_hits')::integer,
  'groupingRating',(metrics->>'grouping_rating')::integer,
  'timeMs',CASE WHEN game_id='wild-hunt' THEN (metrics->>'time')::integer ELSE (metrics->>'time_ms')::integer END,'harvests',(metrics->>'har')::integer,'vitalHits',(metrics->>'vital')::integer,'coverHits',(metrics->>'cov')::integer,'basePoints',(metrics->>'base')::integer,'sasquatchUplift',(metrics->>'sq')::integer,'threatHits',(metrics->>'threat_hits')::integer,'protectedHits',(metrics->>'protected_hits')::integer,'misses',(metrics->>'misses')::integer,'correctHolds',(metrics->>'correct_holds')::integer,'failedScenes',(metrics->>'failed_scenes')::integer,
  'kills',(metrics->>'kills')::integer,'targetHits',(metrics->>'target_hits')::integer,
  'qualifiedHeadshots',(metrics->>'qualified_headshots')::integer,
  'highestScene',(metrics->>'highest_scene')::integer,'scenesCleared',(metrics->>'scenes_cleared')::integer,
  'completed',(metrics->>'completed')::integer,'groupingBonus',(metrics->>'group_bonus')::integer,
  'speedBonus',(metrics->>'speed_bonus')::integer
 ) ORDER BY claimed_at DESC),'[]'::jsonb) INTO v_recent FROM recent;
 SELECT coalesce(jsonb_agg(jsonb_build_object(
  'gameId',game_id,'modeId',mode_id,'scoringRevision',scoring_revision,
  'score',score,'achievedAt',achieved_at,'hiddenFromPublic',hidden,
  'registeredImpacts',CASE WHEN game_id='wild-hunt' THEN (metrics->>'imp')::integer ELSE NULL END,
  'rawPoints',CASE WHEN game_id='silhouette-precision' AND scoring_revision=2 THEN NULL
                    WHEN game_id='silhouette-precision' THEN score WHEN game_id IN ('hostage-rescue','wild-hunt') THEN NULL ELSE (metrics->>'raw_points')::integer END,
  'centerHits',CASE WHEN game_id='silhouette-precision' THEN (metrics->>'center_chest_hits')::integer
                    WHEN game_id='hostage-rescue' THEN (metrics->>'threat_hits')::integer WHEN game_id='wild-hunt' THEN (metrics->>'vital')::integer ELSE (metrics->>'center_hits')::integer END,
  'tenPointHits',(metrics->>'ten_point_hits')::integer,
  'groupingRating',(metrics->>'grouping_rating')::integer,
  'timeMs',CASE WHEN game_id='wild-hunt' THEN (metrics->>'time')::integer ELSE (metrics->>'time_ms')::integer END,'harvests',(metrics->>'har')::integer,'vitalHits',(metrics->>'vital')::integer,'coverHits',(metrics->>'cov')::integer,'basePoints',(metrics->>'base')::integer,'sasquatchUplift',(metrics->>'sq')::integer,'threatHits',(metrics->>'threat_hits')::integer,'protectedHits',(metrics->>'protected_hits')::integer,'misses',(metrics->>'misses')::integer,'correctHolds',(metrics->>'correct_holds')::integer,'failedScenes',(metrics->>'failed_scenes')::integer,
  'kills',(metrics->>'kills')::integer,'targetHits',(metrics->>'target_hits')::integer,
  'qualifiedHeadshots',(metrics->>'qualified_headshots')::integer,
  'highestScene',(metrics->>'highest_scene')::integer,'scenesCleared',(metrics->>'scenes_cleared')::integer,
  'completed',(metrics->>'completed')::integer
 ) ORDER BY game_id,mode_id,scoring_revision),'[]'::jsonb)
 INTO v_bests FROM arcade_live_private.arcade_signed_personal_bests WHERE profile_id=v_profile;
 SELECT coalesce(jsonb_agg(jsonb_build_object(
  'gameId',game_id,'modeId',mode_id,'scoringRevision',scoring_revision,
  'attempts',attempts,'totalScore',sum_scores,
  'totalRawPoints',CASE WHEN game_id='silhouette-precision' AND scoring_revision=2 THEN NULL WHEN game_id IN ('hostage-rescue','wild-hunt') THEN NULL ELSE sum_raw_points END,
  'registeredImpacts',sum_registered_impacts,'centerHits',sum_center_hits
 ) ORDER BY game_id,mode_id,scoring_revision),'[]'::jsonb)
 INTO v_lifetime FROM arcade_live_private.arcade_signed_lifetime WHERE profile_id=v_profile;
 RETURN jsonb_build_object('version',1,'recent',v_recent,'personalBests',v_bests,
  'lifetimeByMode',v_lifetime,'maxRecent',50);
END $function$;

-- public.arcade_live_staff_remove_verified_score_v1(uuid,text)
CREATE OR REPLACE FUNCTION public.arcade_live_staff_remove_verified_score_v1(p_result_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_actor uuid;v_role text;v_s arcade_live_private.arcade_signed_attempts%ROWTYPE;
 v_p arcade_live_private.arcade_signed_personal_bests%ROWTYPE;
 v_candidate arcade_live_private.arcade_signed_attempts%ROWTYPE;
 v_raw bigint;v_shots bigint;v_center bigint;v_lifetime arcade_live_private.arcade_signed_lifetime%ROWTYPE;
 v_now timestamptz:=clock_timestamp();
BEGIN
 v_actor:=arcade_live_private.assert_staff();
 SELECT role INTO v_role FROM arcade_live_private.staff WHERE auth_user_id=v_actor AND active;
 IF v_role IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='staff_admin_required';END IF;
 IF p_result_id IS NULL OR p_reason IS NULL OR p_reason NOT IN
 ('staff_review','duplicate','inappropriate','score_error','player_request','correction')
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_score_removal';END IF;
 SELECT * INTO v_s FROM arcade_live_private.arcade_signed_attempts WHERE result_id=p_result_id;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='verified_score_not_found';END IF;
 PERFORM 1 FROM public.arcade_player_profiles WHERE id=v_s.profile_id FOR UPDATE;
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_s.profile_id::text,149071));
 SELECT * INTO v_s FROM arcade_live_private.arcade_signed_attempts WHERE result_id=p_result_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='verified_score_not_found'; END IF;
 SELECT * INTO v_lifetime FROM arcade_live_private.arcade_signed_lifetime
 WHERE profile_id=v_s.profile_id AND game_id=v_s.game_id AND mode_id=v_s.mode_id
  AND scoring_revision=v_s.scoring_revision FOR UPDATE;
 IF NOT FOUND OR v_lifetime.attempts<1 THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='score_lifetime_inconsistent';
 END IF;
 v_raw:= CASE WHEN v_s.game_id='zombie-outbreak' THEN v_s.score
       WHEN v_s.game_id='bullseye-classic' THEN COALESCE((v_s.metrics->>'raw_points')::bigint,0)
       ELSE 0 END;
 v_shots:=CASE WHEN v_s.game_id='wild-hunt' THEN COALESCE((v_s.metrics->>'imp')::bigint,0) ELSE COALESCE((v_s.metrics->>'shots')::bigint,0) END;
 v_center:=CASE WHEN v_s.game_id='wild-hunt' THEN COALESCE((v_s.metrics->>'vital')::bigint,0)
          WHEN v_s.game_id='hostage-rescue' THEN COALESCE((v_s.metrics->>'threat_hits')::bigint,0)
          WHEN v_s.game_id='silhouette-precision' THEN COALESCE((v_s.metrics->>'center_chest_hits')::bigint,0)
          WHEN v_s.game_id='zombie-outbreak' THEN COALESCE((v_s.metrics->>'qualified_headshots')::bigint,0)
          ELSE COALESCE((v_s.metrics->>'center_hits')::bigint,0) END;
 IF v_lifetime.sum_scores<v_s.score OR v_lifetime.sum_raw_points<v_raw OR
  v_lifetime.sum_registered_impacts<v_shots OR v_lifetime.sum_center_hits<v_center THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='score_lifetime_inconsistent';
 END IF;
 DELETE FROM arcade_live_private.arcade_signed_attempts WHERE result_id=p_result_id;
 IF v_lifetime.attempts=1 THEN
   DELETE FROM arcade_live_private.arcade_signed_lifetime WHERE profile_id=v_s.profile_id
    AND game_id=v_s.game_id AND mode_id=v_s.mode_id AND scoring_revision=v_s.scoring_revision;
 ELSE
  UPDATE arcade_live_private.arcade_signed_lifetime SET
   attempts=attempts-1,sum_scores=sum_scores-v_s.score,sum_raw_points=sum_raw_points-v_raw,
   sum_registered_impacts=sum_registered_impacts-v_shots,sum_center_hits=sum_center_hits-v_center,
   last_updated=v_now
  WHERE profile_id=v_s.profile_id AND game_id=v_s.game_id AND mode_id=v_s.mode_id
   AND scoring_revision=v_s.scoring_revision;
 END IF;
 SELECT * INTO v_p FROM arcade_live_private.arcade_signed_personal_bests
 WHERE profile_id=v_s.profile_id AND game_id=v_s.game_id AND mode_id=v_s.mode_id
 AND scoring_revision=v_s.scoring_revision FOR UPDATE;
 IF FOUND AND v_p.best_result_id=p_result_id THEN
  DELETE FROM arcade_live_private.arcade_signed_personal_bests
  WHERE profile_id=v_s.profile_id AND game_id=v_s.game_id AND mode_id=v_s.mode_id
    AND scoring_revision=v_s.scoring_revision;
  SELECT * INTO v_candidate FROM arcade_live_private.arcade_signed_attempts a
   WHERE a.profile_id=v_s.profile_id AND a.game_id=v_s.game_id AND
     a.mode_id=v_s.mode_id AND a.scoring_revision=v_s.scoring_revision AND a.hidden=false
   ORDER BY a.score DESC,
      CASE WHEN a.game_id='hostage-rescue' THEN COALESCE((a.metrics->>'protected_hits')::integer,99999) END ASC,
      CASE WHEN a.game_id='hostage-rescue' THEN COALESCE((a.metrics->>'misses')::integer,99999) END ASC,
      CASE WHEN a.game_id='silhouette-precision' THEN COALESCE((a.metrics->>'ten_point_hits')::integer,0) END DESC,
      CASE WHEN a.game_id='silhouette-precision' THEN COALESCE((a.metrics->>'center_chest_hits')::integer,0) END DESC,
      CASE WHEN a.game_id='silhouette-precision' THEN COALESCE((a.metrics->>'grouping_rating')::integer,0) END DESC,
      CASE WHEN a.game_id='zombie-outbreak' THEN COALESCE((a.metrics->>'qualified_headshots')::integer,0) END DESC,
      CASE WHEN a.game_id='bullseye-classic' THEN COALESCE((a.metrics->>'raw_points')::integer,0) END DESC,
      CASE WHEN a.game_id='bullseye-classic' THEN COALESCE((a.metrics->>'center_hits')::integer,0) END DESC,
      CASE WHEN a.game_id='wild-hunt' THEN NULL ELSE COALESCE((a.metrics->>'time_ms')::integer,2147483647) END ASC,a.claimed_at ASC,a.result_id ASC
   LIMIT 1;
  IF FOUND THEN
   INSERT INTO arcade_live_private.arcade_signed_personal_bests
    (profile_id,game_id,mode_id,scoring_revision,best_result_id,score,metrics,achieved_at)
   VALUES(v_candidate.profile_id,v_candidate.game_id,v_candidate.mode_id,
    v_candidate.scoring_revision,v_candidate.result_id,v_candidate.score,v_candidate.metrics,v_candidate.claimed_at);
  END IF;
 END IF;
 INSERT INTO arcade_live_private.moderation_audit(actor_auth_user_id,event,profile_id,score_id,verified_result_id,reason)
 VALUES(v_actor,'verified_score_removed',v_s.profile_id,NULL,p_result_id,p_reason);
 RETURN jsonb_build_object('version',1,'removed',true,'resultId',p_result_id,
  'gameId',v_s.game_id,'modeId',v_s.mode_id);
END $function$;

-- Strong privilege boundaries for newly added server-only functions.
REVOKE ALL ON FUNCTION public.arcade_live_signed_claim_wildhunt_v1(uuid,uuid,bigint,text,text,text,text,text,text,text,text,integer,integer,bigint,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.arcade_live_signed_claim_wildhunt_v1(uuid,uuid,bigint,text,text,text,text,text,text,text,text,integer,integer,bigint,jsonb) TO service_role;
REVOKE ALL ON FUNCTION public.arcade_live_verified_leaderboard_wildhunt_v1(text,text,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.arcade_live_verified_leaderboard_wildhunt_v1(text,text,integer) TO service_role;
REVOKE ALL ON FUNCTION public.arcade_live_my_verified_scorecard_v6(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.arcade_live_my_verified_scorecard_v6(uuid) TO service_role;
