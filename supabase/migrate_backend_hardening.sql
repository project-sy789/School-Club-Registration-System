-- Backend hardening migration
-- Run after supabase/setup_database.sql.
-- This migration keeps first-come-first-served registration while moving all
-- trusted decisions into Postgres and separating public from admin access.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon, authenticated;
CREATE TABLE IF NOT EXISTS private.registration_secrets (
    name TEXT PRIMARY KEY,
    secret BYTEA NOT NULL
);
INSERT INTO private.registration_secrets(name, secret)
VALUES ('pending_phone_hmac', gen_random_bytes(32))
ON CONFLICT (name) DO NOTHING;
REVOKE ALL ON private.registration_secrets FROM PUBLIC, anon, authenticated;

ALTER TABLE settings
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();

ALTER TABLE students
    ADD COLUMN IF NOT EXISTS id UUID DEFAULT gen_random_uuid();

UPDATE students SET id = gen_random_uuid() WHERE id IS NULL;
ALTER TABLE students ALTER COLUMN id SET NOT NULL;
ALTER TABLE students DROP CONSTRAINT IF EXISTS students_pkey;
ALTER TABLE students ALTER COLUMN student_id DROP NOT NULL;
ALTER TABLE students ADD CONSTRAINT students_pkey PRIMARY KEY (id);
ALTER TABLE students DROP CONSTRAINT IF EXISTS students_student_id_key;
ALTER TABLE students ADD CONSTRAINT students_student_id_key UNIQUE (student_id);

ALTER TABLE registrations
    ADD COLUMN IF NOT EXISTS registration_token UUID DEFAULT gen_random_uuid();
ALTER TABLE registrations
    ADD COLUMN IF NOT EXISTS request_key UUID DEFAULT gen_random_uuid();
UPDATE registrations
SET registration_token = gen_random_uuid()
WHERE registration_token IS NULL;
UPDATE registrations
SET request_key = gen_random_uuid()
WHERE request_key IS NULL;
ALTER TABLE registrations ALTER COLUMN registration_token SET NOT NULL;
ALTER TABLE registrations ALTER COLUMN request_key SET NOT NULL;
ALTER TABLE registrations
    ADD COLUMN IF NOT EXISTS pending_contact_hash TEXT;
ALTER TABLE registrations
    ADD COLUMN IF NOT EXISTS pending_contact_hint TEXT;
CREATE UNIQUE INDEX IF NOT EXISTS registrations_token_uidx
    ON registrations(registration_token);
CREATE UNIQUE INDEX IF NOT EXISTS registrations_request_key_uidx
    ON registrations(request_key);

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM registrations
        WHERE student_id IS NOT NULL
        GROUP BY student_id, academic_year, semester
        HAVING COUNT(*) > 1
    ) THEN
        RAISE EXCEPTION 'Duplicate student_id registrations exist in the same term; resolve them before applying this migration.';
    END IF;
    IF EXISTS (
        SELECT 1 FROM registrations
        GROUP BY lower(btrim(first_name)), lower(btrim(last_name)), academic_year, semester
        HAVING COUNT(*) > 1
    ) THEN
        RAISE EXCEPTION 'Duplicate normalized student names exist in the same term; resolve them before applying this migration.';
    END IF;
END;
$$;

ALTER TABLE clubs
    DROP CONSTRAINT IF EXISTS clubs_capacity_check;
ALTER TABLE clubs
    ADD CONSTRAINT clubs_capacity_check CHECK (capacity > 0);
ALTER TABLE clubs
    DROP CONSTRAINT IF EXISTS clubs_enrolled_count_check;
ALTER TABLE clubs
    ADD CONSTRAINT clubs_enrolled_count_check CHECK (enrolled_count >= 0);

CREATE INDEX IF NOT EXISTS registrations_current_student_idx
    ON registrations(student_id, academic_year, semester)
    WHERE student_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS registrations_one_student_per_term_uidx
    ON registrations(student_id, academic_year, semester)
    WHERE student_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS registrations_one_name_per_term_uidx
    ON registrations(
        lower(btrim(first_name)),
        lower(btrim(last_name)),
        academic_year,
        semester
    );

