-- =====================================================================
-- 🛠️ SUPABASE SETUP DATABASE SCRIPT - SCHOOL CLUB REGISTRATION APP
-- =====================================================================
-- สามารถคัดลอกสคริปต์ทั้งหมดนี้ไปรันในช่อง SQL Editor ของ Supabase ได้ทันที!
-- =====================================================================

-- 1. ล้างตารางเดิมหากเคยมีอยู่ (ย้ายลำดับความสัมพันธ์ตาม Foreign Keys)
DROP TABLE IF EXISTS registrations CASCADE;
DROP TABLE IF EXISTS students CASCADE;
DROP TABLE IF EXISTS clubs CASCADE;
DROP TABLE IF EXISTS settings CASCADE;
DROP TABLE IF EXISTS audit_logs CASCADE;

-- 2. สร้างตารางการตั้งค่าระบบ (Settings)
CREATE TABLE settings (
    key TEXT PRIMARY KEY,
    value JSONB NOT NULL
);

-- บันทึกการตั้งค่าเริ่มต้น (ชื่อโรงเรียน, ช่วงเวลาเปิด-ปิด)
INSERT INTO settings (key, value) VALUES
('school_config', '{
    "school_name": "โรงเรียนมัธยมศึกษารวมวิทยายน",
    "academic_year": "2569",
    "semester": "1",
    "admin_password": "admin-password-1234",
    "logo_base64": null
}'::jsonb),
('registration_period', '{
    "is_active": true,
    "start_time": "2026-05-20T08:30:00",
    "end_time": "2026-05-25T16:30:00"
}'::jsonb);

-- เปิดใช้งาน RLS สำหรับ Settings (เพื่อให้หน้าเว็บอ่านและบันทึกการตั้งค่าระบบได้)
ALTER TABLE settings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Allow public read access to settings" ON settings FOR SELECT USING (true);
CREATE POLICY "Allow public all access to settings" ON settings FOR ALL USING (true);


-- 3. สร้างตารางรายชื่อชุมนุม (Clubs)
CREATE TABLE clubs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    teacher TEXT NOT NULL,
    location TEXT NOT NULL,
    description TEXT,
    grades TEXT[] NOT NULL, -- เก็บในรูปแบบ array เช่น ['ม.4', 'ม.5', 'ม.6']
    capacity INTEGER NOT NULL DEFAULT 40,
    enrolled_count INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- เปิดใช้งาน RLS สำหรับ Clubs (เพื่อให้ทุกคนดึงข้อมูลชุมนุมได้โดยไม่ต้อง Login)
ALTER TABLE clubs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Allow public read access to clubs" ON clubs FOR SELECT USING (true);
CREATE POLICY "Allow public all access to clubs for testing" ON clubs FOR ALL USING (true); -- สำหรับความง่ายในการพัฒนาแบบไร้ Backend Server


-- 4. สร้างตารางรายชื่อนักเรียนที่มีอยู่ในระบบ (Students)
CREATE TABLE students (
    student_id TEXT PRIMARY KEY, -- เลขประจำตัวนักเรียน
    prefix TEXT, -- คำนำหน้าชื่อ เช่น เด็กชาย, นาย, นางสาว
    first_name TEXT NOT NULL,
    last_name TEXT NOT NULL,
    level TEXT NOT NULL, -- เช่น ม.4/1, ม.5/2
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'graduated')),
    graduated_year TEXT
);

-- เปิดใช้งาน RLS สำหรับ Students
ALTER TABLE students ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Allow public read access to students" ON students FOR SELECT USING (true);
CREATE POLICY "Allow public insert/update/delete for admin" ON students FOR ALL USING (true);


