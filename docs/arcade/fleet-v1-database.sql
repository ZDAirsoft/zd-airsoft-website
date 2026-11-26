-- Central verified fleet-v1 stage. The live database already contains this schema.
-- Deliberately disabled: internal scope 3 is PENDING and Netlify fleet flags are OFF.
-- Never remove or mutate historical Event 2 receipts/keys.
CREATE TABLE IF NOT EXISTS arcade_live_private.arcade_fleet_devices (
  key_id text PRIMARY KEY REFERENCES arcade_live_private.arcade_monitor_signing_keys(key_id) ON DELETE RESTRICT,
  monitor_id text NOT NULL UNIQUE CHECK(monitor_id ~ '^[0-9]{2}$' AND monitor_id<>'00'),
  status text NOT NULL CHECK(status IN('approved','revoked')),
  approved_at timestamptz NOT NULL DEFAULT clock_timestamp(),approved_by uuid,revoked_at timestamptz,
  CONSTRAINT fleet_revocation_time CHECK ((status='approved' AND revoked_at IS NULL) OR (status='revoked' AND revoked_at IS NOT NULL)));
REVOKE ALL ON arcade_live_private.arcade_fleet_devices FROM PUBLIC,anon,authenticated;
CREATE TABLE IF NOT EXISTS arcade_live_private.arcade_fleet_pairing_requests (
  key_id text PRIMARY KEY CHECK(key_id ~ '^K[0-9A-F]{16}$'),
  public_key_spki_der bytea NOT NULL CHECK(octet_length(public_key_spki_der) BETWEEN 70 AND 160),
  public_key_sha256 bytea NOT NULL UNIQUE CHECK(octet_length(public_key_sha256)=32),
  requested_at timestamptz NOT NULL DEFAULT clock_timestamp(),last_proven_at timestamptz NOT NULL,
  status text NOT NULL DEFAULT 'pending' CHECK(status IN('pending','approved','rejected')),
  monitor_id text CHECK(monitor_id IS NULL OR (monitor_id ~ '^[0-9]{2}$' AND monitor_id <> '00')),
  CONSTRAINT fleet_request_key_fingerprint CHECK ('K'||left(upper(encode(public_key_sha256,'hex')),16)=key_id));
REVOKE ALL ON arcade_live_private.arcade_fleet_pairing_requests FROM PUBLIC,anon,authenticated;
CREATE TABLE IF NOT EXISTS arcade_live_private.arcade_fleet_challenges (
  challenge_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),key_id text NOT NULL CHECK(key_id ~ '^K[0-9A-F]{16}$'),
  nonce bytea NOT NULL CHECK(octet_length(nonce)=32),created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  expires_at timestamptz NOT NULL,consumed_at timestamptz,
  CONSTRAINT fleet_challenge_time CHECK(expires_at>created_at));
CREATE INDEX IF NOT EXISTS arcade_fleet_challenges_key_idx ON arcade_live_private.arcade_fleet_challenges(key_id,created_at DESC);
REVOKE ALL ON arcade_live_private.arcade_fleet_challenges FROM PUBLIC,anon,authenticated;
INSERT INTO arcade_live_private.arcade_events(id,label,starts_at,ends_at,state,pilot_only)
 VALUES (3,'Arcade Fleet Scope (internal, permanent)',timestamptz '2026-11-26 00:00:00+00',timestamptz '9999-12-31 23:59:59+00','pending',false)
 ON CONFLICT(id) DO NOTHING;
INSERT INTO arcade_live_private.arcade_fleet_devices(key_id,monitor_id,status,approved_at)
 SELECT key_id,monitor_code,'approved',coalesce(activated_at,created_at)
 FROM arcade_live_private.arcade_monitor_signing_keys
 WHERE status='active' AND monitor_code IS NOT NULL
 ON CONFLICT(key_id) DO NOTHING;