CREATE UNIQUE INDEX IF NOT EXISTS registrations_one_pending_phone_per_term_uidx
    ON registrations(pending_contact_hash, academic_year, semester)
    WHERE pending_contact_hash IS NOT NULL;

-- Admin identities are Supabase Auth users explicitly granted the admin role.
CREATE TABLE IF NOT EXISTS admin_users (
    user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    role TEXT NOT NULL DEFAULT 'admin' CHECK (role IN ('admin')),
    enabled BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE admin_users ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION is_admin()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM admin_users
        WHERE user_id = auth.uid()
          AND enabled = true
          AND role = 'admin'
    );
$$;

REVOKE ALL ON FUNCTION is_admin() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION is_admin() TO authenticated;

-- Public settings deliberately omit admin credentials.
CREATE OR REPLACE FUNCTION get_public_settings()
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT COALESCE(jsonb_object_agg(key, value - 'admin_password'), '{}'::jsonb)
    FROM settings
    WHERE key IN ('school_config', 'registration_period');
$$;

REVOKE ALL ON FUNCTION get_public_settings() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_public_settings() TO anon, authenticated;

-- Lightweight health check for scheduled keep-alive monitoring. It touches
-- the database without exposing settings, students, or registrations.
CREATE OR REPLACE FUNCTION healthcheck()
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT jsonb_build_object('ok', true);
$$;

REVOKE ALL ON FUNCTION healthcheck() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION healthcheck() TO anon, authenticated;