-- 5. สร้างตารางการลงทะเบียนนักเรียน (Registrations)
CREATE TABLE registrations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    club_id UUID REFERENCES clubs(id) ON DELETE CASCADE,
    student_id TEXT, -- สามารถเป็น NULL ได้ สำหรับนักเรียนใหม่ที่ไม่มีเลขในระบบ
    prefix TEXT, -- คำนำหน้าชื่อ เช่น เด็กชาย, นาย, นางสาว
    first_name TEXT NOT NULL,
    last_name TEXT NOT NULL,
    level TEXT NOT NULL, -- เช่น ม.4/1
    registration_status TEXT NOT NULL CHECK (registration_status IN ('verified', 'pending')),
    academic_year TEXT NOT NULL DEFAULT '2569',
    semester TEXT NOT NULL DEFAULT '1',
    created_at TIMESTAMPTZ DEFAULT now(),
    -- ห้ามชื่อ-นามสกุลเดียวกันลงทะเบียนซ้ำภายในเทอม/ปีการศึกษาเดียวกัน
    CONSTRAINT unique_student_name_per_term UNIQUE (first_name, last_name, academic_year, semester)
);

CREATE INDEX IF NOT EXISTS idx_registrations_term ON registrations(academic_year, semester);

-- เปิดใช้งาน RLS สำหรับ Registrations
ALTER TABLE registrations ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Allow public read access to registrations" ON registrations FOR SELECT USING (true);
CREATE POLICY "Allow public insert registrations" ON registrations FOR INSERT WITH CHECK (true);
CREATE POLICY "Allow public update/delete for admin" ON registrations FOR ALL USING (true);


-- 6. สร้างตารางบันทึกประวัติความปลอดภัยและการกระทำระบบ (Audit Logs)
CREATE TABLE audit_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    student_id TEXT, -- รหัสนักเรียนที่เกี่ยวข้อง
    student_name TEXT, -- ชื่อนักเรียนที่เกี่ยวข้อง
    action TEXT NOT NULL, -- กิจกรรม (เช่น REGISTER_SUCCESS, REGISTER_PENDING, REGISTRATION_DELETED, PENDING_APPROVED, PENDING_REJECTED)
    club_name TEXT, -- ชื่อชุมนุม
    ip_address TEXT, -- IP ของผู้ใช้งาน
    user_agent TEXT, -- เบราว์เซอร์และอุปกรณ์
    details TEXT, -- รายละเอียดเพิ่มเติม
    created_at TIMESTAMPTZ DEFAULT now()
);

-- เปิดใช้งาน RLS สำหรับ audit_logs
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Allow public insert access to audit_logs" ON audit_logs FOR INSERT WITH CHECK (true);
CREATE POLICY "Allow read access to audit_logs for admin" ON audit_logs FOR SELECT USING (true);


-- =====================================================================
-- ⚡ STORED PROCEDURE: register_student_atomic
-- ฟังก์ชันประมวลผลการสมัครแบบ Atomic เพื่อป้องกัน Race Condition และรองรับโหลดพร้อมกันสูง
-- =====================================================================
DROP FUNCTION IF EXISTS register_student_atomic(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT);

CREATE OR REPLACE FUNCTION register_student_atomic(
    p_club_id UUID,
    p_student_id TEXT,
    p_prefix TEXT, -- พารามิเตอร์ใหม่
    p_first_name TEXT,
    p_last_name TEXT,
    p_level TEXT,
    p_ip_address TEXT,
    p_user_agent TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER -- ให้รันด้วยสิทธิ์สูงสุดเพื่อจัดการอัปเดตและจองที่นั่งได้ถูกต้อง
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

    -- 1. ตรวจสอบการเปิด-ปิดรับสมัครจากระบบ
    SELECT
        (value->>'is_active')::BOOLEAN,
        (value->>'start_time')::TIMESTAMPTZ,
        (value->>'end_time')::TIMESTAMPTZ
    INTO v_is_active, v_start_time, v_end_time
    FROM settings
    WHERE key = 'registration_period';

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

    -- 3. ตรวจสอบโควตาที่นั่ง + Row Lock
    SELECT name, capacity, enrolled_count
    INTO v_club_name, v_capacity, v_enrolled
    FROM clubs
    WHERE id = p_club_id
    FOR UPDATE;

    IF v_capacity IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'ไม่พบชุมนุมที่คุณเลือกในระบบ');
    END IF;

    IF v_enrolled >= v_capacity THEN
        RETURN jsonb_build_object('success', false, 'message', 'ขออภัย ชุมนุม "' || v_club_name || '" เต็มโควตาแล้ว กรุณาเลือกชุมนุมอื่น');
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
    RETURN jsonb_build_object('success', false, 'message', 'เกิดข้อผิดพลาดในการประมวลผล กรุณาลองใหม่อีกครั้ง (' || SQLERRM || ')');
