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