-- Exact-ID lookup is enough to prefill a form without exposing the students table.
CREATE OR REPLACE FUNCTION lookup_student_for_registration(p_student_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_student RECORD;
BEGIN
    SELECT student_id, prefix, first_name, last_name, level
    INTO v_student
    FROM students
    WHERE student_id = NULLIF(btrim(p_student_id), '')
      AND status = 'active';

    IF NOT FOUND THEN
        RETURN jsonb_build_object('found', false);
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

REVOKE ALL ON FUNCTION lookup_student_for_registration(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION lookup_student_for_registration(TEXT) TO anon, authenticated;

-- A registration token lets a student see their own result without making the
-- registrations table public. Store this token in the browser after submit.
CREATE OR REPLACE FUNCTION get_my_registrations(p_registration_tokens UUID[])
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
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT r.id, r.registration_token, r.club_id, r.student_id,
           r.prefix, r.first_name, r.last_name, r.level,
           r.registration_status, r.academic_year, r.semester, r.created_at,
           c.name, c.teacher, c.location
    FROM registrations r
    JOIN clubs c ON c.id = r.club_id
    WHERE r.registration_token = ANY(COALESCE(p_registration_tokens, ARRAY[]::UUID[]));
$$;

REVOKE ALL ON FUNCTION get_my_registrations(UUID[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_my_registrations(UUID[]) TO anon, authenticated;

DROP FUNCTION IF EXISTS register_student_atomic(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT);

CREATE OR REPLACE FUNCTION register_student_atomic(
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
SET search_path = public, pg_temp
AS $$
DECLARE
    v_club RECORD;
    v_student RECORD;
    v_registration RECORD;
    v_year TEXT;
    v_semester TEXT;
    v_is_active BOOLEAN;
    v_start_time TIMESTAMPTZ;
    v_end_time TIMESTAMPTZ;
    v_student_id TEXT := NULLIF(btrim(p_student_id), '');
    v_pending_contact_hash TEXT;
    v_pending_contact_hint TEXT;
    v_phone_secret BYTEA;
    v_first_name TEXT := NULLIF(btrim(p_first_name), '');
    v_last_name TEXT := NULLIF(btrim(p_last_name), '');
    v_level TEXT := NULLIF(btrim(p_level), '');
    v_prefix TEXT := NULLIF(btrim(p_prefix), '');
    v_status TEXT := 'pending';
BEGIN
    IF p_club_id IS NULL OR v_first_name IS NULL OR v_last_name IS NULL OR v_level IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'กรุณากรอกข้อมูลการสมัครให้ครบถ้วน');
    END IF;

    IF length(v_first_name) > 120 OR length(v_last_name) > 120 OR length(v_level) > 40
       OR length(COALESCE(v_student_id, '')) > 40 THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'ข้อมูลการสมัครยาวเกินกำหนด');
    END IF;
    IF p_request_key IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'คำขอไม่มีรหัสอ้างอิง กรุณาลองใหม่');
    END IF;

    SELECT * INTO v_registration FROM registrations WHERE request_key = p_request_key;
    IF FOUND THEN
        RETURN jsonb_build_object(
            'success', true,
            'status', v_registration.registration_status,
            'registration_id', v_registration.id,
            'registration_token', v_registration.registration_token,
            'message', 'คำขอนี้ถูกบันทึกแล้ว'
        );
    END IF;

    SELECT COALESCE(value->>'academic_year', '2569'),
           COALESCE(value->>'semester', '1')
    INTO v_year, v_semester
    FROM settings
    WHERE key = 'school_config';

    SELECT COALESCE((value->>'is_active')::BOOLEAN, false),
           (value->>'start_time')::TIMESTAMPTZ,
           (value->>'end_time')::TIMESTAMPTZ
    INTO v_is_active, v_start_time, v_end_time
    FROM settings
    WHERE key = 'registration_period';

    IF NOT v_is_active OR (v_start_time IS NOT NULL AND now() < v_start_time)
       OR (v_end_time IS NOT NULL AND now() > v_end_time) THEN
        RETURN jsonb_build_object('success', false, 'code', 'REGISTRATION_CLOSED', 'message', 'ขณะนี้ไม่อยู่ในช่วงเวลาเปิดรับสมัคร');
    END IF;

    -- The club row is the serialization point for first-come-first-served seats.
    SELECT id, name, capacity, enrolled_count, grades
    INTO v_club
    FROM clubs
    WHERE id = p_club_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'CLUB_NOT_FOUND', 'message', 'ไม่พบชุมนุมที่เลือก');
    END IF;

    -- A retry may have been waiting on the club lock while the original
    -- request committed. Re-read the key after serialization so it returns
    -- the original result instead of being rejected as a full club.
    SELECT * INTO v_registration FROM registrations WHERE request_key = p_request_key;
    IF FOUND THEN
        RETURN jsonb_build_object(
            'success', true,
            'status', v_registration.registration_status,
            'registration_id', v_registration.id,
            'registration_token', v_registration.registration_token,
            'message', 'คำขอนี้ถูกบันทึกแล้ว'
        );
    END IF;

    IF NOT (v_level = ANY(v_club.grades) OR split_part(v_level, '/', 1) = ANY(v_club.grades)) THEN
        RETURN jsonb_build_object('success', false, 'code', 'GRADE_NOT_ALLOWED', 'message', 'ชุมนุมนี้ไม่เปิดรับระดับชั้นของคุณ');
    END IF;

    IF v_club.enrolled_count >= v_club.capacity THEN
        RETURN jsonb_build_object('success', false, 'code', 'CLUB_FULL', 'message', 'ชุมนุม "' || v_club.name || '" เต็มโควตาแล้ว');
    END IF;

    IF v_student_id IS NOT NULL THEN
        SELECT student_id, prefix, first_name, last_name, level
        INTO v_student
        FROM students
        WHERE student_id = v_student_id AND status = 'active';

        IF FOUND THEN
            IF lower(btrim(v_student.first_name)) <> lower(v_first_name)
               OR lower(btrim(v_student.last_name)) <> lower(v_last_name)
               OR lower(btrim(v_student.level)) <> lower(v_level) THEN
                RETURN jsonb_build_object('success', false, 'code', 'STUDENT_DATA_MISMATCH', 'message', 'ข้อมูลไม่ตรงกับทะเบียนนักเรียน');
            END IF;
            v_prefix := COALESCE(v_student.prefix, v_prefix);
            v_first_name := v_student.first_name;
            v_last_name := v_student.last_name;
            v_level := v_student.level;
            v_status := 'verified';
        ELSE
            IF EXISTS (
                SELECT 1 FROM students
                WHERE status = 'active'
                  AND lower(btrim(first_name)) = lower(v_first_name)
                  AND lower(btrim(last_name)) = lower(v_last_name)
            ) THEN
                RETURN jsonb_build_object('success', false, 'code', 'STUDENT_ID_REQUIRED', 'message', 'พบข้อมูลในทะเบียนแล้ว กรุณาสมัครด้วยรหัสนักเรียนจริง');
            END IF;

            IF v_student_id !~ '^0[0-9]{9}$' AND v_student_id !~* '^TMP-[A-Z0-9]{6,32}$' THEN
                RETURN jsonb_build_object('success', false, 'code', 'INVALID_CONTACT', 'message', 'นักเรียนที่ยังไม่มีรหัสให้ใช้เบอร์โทรศัพท์ผู้ปกครอง 10 หลัก หรือรหัสสมัครรูปแบบ TMP-XXXXXX ระบบไม่รับเลขบัตรประชาชน');
            END IF;
            IF v_student_id ~* '^TMP-' THEN
                v_student_id := upper(v_student_id);
            END IF;

            SELECT secret INTO v_phone_secret FROM private.registration_secrets WHERE name = 'pending_phone_hmac';
            v_pending_contact_hash := encode(hmac(
                convert_to(v_student_id || ':' || lower(v_first_name) || ':' || lower(v_last_name) || ':' || lower(v_level), 'UTF8'),
                v_phone_secret,
                'sha256'
            ), 'hex');
            v_pending_contact_hint := right(v_student_id, 4);
            v_student_id := NULL;
        END IF;
    ELSIF EXISTS (
        SELECT 1 FROM students
        WHERE status = 'active'
          AND lower(btrim(first_name)) = lower(v_first_name)
          AND lower(btrim(last_name)) = lower(v_last_name)
    ) THEN
        RETURN jsonb_build_object('success', false, 'code', 'STUDENT_ID_REQUIRED', 'message', 'พบข้อมูลในทะเบียนแล้ว กรุณาสมัครด้วยรหัสนักเรียนจริง');
    ELSIF v_student_id IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'STUDENT_NOT_FOUND', 'message', 'ไม่พบรหัสนักเรียน กรุณาใช้เบอร์ผู้ปกครองหรือรหัสสมัคร TMP-XXXXXX');
    ELSE
        RETURN jsonb_build_object('success', false, 'code', 'CONTACT_PHONE_REQUIRED', 'message', 'นักเรียนที่ยังไม่มีรหัสให้ใช้เบอร์โทรศัพท์ผู้ปกครอง 10 หลัก');
    END IF;

    BEGIN
        INSERT INTO registrations (
            club_id, student_id, pending_contact_hash, pending_contact_hint, request_key,
            prefix, first_name, last_name, level,
            registration_status, academic_year, semester
        )
        VALUES (
            v_club.id, v_student_id, v_pending_contact_hash, v_pending_contact_hint, p_request_key,
            v_prefix, v_first_name,
            v_last_name, v_level, v_status, v_year, v_semester
        )
        RETURNING * INTO v_registration;
    EXCEPTION WHEN unique_violation THEN
        SELECT * INTO v_registration FROM registrations WHERE request_key = p_request_key;
        IF FOUND THEN
            RETURN jsonb_build_object(
                'success', true,
                'status', v_registration.registration_status,
                'registration_id', v_registration.id,
                'registration_token', v_registration.registration_token,
                'message', 'คำขอนี้ถูกบันทึกแล้ว'
            );
        END IF;
        RETURN jsonb_build_object('success', false, 'code', 'ALREADY_REGISTERED', 'message', 'นักเรียนคนนี้ลงทะเบียนในเทอมนี้แล้ว');
    END;

    UPDATE clubs
    SET enrolled_count = enrolled_count + 1
    WHERE id = v_club.id;

    INSERT INTO audit_logs (student_id, student_name, action, club_name, ip_address, user_agent, details)
    VALUES (
        v_student_id,
        concat_ws('', v_prefix, v_first_name, ' ', v_last_name),
        CASE WHEN v_status = 'verified' THEN 'REGISTER_SUCCESS' ELSE 'REGISTER_PENDING' END,
        v_club.name,
        left(COALESCE(p_ip_address, 'Unknown IP'), 128),
        left(COALESCE(p_user_agent, 'Unknown Device'), 500),
        'term=' || v_semester || '/' || v_year || '; status=' || v_status
    );

    RETURN jsonb_build_object(
        'success', true,
        'status', v_status,
        'registration_id', v_registration.id,
        'registration_token', v_registration.registration_token,
        'message', 'ลงทะเบียนเรียนชุมนุม "' || v_club.name || '" สำเร็จแล้ว'
    );
