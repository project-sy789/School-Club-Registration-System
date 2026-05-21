-- =====================================================================
-- 🚀 MIGRATION V2 — เพิ่มระบบเลื่อนชั้น + แยกเทอม/ปีการศึกษา
-- =====================================================================
-- รันสคริปต์นี้บน Supabase SQL Editor *เพียงครั้งเดียว* บนฐานข้อมูลที่ติดตั้ง
-- setup_database.sql เวอร์ชันเดิมไปแล้ว เพื่ออัปเกรดเป็นเวอร์ชัน 2
-- ปลอดภัย: ใช้ IF NOT EXISTS / IF EXISTS ทั้งหมด รันซ้ำได้ไม่เสีย
-- =====================================================================

-- ────────────────────────────────────────────────────────────────────
-- 1. STUDENTS: เพิ่มคอลัมน์ status (active/graduated) + graduated_year
-- ────────────────────────────────────────────────────────────────────
ALTER TABLE students
    ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'graduated'));

ALTER TABLE students
    ADD COLUMN IF NOT EXISTS graduated_year TEXT;

-- ────────────────────────────────────────────────────────────────────
-- 2. REGISTRATIONS: เพิ่ม academic_year + semester (stamp ตอนสมัคร)
-- ────────────────────────────────────────────────────────────────────
ALTER TABLE registrations
    ADD COLUMN IF NOT EXISTS academic_year TEXT NOT NULL DEFAULT '2569';

ALTER TABLE registrations
    ADD COLUMN IF NOT EXISTS semester TEXT NOT NULL DEFAULT '1';

-- เปลี่ยน UNIQUE constraint จาก (first_name, last_name) เป็น
-- (first_name, last_name, academic_year, semester) เพื่อให้คนเดิมลงทะเบียนใหม่ได้ในเทอมถัดไป
ALTER TABLE registrations
    DROP CONSTRAINT IF EXISTS unique_student_name;

ALTER TABLE registrations
    DROP CONSTRAINT IF EXISTS unique_student_name_per_term;

ALTER TABLE registrations
    ADD CONSTRAINT unique_student_name_per_term
    UNIQUE (first_name, last_name, academic_year, semester);

-- index สำหรับ filter ตามเทอม (เร่งความเร็ว query ของหน้าหลัก)
CREATE INDEX IF NOT EXISTS idx_registrations_term
    ON registrations(academic_year, semester);

-- ────────────────────────────────────────────────────────────────────
-- 3. SCHOOL_CONFIG: แยก academic_year / semester ออกจากกัน
-- เดิม semester เก็บเป็น "1/2569" ตอนนี้แยกเป็น semester="1" + academic_year="2569"
-- ถ้าค่าเดิมเป็นรูปแบบ "<sem>/<year>" ก็แยกอัตโนมัติ
-- ────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_cfg JSONB;
    v_old_sem TEXT;
    v_new_sem TEXT;
    v_new_year TEXT;
BEGIN
    SELECT value INTO v_cfg FROM settings WHERE key = 'school_config';
    IF v_cfg IS NULL THEN RETURN; END IF;

    v_old_sem := v_cfg->>'semester';

    -- แยกค่าถ้ายังไม่มี academic_year
    IF (v_cfg ? 'academic_year') = FALSE THEN
        IF v_old_sem ~ '^\d+\s*/\s*\d+$' THEN
            v_new_sem := TRIM(SPLIT_PART(v_old_sem, '/', 1));
            v_new_year := TRIM(SPLIT_PART(v_old_sem, '/', 2));
        ELSE
            v_new_sem := COALESCE(v_old_sem, '1');
            v_new_year := '2569';
        END IF;

        v_cfg := v_cfg
            || jsonb_build_object('semester', v_new_sem)
            || jsonb_build_object('academic_year', v_new_year);

        UPDATE settings SET value = v_cfg WHERE key = 'school_config';
    END IF;
END $$;