END;
$$;

-- ฟังก์ชันลดจำนวนผู้สมัครในชุมนุมเมื่อผู้ดูแลระบบยกเลิกสิทธิ์จอง (Atomic Decrement)
CREATE OR REPLACE FUNCTION decrement_club_seats(
    p_club_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE clubs
    SET enrolled_count = GREATEST(0, enrolled_count - 1)
    WHERE id = p_club_id;
END;
$$;


-- =====================================================================
-- ⚡ STORED PROCEDURE: bulk_register_atomic
-- ฟังก์ชันนำเข้ารายชื่อลงทะเบียนเรียนชุมนุมแบบ Bulk จากไฟล์ CSV/Excel ของผู้ดูแลระบบ
-- ทำงานใน transaction เดียว ตัดยอด enrolled_count ทีละชุมนุมแบบ Row Lock เคารพโควตา
-- ข้ามแถวที่ซ้ำหรือเต็ม (ไม่ทำให้ batch ทั้งก้อนล้ม) และคืน summary {inserted, skipped, failed}
-- หมายเหตุ: bypass ช่วงเวลาเปิด-ปิดระบบ เพราะเป็นการกระทำของ admin
-- =====================================================================
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

            -- ตรวจสอบความครบถ้วนขั้นต่ำ
            IF v_first_name = '' OR v_last_name = '' OR v_input_club_name = '' OR v_level = '' THEN
                v_failed := v_failed || jsonb_build_object('row', v_row, 'reason', 'ข้อมูลไม่ครบ (ต้องมี first_name, last_name, level, club_name)');
                CONTINUE;
            END IF;

            -- ค้นหาชุมนุมตามชื่อ (case-insensitive, trim) พร้อม Row Lock เพื่อป้องกัน Race
            SELECT id, name, capacity, enrolled_count
            INTO v_club_id, v_club_name, v_capacity, v_enrolled
            FROM clubs
            WHERE LOWER(TRIM(name)) = LOWER(v_input_club_name)
            LIMIT 1
            FOR UPDATE;

            IF v_club_id IS NULL THEN
                v_failed := v_failed || jsonb_build_object('row', v_row, 'reason', 'ไม่พบชุมนุมชื่อ "' || v_input_club_name || '" ในระบบ');
                CONTINUE;
            END IF;

            -- เคารพโควตาที่นั่ง (ถ้าเต็ม → skip + รายงาน)
            IF v_enrolled >= v_capacity THEN
                v_skipped := v_skipped || jsonb_build_object('row', v_row, 'reason', 'ชุมนุม "' || v_club_name || '" เต็มโควตา (' || v_enrolled || '/' || v_capacity || ')');
                CONTINUE;
            END IF;

            -- ป้องกันลงทะเบียนซ้ำด้วยรหัสนักเรียน — เฉพาะเทอม+ปีปัจจุบัน
            IF v_student_id_cleaned IS NOT NULL THEN
                IF EXISTS (SELECT 1 FROM registrations
                           WHERE student_id = v_student_id_cleaned
                             AND academic_year = v_current_year
                             AND semester = v_current_sem) THEN
                    v_skipped := v_skipped || jsonb_build_object('row', v_row, 'reason', 'รหัสนักเรียน ' || v_student_id_cleaned || ' ลงทะเบียนเทอมนี้ไปแล้ว');
                    CONTINUE;
                END IF;
            END IF;

            -- ป้องกันลงทะเบียนซ้ำด้วยชื่อ-นามสกุล — เฉพาะเทอม+ปีปัจจุบัน
            IF EXISTS (
                SELECT 1 FROM registrations
                WHERE TRIM(first_name) = v_first_name
                  AND TRIM(last_name) = v_last_name
                  AND academic_year = v_current_year
                  AND semester = v_current_sem
            ) THEN
                v_skipped := v_skipped || jsonb_build_object('row', v_row, 'reason', 'นักเรียน ' || v_first_name || ' ' || v_last_name || ' ลงทะเบียนเทอมนี้ไปแล้ว');
                CONTINUE;
            END IF;

            -- กำหนดสถานะ: มีในตาราง students (status='active') = verified, ไม่มี = pending
            IF v_student_id_cleaned IS NOT NULL THEN
                SELECT EXISTS (SELECT 1 FROM students
                               WHERE student_id = v_student_id_cleaned
                                 AND status = 'active') INTO v_student_exists;
            ELSE
                v_student_exists := FALSE;
            END IF;
            v_status := CASE WHEN v_student_exists THEN 'verified' ELSE 'pending' END;

            -- Insert ทะเบียนและเพิ่ม enrolled_count
            INSERT INTO registrations (club_id, student_id, prefix, first_name, last_name, level, registration_status, academic_year, semester)
            VALUES (v_club_id, v_student_id_cleaned, v_prefix, v_first_name, v_last_name, v_level, v_status, v_current_year, v_current_sem);

            UPDATE clubs SET enrolled_count = enrolled_count + 1 WHERE id = v_club_id;

            v_inserted_count := v_inserted_count + 1;

        EXCEPTION WHEN OTHERS THEN
            v_failed := v_failed || jsonb_build_object('row', v_row, 'reason', SQLERRM);
        END;
    END LOOP;

    -- บันทึก Audit Log สรุปผลการนำเข้าครั้งนี้
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


-- =====================================================================
-- 🎓 STORED PROC: promote_all_students() — เลื่อนชั้นทั้งโรงเรียน
-- ม.6/x → graduated, ม.5/x → ม.6/x, ... ม.1/x → ม.2/x (status='active' เท่านั้น)
-- =====================================================================
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
        v_grade_num := NULL;
        BEGIN
            v_grade_num := (regexp_match(v_student.level, 'ม\.?\s*([1-6])'))[1]::INT;
        EXCEPTION WHEN OTHERS THEN
            v_grade_num := NULL;
        END;

        v_classroom := NULLIF(TRIM(SPLIT_PART(REPLACE(v_student.level, '-', '/'), '/', 2)), '');

        IF v_grade_num IS NULL THEN
            v_unchanged := v_unchanged + 1;
            CONTINUE;
        END IF;

        IF v_grade_num = 6 THEN
            UPDATE students
            SET status = 'graduated',
                graduated_year = v_current_year
            WHERE student_id = v_student.student_id;
            v_graduated := v_graduated + 1;
        ELSE
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


-- =====================================================================
-- 🆕 STORED PROC: start_new_term(p_year, p_semester)
-- รีเซ็ต enrolled_count ทุกชุมนุม + อัปเดต school_config (ไม่ลบ registrations เก่า)
-- =====================================================================
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

    IF v_old_year = TRIM(p_academic_year) AND v_old_sem = TRIM(p_semester) THEN
        RETURN jsonb_build_object('success', false, 'message', 'เทอม ' || p_semester || '/' || p_academic_year || ' เป็นเทอมปัจจุบันอยู่แล้ว');
    END IF;

    UPDATE clubs SET enrolled_count = 0;
    GET DIAGNOSTICS v_clubs_reset = ROW_COUNT;

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


-- =====================================================================
-- 🌱 SEED DATA: ใส่ข้อมูลตัวอย่างสำหรับพร้อมใช้งานในทันที
-- =====================================================================

-- ข้อมูลตัวอย่างชุมนุม
INSERT INTO clubs (name, teacher, location, description, grades, capacity) VALUES
('ชุมนุมคอมพิวเตอร์และวิทยาการคำนวณ', 'ครูสมเจตน์ เจริญดี', 'ห้องปฏิบัติการคอมพิวเตอร์ 3', 'เรียนรู้การเขียนโปรแกรมด้วยภาษา Python, การคิดเชิงคำนวณ และการสร้างนวัตกรรมดิจิทัลสำหรับมัธยมศึกษา', ARRAY['ม.1', 'ม.2', 'ม.3', 'ม.4', 'ม.5', 'ม.6'], 45),
('ชุมนุมดนตรีสากลและวงสตริง', 'ครูอภิสิทธิ์ พิณทอง', 'ห้องดนตรีสากล อาคาร 3', 'พัฒนาทักษะการเล่นเครื่องดนตรีสากล กีตาร์ เบส กลอง คีย์บอร์ด และซ้อมดนตรีฟอร์มวงสำหรับงานโรงเรียน', ARRAY['ม.1', 'ม.2', 'ม.3', 'ม.4', 'ม.5', 'ม.6'], 25),
('ชุมนุมศิลปะสร้างสรรค์และการออกแบบ', 'ครูภัทรา วรรณดี', 'ห้องศิลปะ 1 อาคารเรียน 4', 'ฝึกทักษะการวาดภาพสีน้ำ สีอะคริลิค การออกแบบงานกราฟิกเบื้องต้น และงานศิลปะแนวร่วมสมัย', ARRAY['ม.1', 'ม.2', 'ม.3', 'ม.4', 'ม.5', 'ม.6'], 30),
('ชุมนุมการโต้วาทีและผู้นำยุคใหม่', 'ครูวรรณวิสา เลิศใจ', 'ห้องประชุมย่อย อาคาร 1', 'พัฒนาทักษะการพูดต่อหน้าชุมชน ความคิดเชิงวิพากษ์ ศิลปะการเจรจาต่อรอง และฝึกทักษะการโต้วาทีระดับภูมิภาค', ARRAY['ม.4', 'ม.5', 'ม.6'], 20),
('ชุมนุมอนุรักษ์ธรรมชาติและสิ่งแวดล้อม', 'ครูสุชาติ รักษ์ไทย', 'สวนพฤกษศาสตร์หลังโรงเรียน', 'ทำกิจกรรมดูแลสิ่งแวดล้อมในโรงเรียน ปลูกผักไฮโดรโปนิกส์ และศึกษาระบบนิเวศพฤกษศาสตร์โรงเรียน', ARRAY['ม.1', 'ม.2', 'ม.3'], 35),
('ชุมนุมกีฬาบาสเกตบอลเพื่อความเป็นเลิศ', 'ครูวิทยา พละเลิศ', 'โรงยิมเนเซียม 2', 'เรียนรู้กฎกติกาการแข่งบาสเกตบอล ฝึกทักษะการส่ง ลูกชู้ต ระบบทีม และสร้างสรรค์แผนการเล่นอย่างถูกหลักกีฬา', ARRAY['ม.1', 'ม.2', 'ม.3', 'ม.4', 'ม.5', 'ม.6'], 40),
('ชุมนุมภาษาอังกฤษเพื่อการสื่อสารและการเดินทาง', 'Mr. David Smith', 'ห้อง Sound Lab 2', 'Enhance English speaking skills through role-plays, presentation skills, and preparing for study abroad trips.', ARRAY['ม.4', 'ม.5', 'ม.6'], 30),
('ชุมนุมอาหารไทยและเบเกอรี่เบื้องต้น', 'ครูสุมาลี ครัวไทย', 'ห้องคหกรรม อาคาร 2', 'ฝึกทำอาหารคาวไทยยอดนิยมและขนมเค้ก/เบเกอรี่ พร้อมเคล็ดลับการจัดจานเพื่อสร้างรายได้เสริมในโรงเรียน', ARRAY['ม.1', 'ม.2', 'ม.3', 'ม.4', 'ม.5', 'ม.6'], 20);

-- ข้อมูลตัวอย่างนักเรียน (สุ่มตัวอย่างห้อง ม.ปลาย และ ม.ต้น)
INSERT INTO students (student_id, prefix, first_name, last_name, level) VALUES
('10001', 'นาย', 'กิตติพงศ์', 'ทองดี', 'ม.4/1'),
('10002', 'นางสาว', 'ณัฏฐณิชา', 'จิตอารีย์', 'ม.4/1'),
('10003', 'นาย', 'ธนพล', 'ปัญญาแก้ว', 'ม.4/2'),
('10004', 'นางสาว', 'สุภัสสรา', 'อินทร์จันทร์', 'ม.4/2'),
('10005', 'นาย', 'ปกรณ์', 'มีชัย', 'ม.5/1'),
('10006', 'นางสาว', 'วรัญญา', 'ศรีสุข', 'ม.5/1'),
('10007', 'นาย', 'จิรเดช', 'สมบูรณ์', 'ม.5/2'),
('10008', 'นางสาว', 'นัทธ์ชนัน', 'แสงอรุณ', 'ม.5/2'),
('10009', 'นาย', 'ปรเมศวร์', 'อุดมผล', 'ม.6/1'),
('10010', 'นางสาว', 'อภิชญา', 'สิริกุล', 'ม.6/1'),
('10011', 'เด็กชาย', 'ศุภโชค', 'ใจดี', 'ม.1/1'),
('10012', 'เด็กหญิง', 'อนัญญา', 'รักษาสัตย์', 'ม.1/1'),
('10013', 'เด็กชาย', 'ธนภัทร', 'แก้วตา', 'ม.2/1'),
('10014', 'เด็กหญิง', 'ชลิดา', 'เดชรุ่ง', 'ม.2/1'),
('10015', 'เด็กชาย', 'พีรพล', 'คงกระพัน', 'ม.3/1'),
('10016', 'เด็กหญิง', 'กนกวรรณ', 'สิริเวช', 'ม.3/2');
-- =====================================================================
-- 🚀 MIGRATION V3 — ระบบจัดการข้อมูลศิษย์เก่า (PDPA)
-- =====================================================================
-- ต้องรัน migration_v2.sql มาก่อน
-- รันสคริปต์นี้บน Supabase SQL Editor *เพียงครั้งเดียว*
-- ปลอดภัย: ใช้ CREATE OR REPLACE ทั้งหมด รันซ้ำได้ไม่เสีย
-- =====================================================================

-- ────────────────────────────────────────────────────────────────────
-- 1. anonymize_graduated_students(p_years_old) — ปกปิดข้อมูลศิษย์เก่าเกิน N ปี
-- แทนชื่อด้วย "ศิษย์เก่า #YEAR-NNN" เพื่อรักษาสถิติแต่ลบข้อมูลส่วนตัว
-- ทำงานเฉพาะนักเรียน status='graduated' และ graduated_year ≤ (current - N)
-- ────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION anonymize_graduated_students(
    p_years_old INT DEFAULT 5,
    p_ip_address TEXT DEFAULT NULL,
    p_user_agent TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_current_year_text TEXT;
    v_current_year_int INT;
    v_cutoff_year INT;
    v_student RECORD;
    v_counter INT;
    v_anon_first TEXT;
    v_anon_last TEXT;
    v_anonymized INT := 0;
    v_skipped INT := 0;
BEGIN
    IF p_years_old IS NULL OR p_years_old < 0 THEN
        RETURN jsonb_build_object('success', false, 'message', 'จำนวนปีต้องเป็นจำนวนเต็มไม่ติดลบ');
    END IF;

    SELECT COALESCE(value->>'academic_year', '2569')
    INTO v_current_year_text
    FROM settings WHERE key = 'school_config';

    BEGIN
        v_current_year_int := v_current_year_text::INT;
    EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'ปีการศึกษาในระบบไม่ใช่ตัวเลขที่ถูกต้อง: ' || v_current_year_text);
    END;

    v_cutoff_year := v_current_year_int - p_years_old;

    FOR v_student IN
        SELECT id, student_id, graduated_year, first_name, last_name
        FROM students
        WHERE status = 'graduated'
          AND graduated_year IS NOT NULL
          AND graduated_year ~ '^\d+$'
          AND graduated_year::INT <= v_cutoff_year
          AND first_name <> 'ศิษย์เก่า'
        ORDER BY graduated_year, id
    LOOP
        -- หา counter ภายในปีนั้น (นับ anon ที่มีอยู่แล้ว + 1)
        SELECT COUNT(*) + 1 INTO v_counter
        FROM students
        WHERE first_name = 'ศิษย์เก่า'
          AND last_name LIKE '#' || v_student.graduated_year || '-%';

        v_anon_first := 'ศิษย์เก่า';
        v_anon_last := '#' || v_student.graduated_year || '-' || LPAD(v_counter::TEXT, 3, '0');

        -- อัปเดต students
        UPDATE students
        SET prefix = NULL,
            first_name = v_anon_first,
            last_name = v_anon_last,
            student_id = NULL
        WHERE id = v_student.id;

        -- อัปเดต registrations ที่อ้างถึงนักเรียนคนนี้ (จับด้วยชื่อเดิม + รหัสเดิม)
        UPDATE registrations
        SET prefix = NULL,
            first_name = v_anon_first,
            last_name = v_anon_last,
            student_id = NULL
        WHERE (
                (v_student.student_id IS NOT NULL AND student_id = v_student.student_id)
                OR (TRIM(first_name) = TRIM(v_student.first_name)
                    AND TRIM(last_name) = TRIM(v_student.last_name))
              );

        v_anonymized := v_anonymized + 1;
    END LOOP;

    SELECT COUNT(*) INTO v_skipped
    FROM students
    WHERE status = 'graduated'
      AND first_name = 'ศิษย์เก่า';

    INSERT INTO audit_logs (action, ip_address, user_agent, details)
    VALUES (
        'ANONYMIZE_GRADUATED_STUDENTS',
        COALESCE(p_ip_address, 'Unknown IP'),
        COALESCE(p_user_agent, 'Unknown Device'),
        'ปกปิดข้อมูลศิษย์เก่าที่จบเกิน ' || p_years_old || ' ปี (cutoff <= ' || v_cutoff_year
            || '): ปกปิด ' || v_anonymized || ' คน, มี anonymous เดิมในระบบ ' || v_skipped || ' คน'
    );

    RETURN jsonb_build_object(
        'success', true,
        'anonymized', v_anonymized,
        'cutoff_year', v_cutoff_year,
        'current_year', v_current_year_int,
        'years_old', p_years_old,
        'total_anonymous', v_skipped
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$;

-- ────────────────────────────────────────────────────────────────────
-- 2. delete_graduated_student(p_student_pk) — ลบข้อมูลรายคนถาวร (PDPA)
-- p_student_pk = students.id (UUID) — ลบทั้ง students + registrations ที่เชื่อมโยง
-- เฉพาะนักเรียน status='graduated' เท่านั้น (กันลบนักเรียนปัจจุบันโดยพลาด)
-- ────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION delete_graduated_student(
    p_student_pk UUID,
    p_ip_address TEXT DEFAULT NULL,
    p_user_agent TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_student RECORD;
    v_reg_deleted INT := 0;
    v_full_name TEXT;
BEGIN
    SELECT id, student_id, prefix, first_name, last_name, status, graduated_year
    INTO v_student
    FROM students WHERE id = p_student_pk;

    IF v_student.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'ไม่พบนักเรียนในระบบ');
    END IF;

    IF v_student.status <> 'graduated' THEN
        RETURN jsonb_build_object('success', false, 'message', 'ลบได้เฉพาะนักเรียนที่จบการศึกษาแล้วเท่านั้น');
    END IF;

    v_full_name := COALESCE(v_student.prefix, '') || COALESCE(v_student.first_name, '')
                || ' ' || COALESCE(v_student.last_name, '');

    -- ลบ registrations ที่เชื่อมโยง (ผ่าน student_id หรือ ชื่อ-นามสกุล)
    DELETE FROM registrations
    WHERE (v_student.student_id IS NOT NULL AND student_id = v_student.student_id)
       OR (TRIM(first_name) = TRIM(v_student.first_name)
           AND TRIM(last_name) = TRIM(v_student.last_name));
    GET DIAGNOSTICS v_reg_deleted = ROW_COUNT;

    DELETE FROM students WHERE id = p_student_pk;

    INSERT INTO audit_logs (student_id, student_name, action, ip_address, user_agent, details)
    VALUES (
        v_student.student_id,
        v_full_name,
        'DELETE_GRADUATED_STUDENT',
        COALESCE(p_ip_address, 'Unknown IP'),
        COALESCE(p_user_agent, 'Unknown Device'),
        'ลบข้อมูลศิษย์เก่าถาวร (จบปี ' || COALESCE(v_student.graduated_year, '-')
            || ', ลบ registrations ที่เชื่อมโยง ' || v_reg_deleted || ' รายการ)'
    );

    RETURN jsonb_build_object(
        'success', true,
        'deleted_student', v_full_name,
        'registrations_deleted', v_reg_deleted
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$;