END;
$$;

REVOKE ALL ON FUNCTION register_student_atomic(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION register_student_atomic(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID) TO anon, authenticated;

CREATE OR REPLACE FUNCTION admin_approve_registration(
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
    v_year TEXT;
    v_semester TEXT;
BEGIN
    IF NOT is_admin() THEN
        RETURN jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'ไม่มีสิทธิ์ผู้ดูแลระบบ');
    END IF;

    SELECT value->>'academic_year', value->>'semester'
    INTO v_year, v_semester FROM settings WHERE key = 'school_config';

    SELECT r.*, c.name AS club_name
    INTO v_reg
    FROM registrations r JOIN clubs c ON c.id = r.club_id
    WHERE r.id = p_registration_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'ไม่พบรายการสมัคร');
    END IF;

    SELECT student_id, prefix, first_name, last_name, level
    INTO v_student FROM students
    WHERE student_id = NULLIF(btrim(p_student_id), '') AND status = 'active';
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'STUDENT_NOT_FOUND', 'message', 'ไม่พบรหัสนักเรียนที่ยังใช้งาน');
    END IF;

    IF EXISTS (
        SELECT 1 FROM registrations
        WHERE student_id = v_student.student_id
          AND academic_year = v_year AND semester = v_semester AND id <> v_reg.id
    ) THEN
        RETURN jsonb_build_object('success', false, 'code', 'ALREADY_REGISTERED', 'message', 'รหัสนักเรียนนี้มีรายการสมัครในเทอมนี้แล้ว');
    END IF;

    UPDATE registrations
    SET student_id = v_student.student_id,
        pending_contact_hash = NULL,
        pending_contact_hint = NULL,
        prefix = v_student.prefix,
        first_name = v_student.first_name,
        last_name = v_student.last_name,
        level = v_student.level,
        registration_status = 'verified'
    WHERE id = v_reg.id;

    INSERT INTO audit_logs (student_id, student_name, action, club_name, ip_address, user_agent, details)
    VALUES (v_student.student_id, concat_ws('', v_student.prefix, v_student.first_name, ' ', v_student.last_name),
            'PENDING_APPROVED', v_reg.club_name, left(COALESCE(p_ip_address, 'Unknown IP'), 128),
            left(COALESCE(p_user_agent, 'Unknown Device'), 500), 'registration_id=' || v_reg.id);

    RETURN jsonb_build_object('success', true, 'registration_id', v_reg.id);