-- ────────────────────────────────────────────────────────────────────
-- 4. STORED PROC: register_student_atomic — stamp year+semester
-- ────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS register_student_atomic(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS register_student_atomic(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT);

CREATE OR REPLACE FUNCTION register_student_atomic(
    p_club_id UUID,
    p_student_id TEXT,
    p_prefix TEXT,
    p_first_name TEXT,
    p_last_name TEXT,
    p_level TEXT,
    p_ip_address TEXT,
    p_user_agent TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_club_name TEXT;
    v_capacity INTEGER;
    v_enrolled INTEGER;
    v_is_active BOOLEAN;
    v_start_time TIMESTAMPTZ;
    v_end_time TIMESTAMPTZ;
    v_student_exists BOOLEAN;
    v_already_registered BOOLEAN;
    v_status TEXT;
    v_registered_id UUID;
    v_student_id_cleaned TEXT;
    v_current_year TEXT;
    v_current_sem TEXT;
BEGIN
    v_student_id_cleaned := NULLIF(TRIM(p_student_id), '');

    -- โหลดเทอมปัจจุบันจาก school_config
    SELECT
        COALESCE(value->>'academic_year', '2569'),
        COALESCE(value->>'semester', '1')
    INTO v_current_year, v_current_sem
    FROM settings
    WHERE key = 'school_config';

    -- 1. ตรวจสอบช่วงเวลาเปิด-ปิดระบบ
    SELECT
        (value->>'is_active')::BOOLEAN,
        (value->>'start_time')::TIMESTAMPTZ,
        (value->>'end_time')::TIMESTAMPTZ
    INTO v_is_active, v_start_time, v_end_time
    FROM settings WHERE key = 'registration_period';

    IF NOT v_is_active THEN
        RETURN jsonb_build_object('success', false, 'message', 'ขณะนี้ระบบปิดรับสมัครลงทะเบียนชุมนุมชั่วคราว');
    END IF;
    IF now() < v_start_time THEN
        RETURN jsonb_build_object('success', false, 'message', 'ยังไม่ถึงเวลาเปิดรับสมัครชุมนุม (จะเปิดในวันที่ ' || to_char(v_start_time AT TIME ZONE 'Asia/Bangkok', 'DD/MM/YYYY HH24:MI') || ' น.)');
    END IF;
    IF now() > v_end_time THEN
        RETURN jsonb_build_object('success', false, 'message', 'ระบบหมดเวลาเปิดรับสมัครชุมนุมเรียบร้อยแล้ว');
    END IF;

    -- 2. ป้องกันลงทะเบียนซ้ำ — เฉพาะเทอม+ปีปัจจุบัน
    IF v_student_id_cleaned IS NOT NULL THEN
        SELECT EXISTS (
            SELECT 1 FROM registrations
            WHERE student_id = v_student_id_cleaned
              AND academic_year = v_current_year
              AND semester = v_current_sem
        ) INTO v_already_registered;

        IF v_already_registered THEN
            RETURN jsonb_build_object('success', false, 'message', 'รหัสนักเรียน ' || v_student_id_cleaned || ' ได้ลงทะเบียนชุมนุมในเทอมนี้ไปแล้ว');
        END IF;
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM registrations
        WHERE TRIM(first_name) = TRIM(p_first_name)
          AND TRIM(last_name) = TRIM(p_last_name)
          AND academic_year = v_current_year
          AND semester = v_current_sem
          AND (
              student_id IS NULL
              OR v_student_id_cleaned IS NULL
              OR student_id = v_student_id_cleaned
          )
    ) INTO v_already_registered;

    IF v_already_registered THEN
        RETURN jsonb_build_object('success', false, 'message', 'นักเรียน ' || p_first_name || ' ' || p_last_name || ' ได้ลงทะเบียนชุมนุมในเทอมนี้ไปแล้ว');
    END IF;

    -- 3. โควตา + Row Lock
    SELECT name, capacity, enrolled_count
    INTO v_club_name, v_capacity, v_enrolled
    FROM clubs WHERE id = p_club_id FOR UPDATE;

    IF v_capacity IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'ไม่พบชุมนุมที่คุณเลือกในระบบ');
    END IF;
    IF v_enrolled >= v_capacity THEN
        RETURN jsonb_build_object('success', false, 'message', 'ขออภัย ชุมนุม "' || v_club_name || '" เต็มโควตาแล้ว');
    END IF;

    -- 4. verified vs pending — เฉพาะนักเรียน status='active' เท่านั้น
    IF v_student_id_cleaned IS NOT NULL THEN
        SELECT EXISTS (
            SELECT 1 FROM students
            WHERE student_id = v_student_id_cleaned
              AND status = 'active'
        ) INTO v_student_exists;
    ELSE
        v_student_exists := FALSE;
    END IF;
    v_status := CASE WHEN v_student_exists THEN 'verified' ELSE 'pending' END;

    -- 5. บันทึกลง registrations + stamp ปี/เทอม
    INSERT INTO registrations (club_id, student_id, prefix, first_name, last_name, level, registration_status, academic_year, semester)
    VALUES (p_club_id, v_student_id_cleaned, TRIM(p_prefix), TRIM(p_first_name), TRIM(p_last_name), TRIM(p_level), v_status, v_current_year, v_current_sem)
    RETURNING id INTO v_registered_id;

    UPDATE clubs SET enrolled_count = enrolled_count + 1 WHERE id = p_club_id;

    INSERT INTO audit_logs (student_id, student_name, action, club_name, ip_address, user_agent, details)
    VALUES (
        v_student_id_cleaned,
        COALESCE(TRIM(p_prefix), '') || TRIM(p_first_name) || ' ' || TRIM(p_last_name),
        CASE WHEN v_status = 'verified' THEN 'REGISTER_SUCCESS' ELSE 'REGISTER_PENDING' END,
        v_club_name,
        COALESCE(p_ip_address, 'Unknown IP'),
        COALESCE(p_user_agent, 'Unknown Device'),
        'ลงทะเบียนเทอม ' || v_current_sem || '/' || v_current_year || ' (ระดับห้อง: ' || p_level || ', สถานะ: ' || v_status || ')'
    );

    RETURN jsonb_build_object(
        'success', true,
        'message', 'ลงทะเบียนเรียนชุมนุม "' || v_club_name || '" สำเร็จแล้ว',
        'status', v_status,
        'registration_id', v_registered_id
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'message', 'เกิดข้อผิดพลาด: ' || SQLERRM);
END;
$$;

