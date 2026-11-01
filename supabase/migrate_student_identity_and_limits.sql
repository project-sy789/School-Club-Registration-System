-- Student identity verification and abuse controls
-- Run after setup_database.sql and migrate_backend_hardening.sql.
-- Only HMACs are stored; the national ID is never persisted in plaintext and
-- is never returned to the browser. The full-ID hash is used only to find a
-- known student who forgot their school ID. The last-four hash is used for
-- history/cancellation verification.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS private.registration_secrets (
    name TEXT PRIMARY KEY,
    secret BYTEA NOT NULL
);
INSERT INTO private.registration_secrets(name, secret)
VALUES ('student_identity_hmac', gen_random_bytes(32))
ON CONFLICT (name) DO NOTHING;
REVOKE ALL ON private.registration_secrets FROM PUBLIC, anon, authenticated;

ALTER TABLE public.students
    ADD COLUMN IF NOT EXISTS identity_last4_hash TEXT;
ALTER TABLE public.students
    ADD COLUMN IF NOT EXISTS national_id_hash TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS students_national_id_hash_uidx
    ON public.students(national_id_hash)
    WHERE national_id_hash IS NOT NULL;

CREATE TABLE IF NOT EXISTS private.student_identity_attempts (
    student_id TEXT PRIMARY KEY,
    window_started TIMESTAMPTZ NOT NULL,
    failed_attempts INTEGER NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
REVOKE ALL ON private.student_identity_attempts FROM PUBLIC, anon, authenticated;

-- Admins can enter a full national ID or only its final four digits. The
-- browser calls this RPC so the private HMAC secret never leaves Postgres.
CREATE OR REPLACE FUNCTION public.admin_set_student_identity_last4(
    p_student_id TEXT,
    p_identity TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, private, pg_temp
AS $$
DECLARE
    v_student_id TEXT := NULLIF(btrim(p_student_id), '');
    v_digits TEXT := regexp_replace(COALESCE(p_identity, ''), '[^0-9]', '', 'g');
    v_last4 TEXT;
    v_secret BYTEA;
    v_updated INTEGER;
BEGIN
    IF NOT is_admin() THEN
        RAISE EXCEPTION 'not authorized';
    END IF;
    IF v_student_id IS NULL OR v_digits !~ '^([0-9]{4}|[0-9]{13})$' THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_IDENTITY', 'message', 'กรุณากรอกเลขบัตรประชาชนหรือเลขท้าย 4 หลัก');
    END IF;

    v_last4 := right(v_digits, 4);
    SELECT secret INTO v_secret
    FROM private.registration_secrets
    WHERE name = 'student_identity_hmac';

    IF length(v_digits) = 13 AND EXISTS (
        SELECT 1
        FROM students
        WHERE national_id_hash = encode(hmac(convert_to(v_digits, 'UTF8'), v_secret, 'sha256'::text), 'hex')
          AND student_id IS DISTINCT FROM v_student_id
    ) THEN
        RETURN jsonb_build_object('success', false, 'code', 'DUPLICATE_NATIONAL_ID', 'message', 'เลขบัตรประชาชนนี้ถูกผูกกับนักเรียนรหัสอื่นแล้ว');
    END IF;

    UPDATE students
    SET identity_last4_hash = encode(hmac(convert_to(v_last4, 'UTF8'), v_secret, 'sha256'::text), 'hex'),
        national_id_hash = CASE
            WHEN length(v_digits) = 13
            THEN encode(hmac(convert_to(v_digits, 'UTF8'), v_secret, 'sha256'::text), 'hex')
            ELSE national_id_hash
        END
    WHERE student_id = v_student_id;
    GET DIAGNOSTICS v_updated = ROW_COUNT;

    IF v_updated = 0 THEN
        RETURN jsonb_build_object('success', false, 'code', 'STUDENT_NOT_FOUND', 'message', 'ไม่พบนักเรียนรหัสนี้');
    END IF;
    RETURN jsonb_build_object('success', true, 'student_id', v_student_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_student_identity_last4_batch(p_rows JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, private, pg_temp
AS $$
DECLARE
    v_row JSONB;
    v_result JSONB;
    v_count INTEGER := 0;
BEGIN
    IF NOT is_admin() THEN
        RAISE EXCEPTION 'not authorized';
    END IF;
    IF jsonb_typeof(COALESCE(p_rows, '[]'::jsonb)) <> 'array' THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'ข้อมูลยืนยันตัวตนต้องเป็นรายการ');
    END IF;
    FOR v_row IN SELECT value FROM jsonb_array_elements(COALESCE(p_rows, '[]'::jsonb)) LOOP
        v_result := public.admin_set_student_identity_last4(
            v_row->>'student_id',
            COALESCE(v_row->>'national_id', v_row->>'last4')
        );
        IF COALESCE((v_result->>'success')::BOOLEAN, false) THEN
            v_count := v_count + 1;
        END IF;
    END LOOP;
    RETURN jsonb_build_object('success', true, 'updated', v_count);
END;
$$;

-- Accept either a school ID or a 13-digit national ID. National IDs are
-- compared as keyed HMACs; the plaintext value is never stored.
CREATE OR REPLACE FUNCTION public.lookup_student_for_registration(p_student_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, private, pg_temp
AS $$
DECLARE
    v_input TEXT := btrim(COALESCE(p_student_id, ''));
    v_digits TEXT;
    v_student RECORD;
    v_secret BYTEA;
    v_hash TEXT;
    v_attempt_key TEXT;
    v_window TIMESTAMPTZ;
    v_attempts INTEGER;
BEGIN
    v_digits := regexp_replace(v_input, '[^0-9]', '', 'g');
    IF v_digits ~ '^[0-9]{13}$' AND v_input ~ '^[0-9 -]+$' THEN
        SELECT secret INTO v_secret
        FROM private.registration_secrets
        WHERE name = 'student_identity_hmac';
        v_hash := encode(hmac(convert_to(v_digits, 'UTF8'), v_secret, 'sha256'::text), 'hex');
        v_attempt_key := 'national:' || v_hash;

        PERFORM pg_advisory_xact_lock(hashtextextended('national-id-lookup:' || v_hash, 0));
        SELECT window_started, failed_attempts INTO v_window, v_attempts
        FROM private.student_identity_attempts
        WHERE student_id = v_attempt_key
        FOR UPDATE;
        IF v_window IS NULL OR v_window < now() - interval '10 minutes' THEN
            v_window := now();
            v_attempts := 0;
        END IF;
        v_attempts := COALESCE(v_attempts, 0);
        IF v_attempts >= 6 THEN
            RETURN jsonb_build_object('found', false, 'code', 'RATE_LIMITED', 'message', 'ค้นหาถี่เกินไป กรุณารอ 10 นาทีแล้วลองใหม่');
        END IF;

        SELECT student_id, prefix, first_name, last_name, level INTO v_student
        FROM students
        WHERE national_id_hash = v_hash AND status = 'active';
        IF NOT FOUND THEN
            INSERT INTO private.student_identity_attempts(student_id, window_started, failed_attempts, updated_at)
            VALUES (v_attempt_key, v_window, v_attempts + 1, now())
            ON CONFLICT (student_id) DO UPDATE SET window_started = EXCLUDED.window_started,
                failed_attempts = EXCLUDED.failed_attempts, updated_at = EXCLUDED.updated_at;
            RETURN jsonb_build_object('found', false);
        END IF;

        INSERT INTO private.student_identity_attempts(student_id, window_started, failed_attempts, updated_at)
        VALUES (v_attempt_key, now(), 0, now())
        ON CONFLICT (student_id) DO UPDATE SET window_started = EXCLUDED.window_started,
            failed_attempts = 0, updated_at = EXCLUDED.updated_at;
    ELSE
        SELECT student_id, prefix, first_name, last_name, level INTO v_student
        FROM students
        WHERE student_id = NULLIF(v_input, '') AND status = 'active';
        IF NOT FOUND THEN
            RETURN jsonb_build_object('found', false);
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'found', true,
        'student_id', v_student.student_id,
        'prefix', v_student.prefix,
        'first_name', v_student.first_name,
        'last_name', v_student.last_name,
        'level', v_student.level
    );
END;
$$;

-- Public verification returns no personal data beyond the exact ID supplied.
CREATE OR REPLACE FUNCTION public.verify_student_identity(
    p_student_id TEXT,
    p_last4 TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, private, pg_temp
AS $$
DECLARE
    v_student RECORD;
    v_digits TEXT := regexp_replace(COALESCE(p_last4, ''), '[^0-9]', '', 'g');
    v_last4 TEXT;
    v_secret BYTEA;
    v_hash TEXT;
    v_student_key TEXT := COALESCE(NULLIF(btrim(p_student_id), ''), '__empty__');
    v_window TIMESTAMPTZ;
    v_attempts INTEGER;
BEGIN
    IF length(v_digits) <> 4 THEN
        RETURN jsonb_build_object('verified', false, 'code', 'INVALID_LAST4', 'message', 'กรุณากรอกเลขท้ายบัตรประชาชน 4 หลัก');
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended('identity-verify:' || v_student_key, 0));
    SELECT window_started, failed_attempts INTO v_window, v_attempts
    FROM private.student_identity_attempts
    WHERE student_id = v_student_key
    FOR UPDATE;
    IF v_window IS NULL OR v_window < now() - interval '10 minutes' THEN
        v_window := now();
        v_attempts := 0;
    END IF;
    v_attempts := COALESCE(v_attempts, 0);
    IF v_attempts >= 6 THEN
        RETURN jsonb_build_object('verified', false, 'code', 'RATE_LIMITED', 'message', 'ยืนยันตัวตนผิดหลายครั้ง กรุณารอ 10 นาทีแล้วลองใหม่');
    END IF;
    v_last4 := right(v_digits, 4);
    SELECT secret INTO v_secret
    FROM private.registration_secrets
    WHERE name = 'student_identity_hmac';
    v_hash := encode(hmac(convert_to(v_last4, 'UTF8'), v_secret, 'sha256'::text), 'hex');

    SELECT student_id, first_name, last_name, level, identity_last4_hash
    INTO v_student
    FROM students
    WHERE student_id = NULLIF(btrim(p_student_id), '')
      AND status = 'active';

    IF NOT FOUND THEN
        INSERT INTO private.student_identity_attempts(student_id, window_started, failed_attempts, updated_at)
        VALUES (v_student_key, v_window, v_attempts + 1, now())
        ON CONFLICT (student_id) DO UPDATE SET window_started = EXCLUDED.window_started,
            failed_attempts = EXCLUDED.failed_attempts, updated_at = EXCLUDED.updated_at;
        RETURN jsonb_build_object('verified', false, 'code', 'STUDENT_NOT_FOUND', 'message', 'ไม่พบรหัสนักเรียน');
    END IF;
    IF v_student.identity_last4_hash IS NULL THEN
        INSERT INTO private.student_identity_attempts(student_id, window_started, failed_attempts, updated_at)
        VALUES (v_student_key, v_window, v_attempts + 1, now())
        ON CONFLICT (student_id) DO UPDATE SET window_started = EXCLUDED.window_started,
            failed_attempts = EXCLUDED.failed_attempts, updated_at = EXCLUDED.updated_at;
        RETURN jsonb_build_object('verified', false, 'code', 'IDENTITY_NOT_CONFIGURED', 'message', 'นักเรียนรหัสนี้ยังไม่มีข้อมูลยืนยันตัวตน กรุณาแจ้งผู้ดูแลระบบ');
    END IF;
    IF v_student.identity_last4_hash IS DISTINCT FROM v_hash THEN
        INSERT INTO private.student_identity_attempts(student_id, window_started, failed_attempts, updated_at)
        VALUES (v_student_key, v_window, v_attempts + 1, now())
        ON CONFLICT (student_id) DO UPDATE SET window_started = EXCLUDED.window_started,
            failed_attempts = EXCLUDED.failed_attempts, updated_at = EXCLUDED.updated_at;
        RETURN jsonb_build_object('verified', false, 'code', 'IDENTITY_MISMATCH', 'message', 'เลขท้ายบัตรประชาชนไม่ตรงกัน');
    END IF;
    INSERT INTO private.student_identity_attempts(student_id, window_started, failed_attempts, updated_at)
    VALUES (v_student_key, now(), 0, now())
    ON CONFLICT (student_id) DO UPDATE SET window_started = EXCLUDED.window_started,
        failed_attempts = 0, updated_at = EXCLUDED.updated_at;
    RETURN jsonb_build_object('verified', true, 'student_id', v_student.student_id);
END;
$$;

-- Cross-device lookups require both the school ID and the last four digits.
CREATE OR REPLACE FUNCTION public.get_my_registrations_by_verified_student(
    p_student_id TEXT,
    p_last4 TEXT
)
RETURNS TABLE (
    id UUID,
    registration_token UUID,
    club_id UUID,
    student_id TEXT,
    prefix TEXT,
    first_name TEXT,
    last_name TEXT,
    level TEXT,
    registration_status TEXT,
    academic_year TEXT,
    semester TEXT,
    created_at TIMESTAMPTZ,
    club_name TEXT,
    teacher TEXT,
    location TEXT
)
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = public, extensions, private, pg_temp
AS $$
    WITH identity_check AS MATERIALIZED (
        SELECT public.verify_student_identity(p_student_id, p_last4) AS result
    ), secret_row AS (
        SELECT secret FROM private.registration_secrets WHERE name = 'student_identity_hmac' LIMIT 1
    ), verified_student AS (
        SELECT s.student_id
        FROM students s
        CROSS JOIN secret_row
        CROSS JOIN identity_check
        WHERE s.student_id = NULLIF(btrim(p_student_id), '')
          AND s.status = 'active'
          AND COALESCE((identity_check.result->>'verified')::BOOLEAN, false)
          AND length(regexp_replace(COALESCE(p_last4, ''), '[^0-9]', '', 'g')) = 4
          AND s.identity_last4_hash = encode(hmac(
              convert_to(right(regexp_replace(COALESCE(p_last4, ''), '[^0-9]', '', 'g'), 4), 'UTF8'),
              secret_row.secret, 'sha256'::text
          ), 'hex')
    ), cfg AS (
        SELECT COALESCE(value->>'academic_year', '2569') AS academic_year,
               COALESCE(value->>'semester', '1') AS semester,
               CASE WHEN value->>'registration_scope' = 'academic_year' THEN 'academic_year' ELSE 'semester' END AS registration_scope
        FROM settings WHERE key = 'school_config' LIMIT 1
    )
    SELECT r.id, r.registration_token, r.club_id, r.student_id,
           r.prefix, r.first_name, r.last_name, r.level,
           r.registration_status, r.academic_year, r.semester, r.created_at,
           c.name, c.teacher, c.location
    FROM registrations r
    JOIN clubs c ON c.id = r.club_id
    JOIN verified_student vs ON vs.student_id = r.student_id
    CROSS JOIN cfg
    WHERE r.academic_year = cfg.academic_year
      AND (cfg.registration_scope = 'academic_year' OR r.semester = cfg.semester);
$$;

CREATE OR REPLACE FUNCTION public.get_my_registrations_history_by_verified_student(
    p_student_id TEXT,
    p_last4 TEXT
)
RETURNS TABLE (
    id UUID,
    registration_token UUID,
    club_id UUID,
    student_id TEXT,
    prefix TEXT,
    first_name TEXT,
    last_name TEXT,
    level TEXT,
    registration_status TEXT,
    academic_year TEXT,
    semester TEXT,
    created_at TIMESTAMPTZ,
    club_name TEXT,
    teacher TEXT,
    location TEXT
)
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = public, extensions, private, pg_temp
AS $$
    WITH identity_check AS MATERIALIZED (
        SELECT public.verify_student_identity(p_student_id, p_last4) AS result
    ), secret_row AS (
        SELECT secret FROM private.registration_secrets WHERE name = 'student_identity_hmac' LIMIT 1
    ), verified_student AS (
        SELECT s.student_id
        FROM students s
        CROSS JOIN secret_row
        CROSS JOIN identity_check
        WHERE s.student_id = NULLIF(btrim(p_student_id), '')
          AND s.status = 'active'
          AND COALESCE((identity_check.result->>'verified')::BOOLEAN, false)
          AND length(regexp_replace(COALESCE(p_last4, ''), '[^0-9]', '', 'g')) = 4
          AND s.identity_last4_hash = encode(hmac(
              convert_to(right(regexp_replace(COALESCE(p_last4, ''), '[^0-9]', '', 'g'), 4), 'UTF8'),
              secret_row.secret, 'sha256'::text
          ), 'hex')
    )
    SELECT r.id, r.registration_token, r.club_id, r.student_id,
           r.prefix, r.first_name, r.last_name, r.level,
           r.registration_status, r.academic_year, r.semester, r.created_at,
           c.name, c.teacher, c.location
    FROM registrations r
    JOIN clubs c ON c.id = r.club_id
    JOIN verified_student vs ON vs.student_id = r.student_id
    ORDER BY r.academic_year DESC, r.semester DESC, r.created_at DESC;
$$;

-- This cancellation function deliberately has no token parameter. A browser
-- token can display a receipt, but cannot release a seat by itself.
CREATE OR REPLACE FUNCTION public.student_cancel_registration_secure(
    p_registration_id UUID,
    p_student_id TEXT DEFAULT NULL,
    p_last4 TEXT DEFAULT NULL,
    p_reference TEXT DEFAULT NULL,
    p_first_name TEXT DEFAULT NULL,
    p_last_name TEXT DEFAULT NULL,
    p_level TEXT DEFAULT NULL,
    p_ip_address TEXT DEFAULT NULL,
    p_user_agent TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, private, pg_temp
AS $$
DECLARE
    v_reg RECORD;
    v_config JSONB;
    v_period JSONB;
    v_year TEXT;
    v_semester TEXT;
    v_scope TEXT;
    v_secret BYTEA;
    v_hash TEXT;
    v_digits TEXT;
    v_identity JSONB;
BEGIN
    SELECT value INTO v_config FROM settings WHERE key = 'school_config';
    SELECT value INTO v_period FROM settings WHERE key = 'registration_period';
    IF COALESCE((v_config->>'allow_student_cancellation')::BOOLEAN, false) IS NOT TRUE THEN
        RETURN jsonb_build_object('success', false, 'code', 'CANCELLATION_DISABLED', 'message', 'ผู้ดูแลระบบยังไม่เปิดให้ยกเลิกการลงทะเบียนด้วยตนเอง');
    END IF;
    IF COALESCE((v_period->>'is_active')::BOOLEAN, false) IS NOT TRUE
       OR (NULLIF(v_period->>'start_time', '') IS NOT NULL AND now() < (v_period->>'start_time')::TIMESTAMPTZ)
       OR (NULLIF(v_period->>'end_time', '') IS NOT NULL AND now() > (v_period->>'end_time')::TIMESTAMPTZ) THEN
        RETURN jsonb_build_object('success', false, 'code', 'REGISTRATION_CLOSED', 'message', 'หมดเวลาลงทะเบียนแล้ว ไม่สามารถยกเลิกหรือเปลี่ยนชุมนุมได้');
    END IF;

    v_year := COALESCE(v_config->>'academic_year', '2569');
    v_semester := COALESCE(v_config->>'semester', '1');
    v_scope := CASE WHEN v_config->>'registration_scope' = 'academic_year' THEN 'academic_year' ELSE 'semester' END;

    SELECT r.*, c.name AS club_name
    INTO v_reg
    FROM registrations r
    JOIN clubs c ON c.id = r.club_id
    WHERE r.id = p_registration_id
      AND r.academic_year = v_year
      AND (v_scope = 'academic_year' OR r.semester = v_semester)
    FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'ไม่พบรายการลงทะเบียนในรอบปัจจุบัน');
    END IF;

    IF v_reg.student_id IS NOT NULL THEN
        IF NULLIF(btrim(p_student_id), '') IS NULL OR length(regexp_replace(COALESCE(p_last4, ''), '[^0-9]', '', 'g')) <> 4 THEN
            RETURN jsonb_build_object('success', false, 'code', 'IDENTITY_REQUIRED', 'message', 'กรุณายืนยันรหัสนักเรียนและเลขท้ายบัตรประชาชน 4 หลัก');
        END IF;
        v_identity := public.verify_student_identity(p_student_id, p_last4);
        IF COALESCE((v_identity->>'verified')::BOOLEAN, false) IS NOT TRUE THEN
            RETURN jsonb_build_object('success', false, 'code', COALESCE(v_identity->>'code', 'FORBIDDEN'), 'message', COALESCE(v_identity->>'message', 'ยืนยันตัวตนไม่สำเร็จ'));
        END IF;
        SELECT secret INTO v_secret FROM private.registration_secrets WHERE name = 'student_identity_hmac';
        v_digits := regexp_replace(p_last4, '[^0-9]', '', 'g');
        v_hash := encode(hmac(convert_to(right(v_digits, 4), 'UTF8'), v_secret, 'sha256'::text), 'hex');
        IF NOT EXISTS (
            SELECT 1 FROM students s
            WHERE s.student_id = btrim(p_student_id)
              AND s.status = 'active'
              AND s.identity_last4_hash = v_hash
        ) OR v_reg.student_id IS DISTINCT FROM btrim(p_student_id) THEN
            RETURN jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'ข้อมูลยืนยันตัวตนไม่ตรงกับรายการลงทะเบียนนี้');
        END IF;
    ELSE
        IF NULLIF(btrim(p_reference), '') IS NULL OR NULLIF(btrim(p_first_name), '') IS NULL
           OR NULLIF(btrim(p_last_name), '') IS NULL OR NULLIF(btrim(p_level), '') IS NULL THEN
            RETURN jsonb_build_object('success', false, 'code', 'IDENTITY_REQUIRED', 'message', 'กรุณากรอกเบอร์โทร ชื่อ นามสกุล และระดับชั้นให้ครบถ้วน');
        END IF;
        SELECT secret INTO v_secret FROM private.registration_secrets WHERE name = 'pending_phone_hmac';
        v_hash := encode(hmac(convert_to(
            CASE WHEN p_reference ~* '^TMP-' THEN upper(btrim(p_reference)) ELSE btrim(p_reference) END || ':' ||
            lower(btrim(p_first_name)) || ':' || lower(btrim(p_last_name)) || ':' || lower(btrim(p_level)),
            'UTF8'), v_secret, 'sha256'::text), 'hex');
        IF v_reg.pending_contact_hash IS DISTINCT FROM v_hash THEN
            RETURN jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'ข้อมูลอ้างอิงไม่ตรงกับรายการลงทะเบียนนี้');
        END IF;
    END IF;

    PERFORM 1 FROM clubs WHERE id = v_reg.club_id FOR UPDATE;
    DELETE FROM registrations WHERE id = v_reg.id;
    UPDATE clubs SET enrolled_count = GREATEST(enrolled_count - 1, 0) WHERE id = v_reg.club_id;
    INSERT INTO audit_logs (student_id, student_name, action, club_name, ip_address, user_agent, details)
    VALUES (v_reg.student_id, concat_ws('', v_reg.prefix, v_reg.first_name, ' ', v_reg.last_name),
            'STUDENT_REGISTRATION_CANCELLED', v_reg.club_name,
            left(COALESCE(p_ip_address, 'Unknown IP'), 128),
            left(COALESCE(p_user_agent, 'Unknown Device'), 500),
            'registration_id=' || v_reg.id || '; scope=' || v_scope);
    RETURN jsonb_build_object('success', true, 'club_id', v_reg.club_id, 'registration_id', v_reg.id);
END;
$$;

-- Pending rows are linked only when the official name and class match. The
-- wrapper leaves unmatched rows pending for an administrator to review.
CREATE OR REPLACE FUNCTION public.admin_approve_registration_safe(
    p_registration_id UUID,
    p_student_id TEXT,
    p_ip_address TEXT DEFAULT NULL,
    p_user_agent TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_reg RECORD;
    v_student RECORD;
BEGIN
    IF NOT is_admin() THEN
        RETURN jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'ไม่มีสิทธิ์ผู้ดูแลระบบ');
    END IF;
    SELECT student_id, registration_status, first_name, last_name, level
    INTO v_reg FROM registrations WHERE id = p_registration_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'ไม่พบรายการสมัคร');
    END IF;
    IF v_reg.registration_status <> 'pending' OR v_reg.student_id IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'NOT_PENDING', 'message', 'รายการนี้ไม่ได้อยู่ในสถานะรอจับคู่แล้ว');
    END IF;
    SELECT first_name, last_name, level INTO v_student FROM students
    WHERE student_id = NULLIF(btrim(p_student_id), '') AND status = 'active';
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'STUDENT_NOT_FOUND', 'message', 'ไม่พบรหัสนักเรียนที่ยังใช้งาน');
    END IF;
    IF lower(btrim(v_reg.first_name)) IS DISTINCT FROM lower(btrim(v_student.first_name))
       OR lower(btrim(v_reg.last_name)) IS DISTINCT FROM lower(btrim(v_student.last_name))
       OR lower(btrim(v_reg.level)) IS DISTINCT FROM lower(btrim(v_student.level)) THEN
        RETURN jsonb_build_object('success', false, 'code', 'STUDENT_DATA_MISMATCH', 'message', 'ชื่อ นามสกุล หรือห้องเรียนไม่ตรงกัน กรุณาตรวจสอบก่อนผูกข้อมูล');
    END IF;
    RETURN public.admin_approve_registration(p_registration_id, p_student_id, p_ip_address, p_user_agent);