END;
$$;

CREATE OR REPLACE FUNCTION admin_delete_registration(
    p_registration_id UUID,
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
    v_year TEXT;
    v_semester TEXT;
    v_name TEXT;
BEGIN
    IF NOT is_admin() THEN
        RETURN jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'ไม่มีสิทธิ์ผู้ดูแลระบบ');
    END IF;

    SELECT value->>'academic_year', value->>'semester'
    INTO v_year, v_semester FROM settings WHERE key = 'school_config';

    SELECT r.*, c.name AS club_name
    INTO v_reg
    FROM registrations r JOIN clubs c ON c.id = r.club_id
    WHERE r.id = p_registration_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'ไม่พบรายการสมัคร');
    END IF;

    v_name := concat_ws('', v_reg.prefix, v_reg.first_name, ' ', v_reg.last_name);
    DELETE FROM registrations WHERE id = v_reg.id;

    IF v_reg.academic_year = v_year AND v_reg.semester = v_semester THEN
        UPDATE clubs c
        SET enrolled_count = (
            SELECT COUNT(*) FROM registrations r
            WHERE r.club_id = c.id AND r.academic_year = v_year AND r.semester = v_semester
        )
        WHERE c.id = v_reg.club_id;
    END IF;

    INSERT INTO audit_logs (student_id, student_name, action, club_name, ip_address, user_agent, details)
    VALUES (v_reg.student_id, v_name,
            CASE WHEN v_reg.registration_status = 'pending' THEN 'PENDING_REJECTED' ELSE 'REGISTRATION_DELETED' END,
            v_reg.club_name, left(COALESCE(p_ip_address, 'Unknown IP'), 128),
            left(COALESCE(p_user_agent, 'Unknown Device'), 500), 'registration_id=' || v_reg.id);

    RETURN jsonb_build_object('success', true, 'club_id', v_reg.club_id);