-- public.arcade_fleet_begin_challenge_v1(text)
CREATE OR REPLACE FUNCTION public.arcade_fleet_begin_challenge_v1(p_key_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE c arcade_live_private.arcade_fleet_challenges%ROWTYPE;
BEGIN
 IF p_key_id !~ '^K[0-9A-F]{16}$' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_key_id'; END IF;
 IF (SELECT count(*) FROM arcade_live_private.arcade_fleet_challenges WHERE key_id=p_key_id AND created_at>clock_timestamp()-interval '10 minutes')>=5
 OR (SELECT count(*) FROM arcade_live_private.arcade_fleet_challenges WHERE created_at>clock_timestamp()-interval '10 minutes')>=200
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='fleet_challenge_limit'; END IF;
 INSERT INTO arcade_live_private.arcade_fleet_challenges(key_id,nonce,expires_at)
 VALUES (p_key_id,extensions.gen_random_bytes(32),clock_timestamp()+interval '10 minutes') RETURNING * INTO c;
 RETURN jsonb_build_object('challengeId',c.challenge_id,'nonceHex',encode(c.nonce,'hex'),'expiresAtUtc',to_char(c.expires_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'));
END;
$function$;
REVOKE ALL ON FUNCTION public.arcade_fleet_begin_challenge_v1(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.arcade_fleet_begin_challenge_v1(text) TO service_role;

-- public.arcade_fleet_challenge_check_v1(uuid,text)
CREATE OR REPLACE FUNCTION public.arcade_fleet_challenge_check_v1(p_challenge_id uuid, p_key_id text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
SELECT jsonb_build_object('challengeId',c.challenge_id,'keyId',c.key_id,'nonceHex',encode(c.nonce,'hex'))
FROM arcade_live_private.arcade_fleet_challenges c
WHERE c.challenge_id=p_challenge_id AND c.key_id=p_key_id AND c.expires_at>clock_timestamp() AND c.consumed_at IS NULL
$function$;
REVOKE ALL ON FUNCTION public.arcade_fleet_challenge_check_v1(uuid,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.arcade_fleet_challenge_check_v1(uuid,text) TO service_role;

-- public.arcade_fleet_record_proof_v1(uuid,text,text)
CREATE OR REPLACE FUNCTION public.arcade_fleet_record_proof_v1(p_challenge_id uuid, p_key_id text, p_public_spki_hex text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE c arcade_live_private.arcade_fleet_challenges%ROWTYPE; fp bytea; existing_fp bytea; state text;
BEGIN
 IF p_key_id !~ '^K[0-9A-F]{16}$' OR p_public_spki_hex !~ '^[0-9a-f]{140,320}$' OR length(p_public_spki_hex)%2<>0
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='fleet_proof_invalid'; END IF;
 SELECT * INTO c FROM arcade_live_private.arcade_fleet_challenges WHERE challenge_id=p_challenge_id FOR UPDATE;
 IF NOT FOUND OR c.key_id<>p_key_id OR c.consumed_at IS NOT NULL OR c.expires_at<clock_timestamp()
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='fleet_challenge_invalid'; END IF;
 fp:=sha256(decode(p_public_spki_hex,'hex'));
 IF 'K'||left(upper(encode(fp,'hex')),16)<>p_key_id
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='fleet_key_mismatch'; END IF;
 SELECT public_key_sha256 INTO existing_fp FROM arcade_live_private.arcade_monitor_signing_keys WHERE key_id=p_key_id;
 IF FOUND AND existing_fp<>fp THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='fleet_registered_mismatch'; END IF;
 SELECT public_key_sha256 INTO existing_fp FROM arcade_live_private.arcade_fleet_pairing_requests WHERE key_id=p_key_id;
 IF FOUND AND existing_fp<>fp THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='fleet_request_mismatch'; END IF;
 UPDATE arcade_live_private.arcade_fleet_challenges SET consumed_at=clock_timestamp() WHERE challenge_id=p_challenge_id;
 INSERT INTO arcade_live_private.arcade_fleet_pairing_requests(key_id,public_key_spki_der,public_key_sha256,last_proven_at)
 VALUES(p_key_id,decode(p_public_spki_hex,'hex'),fp,clock_timestamp())
 ON CONFLICT(key_id) DO UPDATE SET last_proven_at=excluded.last_proven_at;
 SELECT status INTO state FROM arcade_live_private.arcade_fleet_devices WHERE key_id=p_key_id;
 RETURN jsonb_build_object('status',coalesce(state,'pending'),'keyId',p_key_id);
END;
$function$;
REVOKE ALL ON FUNCTION public.arcade_fleet_record_proof_v1(uuid,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.arcade_fleet_record_proof_v1(uuid,text,text) TO service_role;

-- public.arcade_fleet_status_v1(text)
CREATE OR REPLACE FUNCTION public.arcade_fleet_status_v1(p_key_id text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
SELECT jsonb_build_object(
 'status',coalesce(
  (SELECT CASE WHEN k.status='revoked' OR f.status='revoked' THEN 'revoked'
               WHEN k.status='active' AND f.status='approved' THEN 'approved'
               ELSE 'pending' END
   FROM arcade_live_private.arcade_fleet_devices f
   JOIN arcade_live_private.arcade_monitor_signing_keys k ON k.key_id=f.key_id
   WHERE f.key_id=p_key_id),
  CASE WHEN EXISTS(SELECT 1 FROM arcade_live_private.arcade_fleet_pairing_requests WHERE key_id=p_key_id) THEN 'pending' ELSE 'unknown' END),
 'monitorId',(SELECT monitor_id FROM arcade_live_private.arcade_fleet_devices WHERE key_id=p_key_id),
 'keyId',p_key_id)
$function$;
REVOKE ALL ON FUNCTION public.arcade_fleet_status_v1(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.arcade_fleet_status_v1(text) TO service_role;

-- public.arcade_fleet_pending_v1(uuid)
CREATE OR REPLACE FUNCTION public.arcade_fleet_pending_v1(p_admin_auth_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM arcade_live_private.staff WHERE auth_user_id=p_admin_auth_user_id AND active AND role='admin')
 THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='fleet_owner_required'; END IF;
 RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('keyId',key_id,'requestedAtUtc',to_char(requested_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),'lastProvenAtUtc',to_char(last_proven_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"')) ORDER BY requested_at DESC)
 FROM arcade_live_private.arcade_fleet_pairing_requests WHERE status='pending'), '[]'::jsonb);
END;
$function$;
REVOKE ALL ON FUNCTION public.arcade_fleet_pending_v1(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.arcade_fleet_pending_v1(uuid) TO service_role;

-- public.arcade_fleet_approve_v1(uuid,text)
CREATE OR REPLACE FUNCTION public.arcade_fleet_approve_v1(p_admin_auth_user_id uuid, p_key_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE req arcade_live_private.arcade_fleet_pairing_requests%ROWTYPE; old_status text; station text; n integer;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM arcade_live_private.staff WHERE auth_user_id=p_admin_auth_user_id AND active=true AND role='admin')
 THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='fleet_owner_required'; END IF;
 PERFORM pg_catalog.pg_advisory_xact_lock(720035,1);
 SELECT * INTO req FROM arcade_live_private.arcade_fleet_pairing_requests WHERE key_id=p_key_id FOR UPDATE;
 IF NOT FOUND OR req.status='rejected' OR req.last_proven_at<clock_timestamp()-interval '7 days'
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='fleet_request_missing_or_stale'; END IF;
 SELECT status,monitor_id INTO old_status,station FROM arcade_live_private.arcade_fleet_devices WHERE key_id=p_key_id FOR UPDATE;
 IF old_status='revoked' THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='fleet_revoked'; END IF;
 IF old_status='approved' THEN RETURN jsonb_build_object('status','approved','monitorId',station,'keyId',p_key_id); END IF;
 station:=NULL;
 FOR n IN 1..99 LOOP
  IF NOT EXISTS(SELECT 1 FROM arcade_live_private.arcade_monitor_signing_keys WHERE monitor_code=lpad(n::text,2,'0'))
   AND NOT EXISTS(SELECT 1 FROM arcade_live_private.arcade_fleet_devices WHERE monitor_id=lpad(n::text,2,'0'))
  THEN station:=lpad(n::text,2,'0');EXIT;END IF;
 END LOOP;
 IF station IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='fleet_capacity_reached'; END IF;
 INSERT INTO arcade_live_private.arcade_monitor_signing_keys(key_id,public_key_spki_der,public_key_sha256,monitor_code,status,activated_at)
 VALUES(req.key_id,req.public_key_spki_der,req.public_key_sha256,station,'active',clock_timestamp())
 ON CONFLICT(key_id) DO NOTHING;
 INSERT INTO arcade_live_private.arcade_fleet_devices(key_id,monitor_id,status,approved_by)
 VALUES(p_key_id,station,'approved',p_admin_auth_user_id);
 UPDATE arcade_live_private.arcade_fleet_pairing_requests SET status='approved',monitor_id=station WHERE key_id=p_key_id;
 RETURN jsonb_build_object('status','approved','monitorId',station,'keyId',p_key_id);
END;
$function$;
REVOKE ALL ON FUNCTION public.arcade_fleet_approve_v1(uuid,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.arcade_fleet_approve_v1(uuid,text) TO service_role;

-- public.arcade_fleet_revoke_v1(uuid,text)
CREATE OR REPLACE FUNCTION public.arcade_fleet_revoke_v1(p_admin_auth_user_id uuid, p_key_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM arcade_live_private.staff WHERE auth_user_id=p_admin_auth_user_id AND active AND role='admin')
 THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='fleet_owner_required'; END IF;
 IF NOT EXISTS(SELECT 1 FROM arcade_live_private.arcade_fleet_devices WHERE key_id=p_key_id)
 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='fleet_device_unknown'; END IF;
 UPDATE arcade_live_private.arcade_fleet_devices SET status='revoked',revoked_at=clock_timestamp()
 WHERE key_id=p_key_id AND status='approved';
 UPDATE arcade_live_private.arcade_monitor_signing_keys SET status='revoked',revoked_at=clock_timestamp()
 WHERE key_id=p_key_id AND status='active';
 RETURN jsonb_build_object('status','revoked','keyId',p_key_id);
END;
$function$;
REVOKE ALL ON FUNCTION public.arcade_fleet_revoke_v1(uuid,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.arcade_fleet_revoke_v1(uuid,text) TO service_role;

-- arcade_live_private.arcade_fleet_scope_link_v1()
CREATE OR REPLACE FUNCTION arcade_live_private.arcade_fleet_scope_link_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN
 IF NEW.status='approved' THEN
 INSERT INTO arcade_live_private.arcade_event_monitors(event_id,monitor_id,key_id)
 VALUES(3,NEW.monitor_id,NEW.key_id)
 ON CONFLICT(event_id,key_id) DO NOTHING;
 END IF;
 RETURN NEW;
END; $function$;
REVOKE ALL ON FUNCTION arcade_live_private.arcade_fleet_scope_link_v1() FROM PUBLIC,anon,authenticated;

DROP TRIGGER IF EXISTS arcade_fleet_scope_link_v1 ON arcade_live_private.arcade_fleet_devices;
CREATE TRIGGER arcade_fleet_scope_link_v1 AFTER INSERT OR UPDATE OF status ON arcade_live_private.arcade_fleet_devices
 FOR EACH ROW EXECUTE FUNCTION arcade_live_private.arcade_fleet_scope_link_v1();
INSERT INTO arcade_live_private.arcade_event_monitors(event_id,monitor_id,key_id)
 SELECT 3,monitor_id,key_id FROM arcade_live_private.arcade_fleet_devices WHERE status='approved'
 ON CONFLICT(event_id,key_id) DO NOTHING;
-- Do not activate scope 3 until Launcher + website verification, review and owner go-live.