-- ────────────────────────────────────────────────────────────────────
-- 5. STORED PROC: bulk_register_atomic — stamp year+semester
-- ────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION bulk_register_atomic(
    p_rows JSONB,
    p_ip_address TEXT DEFAULT NULL,
    p_user_agent TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_row JSONB;
    v_club_id UUID;
    v_club_name TEXT;
    v_capacity INTEGER;
    v_enrolled INTEGER;
    v_input_club_name TEXT;
    v_student_id_cleaned TEXT;
    v_student_exists BOOLEAN;
    v_first_name TEXT;
    v_last_name TEXT;
    v_prefix TEXT;
    v_level TEXT;
    v_status TEXT;
    v_inserted_count INT := 0;
    v_skipped JSONB := '[]'::jsonb;
    v_failed JSONB := '[]'::jsonb;
    v_current_year TEXT;
    v_current_sem TEXT;
BEGIN
    SELECT
        COALESCE(value->>'academic_year', '2569'),
        COALESCE(value->>'semester', '1')
    INTO v_current_year, v_current_sem
    FROM settings WHERE key = 'school_config';

    FOR v_row IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
        BEGIN
            v_student_id_cleaned := NULLIF(TRIM(COALESCE(v_row->>'student_id', '')), '');
            v_prefix := NULLIF(TRIM(COALESCE(v_row->>'prefix', '')), '');
            v_first_name := TRIM(COALESCE(v_row->>'first_name', ''));
            v_last_name := TRIM(COALESCE(v_row->>'last_name', ''));
            v_level := TRIM(COALESCE(v_row->>'level', ''));
            v_input_club_name := TRIM(COALESCE(v_row->>'club_name', ''));

            IF v_first_name = '' OR v_last_name = '' OR v_input_club_name = '' OR v_level = '' THEN
                v_failed := v_failed || jsonb_build_object('row', v_row, 'reason', 'ข้อมูลไม่ครบ');
                CONTINUE;
            END IF;

            SELECT id, name, capacity, enrolled_count
            INTO v_club_id, v_club_name, v_capacity, v_enrolled
            FROM clubs WHERE LOWER(TRIM(name)) = LOWER(v_input_club_name)
            LIMIT 1 FOR UPDATE;

            IF v_club_id IS NULL THEN
                v_failed := v_failed || jsonb_build_object('row', v_row, 'reason', 'ไม่พบชุมนุมชื่อ "' || v_input_club_name || '"');
                CONTINUE;
            END IF;

            IF v_enrolled >= v_capacity THEN
                v_skipped := v_skipped || jsonb_build_object('row', v_row, 'reason', 'ชุมนุม "' || v_club_name || '" เต็มโควตา');
                CONTINUE;
            END IF;

            IF v_student_id_cleaned IS NOT NULL THEN
                IF EXISTS (SELECT 1 FROM registrations
                           WHERE student_id = v_student_id_cleaned
                             AND academic_year = v_current_year
                             AND semester = v_current_sem) THEN
                    v_skipped := v_skipped || jsonb_build_object('row', v_row, 'reason', 'รหัส ' || v_student_id_cleaned || ' ลงทะเบียนเทอมนี้ไปแล้ว');
                    CONTINUE;
                END IF;
            END IF;

            IF EXISTS (
                SELECT 1 FROM registrations
                WHERE TRIM(first_name) = v_first_name
                  AND TRIM(last_name) = v_last_name
                  AND academic_year = v_current_year
                  AND semester = v_current_sem
            ) THEN
                v_skipped := v_skipped || jsonb_build_object('row', v_row, 'reason', v_first_name || ' ' || v_last_name || ' ลงทะเบียนเทอมนี้ไปแล้ว');
                CONTINUE;
            END IF;

            IF v_student_id_cleaned IS NOT NULL THEN
                SELECT EXISTS (SELECT 1 FROM students
                               WHERE student_id = v_student_id_cleaned
                                 AND status = 'active') INTO v_student_exists;
            ELSE
                v_student_exists := FALSE;
            END IF;
            v_status := CASE WHEN v_student_exists THEN 'verified' ELSE 'pending' END;

            INSERT INTO registrations (club_id, student_id, prefix, first_name, last_name, level, registration_status, academic_year, semester)
            VALUES (v_club_id, v_student_id_cleaned, v_prefix, v_first_name, v_last_name, v_level, v_status, v_current_year, v_current_sem);

            UPDATE clubs SET enrolled_count = enrolled_count + 1 WHERE id = v_club_id;

            v_inserted_count := v_inserted_count + 1;

        EXCEPTION WHEN OTHERS THEN
            v_failed := v_failed || jsonb_build_object('row', v_row, 'reason', SQLERRM);
        END;
    END LOOP;

    INSERT INTO audit_logs (action, ip_address, user_agent, details)
    VALUES (
        'BULK_REGISTRATION_IMPORT',
        COALESCE(p_ip_address, 'Unknown IP'),
        COALESCE(p_user_agent, 'Unknown Device'),
        'Bulk import เทอม ' || v_current_sem || '/' || v_current_year || ': สำเร็จ ' || v_inserted_count
            || ', ข้าม ' || jsonb_array_length(v_skipped)
            || ', ผิดพลาด ' || jsonb_array_length(v_failed)
    );

    RETURN jsonb_build_object(
        'success', true,
        'inserted', v_inserted_count,
        'skipped', v_skipped,
        'failed', v_failed
    );
END;
$$;

-- ────────────────────────────────────────────────────────────────────
-- 6. STORED PROC: promote_all_students() — เลื่อนชั้นทั้งโรงเรียน
-- ────────────────────────────────────────────────────────────────────
-- Logic: ม.6/x → graduated, ม.5/x → ม.6/x, ม.4/x → ม.5/x, ... ม.1/x → ม.2/x
-- รองรับรูปแบบ level เช่น "ม.4/1", "ม.4 / 1", "ม.4-1"
-- ทำงานเฉพาะนักเรียน status='active' เท่านั้น
-- คืน {promoted: N, graduated: N, unchanged: N}
-- ────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION promote_all_students(
    p_ip_address TEXT DEFAULT NULL,
    p_user_agent TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_student RECORD;
    v_grade_num INT;
    v_classroom TEXT;
    v_new_level TEXT;
    v_promoted INT := 0;
    v_graduated INT := 0;
    v_unchanged INT := 0;
    v_current_year TEXT;
BEGIN
    SELECT COALESCE(value->>'academic_year', '2569')
    INTO v_current_year
    FROM settings WHERE key = 'school_config';

    FOR v_student IN
        SELECT student_id, level FROM students WHERE status = 'active'
    LOOP
        -- ดึงเลขชั้น (1-6) จาก "ม.X/Y" หรือ "ม.X" หรือ "ม.X-Y"
        v_grade_num := NULL;
        BEGIN
            v_grade_num := (regexp_match(v_student.level, 'ม\.?\s*([1-6])'))[1]::INT;
        EXCEPTION WHEN OTHERS THEN
            v_grade_num := NULL;
        END;

        -- ห้องเรียน (ส่วนหลัง /)
        v_classroom := NULLIF(TRIM(SPLIT_PART(REPLACE(v_student.level, '-', '/'), '/', 2)), '');

        IF v_grade_num IS NULL THEN
            v_unchanged := v_unchanged + 1;
            CONTINUE;
        END IF;

        IF v_grade_num = 6 THEN
            -- ม.6 → จบการศึกษา
            UPDATE students
            SET status = 'graduated',
                graduated_year = v_current_year
            WHERE student_id = v_student.student_id;
            v_graduated := v_graduated + 1;
        ELSE
            -- เลื่อนขึ้น 1 ชั้น คงห้องเดิมไว้
            v_new_level := 'ม.' || (v_grade_num + 1)::TEXT
                || CASE WHEN v_classroom IS NOT NULL THEN '/' || v_classroom ELSE '' END;
            UPDATE students
            SET level = v_new_level
            WHERE student_id = v_student.student_id;
            v_promoted := v_promoted + 1;
        END IF;
    END LOOP;

    INSERT INTO audit_logs (action, ip_address, user_agent, details)
    VALUES (
        'PROMOTE_ALL_STUDENTS',
        COALESCE(p_ip_address, 'Unknown IP'),
        COALESCE(p_user_agent, 'Unknown Device'),
        'เลื่อนชั้นประจำปี: เลื่อน ' || v_promoted || ' คน, จบการศึกษา ' || v_graduated || ' คน, ข้าม ' || v_unchanged || ' คน (ปี ' || v_current_year || ')'
    );

    RETURN jsonb_build_object(
        'success', true,
        'promoted', v_promoted,
        'graduated', v_graduated,
        'unchanged', v_unchanged
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$;

-- ────────────────────────────────────────────────────────────────────
-- 7. STORED PROC: start_new_term(p_year, p_semester)
-- ขึ้นเทอมใหม่: รีเซ็ต enrolled_count ของทุกชุมนุม + อัปเดต school_config
-- ไม่ลบ registrations เก่า (เก็บเป็นประวัติ filter ด้วย academic_year+semester)
-- ────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION start_new_term(
    p_academic_year TEXT,
    p_semester TEXT,
    p_ip_address TEXT DEFAULT NULL,
    p_user_agent TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_old_year TEXT;
    v_old_sem TEXT;
    v_clubs_reset INT;
BEGIN
    IF NULLIF(TRIM(p_academic_year), '') IS NULL OR NULLIF(TRIM(p_semester), '') IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'กรุณาระบุปีการศึกษาและภาคเรียน');
    END IF;

    SELECT
        COALESCE(value->>'academic_year', '2569'),
        COALESCE(value->>'semester', '1')
    INTO v_old_year, v_old_sem
    FROM settings WHERE key = 'school_config';

    -- กันเริ่มเทอมเดิมซ้ำ
    IF v_old_year = TRIM(p_academic_year) AND v_old_sem = TRIM(p_semester) THEN
        RETURN jsonb_build_object('success', false, 'message', 'เทอม ' || p_semester || '/' || p_academic_year || ' เป็นเทอมปัจจุบันอยู่แล้ว');
    END IF;

    -- รีเซ็ตยอดที่นั่งของทุกชุมนุม
    UPDATE clubs SET enrolled_count = 0;
    GET DIAGNOSTICS v_clubs_reset = ROW_COUNT;

    -- อัปเดต school_config
    UPDATE settings
    SET value = value
        || jsonb_build_object('academic_year', TRIM(p_academic_year))
        || jsonb_build_object('semester', TRIM(p_semester))
    WHERE key = 'school_config';

    INSERT INTO audit_logs (action, ip_address, user_agent, details)
    VALUES (
        'START_NEW_TERM',
        COALESCE(p_ip_address, 'Unknown IP'),
        COALESCE(p_user_agent, 'Unknown Device'),
        'เริ่มเทอมใหม่: ' || v_old_sem || '/' || v_old_year || ' → ' || p_semester || '/' || p_academic_year
            || ' (รีเซ็ตที่นั่ง ' || v_clubs_reset || ' ชุมนุม)'
    );

    RETURN jsonb_build_object(
        'success', true,
        'old_term', v_old_sem || '/' || v_old_year,
        'new_term', TRIM(p_semester) || '/' || TRIM(p_academic_year),
        'clubs_reset', v_clubs_reset
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$;