END;
$$;

CREATE OR REPLACE FUNCTION admin_upsert_registration(
    p_registration_id UUID,
    p_club_id UUID,
    p_student_id TEXT,
    p_prefix TEXT,
    p_first_name TEXT,
    p_last_name TEXT,
    p_level TEXT,
    p_registration_status TEXT,
    p_allow_over_capacity BOOLEAN DEFAULT false,
    p_ip_address TEXT DEFAULT NULL,
    p_user_agent TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_existing RECORD;
    v_club RECORD;
    v_year TEXT;
    v_semester TEXT;
    v_id UUID := p_registration_id;
    v_old_club_id UUID;
    v_status TEXT := CASE WHEN p_registration_status = 'verified' THEN 'verified' ELSE 'pending' END;
BEGIN
    IF NOT is_admin() THEN
        RETURN jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'ไม่มีสิทธิ์ผู้ดูแลระบบ');
    END IF;
    IF p_club_id IS NULL OR NULLIF(btrim(p_first_name), '') IS NULL
       OR NULLIF(btrim(p_last_name), '') IS NULL OR NULLIF(btrim(p_level), '') IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'ข้อมูลไม่ครบถ้วน');
    END IF;

    SELECT value->>'academic_year', value->>'semester'
    INTO v_year, v_semester FROM settings WHERE key = 'school_config';
    SELECT id, name, capacity, enrolled_count INTO v_club FROM clubs WHERE id = p_club_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'CLUB_NOT_FOUND', 'message', 'ไม่พบชุมนุม');
    END IF;

    IF v_id IS NULL THEN
        IF v_club.enrolled_count >= v_club.capacity AND NOT p_allow_over_capacity THEN
            RETURN jsonb_build_object('success', false, 'code', 'CLUB_FULL', 'message', 'ชุมนุมเต็มโควตาแล้ว');
        END IF;
        BEGIN
            INSERT INTO registrations (club_id, student_id, prefix, first_name, last_name, level,
                                       registration_status, academic_year, semester)
            VALUES (p_club_id, NULLIF(btrim(p_student_id), ''), NULLIF(btrim(p_prefix), ''),
                    btrim(p_first_name), btrim(p_last_name), btrim(p_level), v_status, v_year, v_semester)
            RETURNING id INTO v_id;
        EXCEPTION WHEN unique_violation THEN
            RETURN jsonb_build_object('success', false, 'code', 'ALREADY_REGISTERED', 'message', 'นักเรียนมีรายการสมัครซ้ำ');
        END;
    ELSE
        SELECT * INTO v_existing FROM registrations WHERE id = v_id FOR UPDATE;
        IF NOT FOUND THEN
            RETURN jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'ไม่พบรายการสมัคร');
        END IF;
        v_old_club_id := v_existing.club_id;
        IF v_old_club_id IS DISTINCT FROM p_club_id
           AND v_club.enrolled_count >= v_club.capacity
           AND NOT p_allow_over_capacity THEN
            RETURN jsonb_build_object('success', false, 'code', 'CLUB_FULL', 'message', 'ชุมนุมเต็มโควตาแล้ว');
        END IF;
        UPDATE registrations
        SET club_id = p_club_id, student_id = NULLIF(btrim(p_student_id), ''),
            prefix = NULLIF(btrim(p_prefix), ''), first_name = btrim(p_first_name),
            last_name = btrim(p_last_name), level = btrim(p_level), registration_status = v_status
        WHERE id = v_id;
    END IF;

    UPDATE clubs c
    SET enrolled_count = (
        SELECT COUNT(*) FROM registrations r
        WHERE r.club_id = c.id AND r.academic_year = v_year AND r.semester = v_semester
    )
    WHERE c.id IN (p_club_id, v_old_club_id);

    INSERT INTO audit_logs (student_id, student_name, action, club_name, ip_address, user_agent, details)
    VALUES (NULLIF(btrim(p_student_id), ''), concat_ws('', NULLIF(btrim(p_prefix), ''), btrim(p_first_name), ' ', btrim(p_last_name)),
            CASE WHEN p_registration_id IS NULL THEN 'REGISTER_SUCCESS' ELSE 'REGISTRATION_UPDATED' END,
            v_club.name, left(COALESCE(p_ip_address, 'Unknown IP'), 128),
            left(COALESCE(p_user_agent, 'Unknown Device'), 500), 'registration_id=' || v_id);

    RETURN jsonb_build_object('success', true, 'registration_id', v_id);