END;
$$;

CREATE OR REPLACE FUNCTION public.claim_pending_registrations_by_student_identity_safe(p_student_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_student RECORD;
    v_year TEXT;
    v_semester TEXT;
    v_scope TEXT;
    v_mismatch INTEGER;
BEGIN
    SELECT student_id, first_name, last_name, level INTO v_student
    FROM students WHERE student_id = NULLIF(btrim(p_student_id), '') AND status = 'active';
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'STUDENT_NOT_FOUND', 'linked_count', 0);
    END IF;
    SELECT COALESCE(value->>'academic_year', '2569'), COALESCE(value->>'semester', '1'),
           CASE WHEN value->>'registration_scope' = 'academic_year' THEN 'academic_year' ELSE 'semester' END
    INTO v_year, v_semester, v_scope FROM settings WHERE key = 'school_config';
    SELECT count(*) INTO v_mismatch
    FROM registrations
    WHERE registration_status = 'pending' AND student_id IS NULL
      AND academic_year = v_year AND (v_scope = 'academic_year' OR semester = v_semester)
      AND lower(btrim(first_name)) = lower(btrim(v_student.first_name))
      AND lower(btrim(last_name)) = lower(btrim(v_student.last_name))
      AND lower(btrim(level)) IS DISTINCT FROM lower(btrim(v_student.level));
    IF v_mismatch > 0 THEN
        RETURN jsonb_build_object('success', false, 'code', 'AMBIGUOUS_MATCH', 'linked_count', 0, 'message', 'พบรายการชื่อเดียวกันแต่ห้องเรียนไม่ตรงกัน กรุณาให้ผู้ดูแลผูกข้อมูล');
    END IF;
    RETURN public.claim_pending_registrations_by_student_identity(p_student_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.claim_pending_registrations_by_student_identity_verified(
    p_student_id TEXT,
    p_last4 TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, private, pg_temp
AS $$
DECLARE
    v_identity JSONB;
BEGIN
    v_identity := public.verify_student_identity(p_student_id, p_last4);
    IF COALESCE((v_identity->>'verified')::BOOLEAN, false) IS NOT TRUE THEN
        RETURN jsonb_build_object('success', false, 'code', v_identity->>'code', 'linked_count', 0,
                                  'message', COALESCE(v_identity->>'message', 'ยืนยันตัวตนไม่สำเร็จ'));
    END IF;
    RETURN public.claim_pending_registrations_by_student_identity_safe(p_student_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.claim_pending_registrations_by_student_safe(
    p_registration_tokens UUID[],
    p_student_id TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_student RECORD;
    v_mismatch INTEGER;
BEGIN
    SELECT first_name, last_name, level INTO v_student
    FROM students WHERE student_id = NULLIF(btrim(p_student_id), '') AND status = 'active';
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'STUDENT_NOT_FOUND', 'linked_count', 0);
    END IF;
    SELECT count(*) INTO v_mismatch
    FROM registrations
    WHERE registration_token = ANY(COALESCE(p_registration_tokens, ARRAY[]::UUID[]))
      AND registration_status = 'pending'
      AND (lower(btrim(first_name)) <> lower(btrim(v_student.first_name))
           OR lower(btrim(last_name)) <> lower(btrim(v_student.last_name))
           OR lower(btrim(level)) <> lower(btrim(v_student.level)));
    IF v_mismatch > 0 THEN
        RETURN jsonb_build_object('success', false, 'code', 'STUDENT_DATA_MISMATCH', 'linked_count', 0, 'message', 'ข้อมูลนักเรียนกับห้องเรียนไม่ตรงกัน กรุณาให้ผู้ดูแลตรวจสอบ');
    END IF;
    RETURN public.claim_pending_registrations_by_student(p_registration_tokens, p_student_id);
END;
$$;

-- Rate limits are keyed by a one-way student identity, never by IP/device.
CREATE TABLE IF NOT EXISTS private.registration_rate_limits (
    identity_key TEXT PRIMARY KEY,
    window_started TIMESTAMPTZ NOT NULL,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
REVOKE ALL ON private.registration_rate_limits FROM PUBLIC, anon, authenticated;

-- Move the original atomic seat function behind a private wrapper once. The
-- wrapper below consumes limits before every actual attempt while preserving
-- idempotent retries using the same request key.
DO $$
BEGIN
    IF to_regprocedure('private.register_student_atomic_unlimited(uuid,text,text,text,text,text,text,text,uuid)') IS NULL
       AND to_regprocedure('public.register_student_atomic(uuid,text,text,text,text,text,text,text,uuid)') IS NOT NULL THEN
        REVOKE ALL ON FUNCTION public.register_student_atomic(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID) FROM PUBLIC, anon, authenticated;
        ALTER FUNCTION public.register_student_atomic(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID) SET SCHEMA private;
        ALTER FUNCTION private.register_student_atomic(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID) RENAME TO register_student_atomic_unlimited;
    END IF;
END;
$$;
REVOKE ALL ON FUNCTION private.register_student_atomic_unlimited(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.register_student_atomic(
    p_club_id UUID,
    p_student_id TEXT,
    p_prefix TEXT,
    p_first_name TEXT,
    p_last_name TEXT,
    p_level TEXT,
    p_ip_address TEXT,
    p_user_agent TEXT,
    p_request_key UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, private, pg_temp
AS $$
DECLARE
    v_key TEXT;
    v_student_id TEXT := NULLIF(btrim(p_student_id), '');
    v_reference TEXT;
    v_phone_secret BYTEA;
    v_identity_hash TEXT;
    v_now TIMESTAMPTZ := now();
    v_window TIMESTAMPTZ;
    v_count INTEGER;
    v_result JSONB;
BEGIN
    IF p_request_key IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'คำขอไม่มีรหัสอ้างอิง กรุณาลองใหม่');
    END IF;
    IF EXISTS (SELECT 1 FROM registrations WHERE request_key = p_request_key) THEN
        RETURN private.register_student_atomic_unlimited(
            p_club_id, p_student_id, p_prefix, p_first_name, p_last_name, p_level,
            p_ip_address, p_user_agent, p_request_key
        );
    END IF;

    IF EXISTS (SELECT 1 FROM students WHERE student_id = v_student_id AND status = 'active') THEN
        v_key := 'student:' || v_student_id;
    ELSIF v_student_id ~ '^0[0-9]{9}$' OR v_student_id ~* '^TMP-[A-Z0-9]{6,32}$' THEN
        v_reference := CASE WHEN v_student_id ~* '^TMP-' THEN upper(v_student_id) ELSE v_student_id END;
        SELECT secret INTO v_phone_secret FROM private.registration_secrets WHERE name = 'pending_phone_hmac';
        v_identity_hash := encode(hmac(convert_to(
            v_reference || ':' || lower(btrim(COALESCE(p_first_name, ''))) || ':' ||
            lower(btrim(COALESCE(p_last_name, ''))) || ':' || lower(btrim(COALESCE(p_level, ''))),
            'UTF8'), v_phone_secret, 'sha256'::text), 'hex');
        v_key := 'pending:' || v_identity_hash;
    ELSE
        v_key := 'name:' || encode(digest(lower(btrim(COALESCE(p_first_name, '') || ':' || COALESCE(p_last_name, '') || ':' || COALESCE(p_level, ''))), 'sha256'), 'hex');
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended('rate:' || v_key, 0));
    SELECT window_started, attempt_count INTO v_window, v_count
    FROM private.registration_rate_limits
    WHERE identity_key = v_key
    FOR UPDATE;
    IF v_window IS NULL OR v_window < v_now - interval '1 minute' THEN
        v_window := v_now;
        v_count := 0;
    END IF;
    v_count := COALESCE(v_count, 0);
    IF v_count >= 8 THEN
        RETURN jsonb_build_object('success', false, 'code', 'RATE_LIMITED', 'message', 'ส่งคำขอถี่เกินไป กรุณารอสักครู่แล้วลองใหม่');
    END IF;
    INSERT INTO private.registration_rate_limits(identity_key, window_started, attempt_count, updated_at)
    VALUES (v_key, v_window, v_count + 1, v_now)
    ON CONFLICT (identity_key) DO UPDATE SET
        window_started = EXCLUDED.window_started,
        attempt_count = EXCLUDED.attempt_count,
        updated_at = EXCLUDED.updated_at;
    v_result := private.register_student_atomic_unlimited(
        p_club_id, p_student_id, p_prefix, p_first_name, p_last_name, p_level,
        p_ip_address, p_user_agent, p_request_key
    );
    RETURN v_result;
END;
$$;

DROP TRIGGER IF EXISTS registrations_rate_limit_trigger ON public.registrations;

-- Old overloads may remain from earlier schema versions. The browser only
-- uses the request-key signature; revoke public access to every other variant.
DO $$
DECLARE
    v_function RECORD;
    v_current_signature OID := to_regprocedure(
        'public.register_student_atomic(uuid,text,text,text,text,text,text,text,uuid)'
    );
BEGIN
    FOR v_function IN
        SELECT p.oid
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'register_student_atomic'
          AND p.oid <> v_current_signature
    LOOP
        EXECUTE format(
            'REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated',
            v_function.oid::regprocedure
        );
    END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_set_student_identity_last4(TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_set_student_identity_last4_batch(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.lookup_student_for_registration(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.verify_student_identity(TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_my_registrations_by_verified_student(TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_my_registrations_history_by_verified_student(TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.student_cancel_registration_secure(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_approve_registration_safe(UUID, TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.claim_pending_registrations_by_student_identity_safe(TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.claim_pending_registrations_by_student_identity_verified(TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.claim_pending_registrations_by_student_safe(UUID[], TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.register_student_atomic(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_student_identity_last4(TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_student_identity_last4_batch(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.lookup_student_for_registration(TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.verify_student_identity(TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_registrations_by_verified_student(TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_registrations_history_by_verified_student(TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.student_cancel_registration_secure(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_approve_registration_safe(UUID, TEXT, TEXT, TEXT) TO authenticated;
REVOKE ALL ON FUNCTION public.claim_pending_registrations_by_student_identity(TEXT) FROM anon, authenticated;
REVOKE ALL ON FUNCTION public.claim_pending_registrations_by_student(UUID[], TEXT) FROM anon, authenticated;
REVOKE ALL ON FUNCTION public.claim_pending_registrations_by_student_safe(UUID[], TEXT) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.register_student_atomic(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID) TO anon, authenticated;

-- Remove the old student-ID-only history access and token-bypass cancellation.
REVOKE ALL ON FUNCTION public.get_my_registrations_by_student(TEXT) FROM anon, authenticated;
REVOKE ALL ON FUNCTION public.get_my_registrations_history_by_student(TEXT) FROM anon, authenticated;
REVOKE ALL ON FUNCTION public.student_cancel_registration(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, UUID, TEXT, TEXT) FROM anon, authenticated;

COMMIT;