END;
$$;

REVOKE ALL ON FUNCTION admin_approve_registration(UUID, TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin_delete_registration(UUID, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin_upsert_registration(UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin_approve_registration(UUID, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION admin_delete_registration(UUID, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION admin_upsert_registration(UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN, TEXT, TEXT) TO authenticated;

-- Replace the bootstrap policies. Public clients can read clubs and call the
-- small public RPCs; all student/registration/audit data is admin-only.
DO $$
DECLARE
    p RECORD;
BEGIN
    FOR p IN
        SELECT policyname, tablename
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename IN ('settings', 'clubs', 'students', 'registrations', 'audit_logs', 'admin_users')
    LOOP
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', p.policyname, p.tablename);
    END LOOP;
END;
$$;

REVOKE ALL ON settings, students, registrations, audit_logs, admin_users FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON clubs FROM anon;
GRANT SELECT ON clubs TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON settings, students, registrations, audit_logs, admin_users TO authenticated;

CREATE POLICY settings_admin_all ON settings FOR ALL TO authenticated USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY clubs_public_read ON clubs FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY clubs_admin_write ON clubs FOR INSERT TO authenticated WITH CHECK (is_admin());
CREATE POLICY clubs_admin_update ON clubs FOR UPDATE TO authenticated USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY clubs_admin_delete ON clubs FOR DELETE TO authenticated USING (is_admin());
CREATE POLICY students_admin_all ON students FOR ALL TO authenticated USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY registrations_admin_all ON registrations FOR ALL TO authenticated USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY audit_admin_all ON audit_logs FOR ALL TO authenticated USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY admin_users_self_read ON admin_users FOR SELECT TO authenticated USING (user_id = auth.uid() OR is_admin());

-- Remove the old public backdoors. Existing admin utilities can be re-enabled
-- for authenticated admins after their callers are migrated to Auth.
REVOKE ALL ON FUNCTION decrement_club_seats(UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION bulk_register_atomic(JSONB, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION promote_all_students(TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION start_new_term(TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION anonymize_graduated_students(INT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION delete_graduated_student(UUID, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION list_archived_terms() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION rollback_to_term(TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION admin_bulk_register_atomic(p_rows JSONB, p_ip_address TEXT DEFAULT NULL, p_user_agent TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT is_admin() THEN
        RETURN jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'ไม่มีสิทธิ์ผู้ดูแลระบบ');
    END IF;
    RETURN public.bulk_register_atomic(p_rows, p_ip_address, p_user_agent);
END;
$$;

CREATE OR REPLACE FUNCTION admin_promote_all_students(p_ip_address TEXT DEFAULT NULL, p_user_agent TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT is_admin() THEN
        RETURN jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'ไม่มีสิทธิ์ผู้ดูแลระบบ');
    END IF;
    RETURN public.promote_all_students(p_ip_address, p_user_agent);
END;
$$;

CREATE OR REPLACE FUNCTION admin_start_new_term(p_academic_year TEXT, p_semester TEXT, p_ip_address TEXT DEFAULT NULL, p_user_agent TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT is_admin() THEN
        RETURN jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'ไม่มีสิทธิ์ผู้ดูแลระบบ');
    END IF;
    RETURN public.start_new_term(p_academic_year, p_semester, p_ip_address, p_user_agent);
END;
$$;

CREATE OR REPLACE FUNCTION admin_list_archived_terms()
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT is_admin() THEN
        RETURN jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'ไม่มีสิทธิ์ผู้ดูแลระบบ');
    END IF;
    RETURN public.list_archived_terms();
END;
$$;

CREATE OR REPLACE FUNCTION admin_anonymize_graduated_students(p_years_old INT DEFAULT 5, p_ip_address TEXT DEFAULT NULL, p_user_agent TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT is_admin() THEN
        RETURN jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'ไม่มีสิทธิ์ผู้ดูแลระบบ');
    END IF;
    RETURN public.anonymize_graduated_students(p_years_old, p_ip_address, p_user_agent);
END;
$$;

CREATE OR REPLACE FUNCTION admin_delete_graduated_student(p_student_pk UUID, p_ip_address TEXT DEFAULT NULL, p_user_agent TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT is_admin() THEN
        RETURN jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'ไม่มีสิทธิ์ผู้ดูแลระบบ');
    END IF;
    RETURN public.delete_graduated_student(p_student_pk, p_ip_address, p_user_agent);
END;
$$;

REVOKE ALL ON FUNCTION admin_bulk_register_atomic(JSONB, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin_promote_all_students(TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin_start_new_term(TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin_list_archived_terms() FROM PUBLIC;
REVOKE ALL ON FUNCTION admin_anonymize_graduated_students(INT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin_delete_graduated_student(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin_bulk_register_atomic(JSONB, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION admin_promote_all_students(TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION admin_start_new_term(TEXT, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION admin_list_archived_terms() TO authenticated;
GRANT EXECUTE ON FUNCTION admin_anonymize_graduated_students(INT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION admin_delete_graduated_student(UUID, TEXT, TEXT) TO authenticated;

-- Repair legacy functions that referenced columns absent from the bootstrap schema.
CREATE OR REPLACE FUNCTION rollback_to_term(
    p_academic_year TEXT,
    p_semester TEXT,
    p_ip_address TEXT DEFAULT NULL,
    p_user_agent TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_old_config JSONB;
    v_old_year TEXT;
    v_old_sem TEXT;
    v_reg_count INT;
    v_clubs_updated INT;
BEGIN
    IF NOT is_admin() THEN
        RETURN jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'ไม่มีสิทธิ์ผู้ดูแลระบบ');
    END IF;
    IF NULLIF(btrim(p_academic_year), '') IS NULL OR NULLIF(btrim(p_semester), '') IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'กรุณาระบุปีการศึกษาและภาคเรียน');
    END IF;
    SELECT value INTO v_old_config FROM settings WHERE key = 'school_config' FOR UPDATE;
    v_old_year := COALESCE(v_old_config->>'academic_year', '');
    v_old_sem := COALESCE(v_old_config->>'semester', '');
    IF v_old_year = btrim(p_academic_year) AND v_old_sem = btrim(p_semester) THEN
        RETURN jsonb_build_object('success', false, 'message', 'ระบบอยู่ที่เทอมนี้อยู่แล้ว');
    END IF;
    SELECT COUNT(*) INTO v_reg_count FROM registrations
    WHERE academic_year = btrim(p_academic_year) AND semester = btrim(p_semester);
    IF v_reg_count = 0 THEN
        RETURN jsonb_build_object('success', false, 'message', 'ไม่พบข้อมูลการสมัครของเทอมที่เลือก');
    END IF;
    UPDATE settings
    SET value = value || jsonb_build_object('academic_year', btrim(p_academic_year), 'semester', btrim(p_semester)),
        updated_at = now()
    WHERE key = 'school_config';
    UPDATE clubs c
    SET enrolled_count = (
        SELECT COUNT(*) FROM registrations r
        WHERE r.club_id = c.id AND r.academic_year = btrim(p_academic_year) AND r.semester = btrim(p_semester)
    );
    GET DIAGNOSTICS v_clubs_updated = ROW_COUNT;
    INSERT INTO audit_logs (action, ip_address, user_agent, details)
    VALUES ('ROLLBACK_TO_TERM', left(COALESCE(p_ip_address, 'Unknown IP'), 128),
            left(COALESCE(p_user_agent, 'Unknown Device'), 500),
            'from=' || v_old_sem || '/' || v_old_year || '; to=' || p_semester || '/' || p_academic_year);
    RETURN jsonb_build_object('success', true, 'registrations_restored', v_reg_count, 'clubs_updated', v_clubs_updated);
END;
$$;
REVOKE ALL ON FUNCTION rollback_to_term(TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rollback_to_term(TEXT, TEXT, TEXT, TEXT) TO authenticated;

COMMIT;
