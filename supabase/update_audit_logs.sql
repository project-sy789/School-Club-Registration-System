-- =====================================================================
-- 🛡️ MIGRATION SCRIPT: ADD AUDIT LOGS & UPDATE RPC (CONCURRENCY SAFE)
-- คัดลอกเฉพาะสคริปต์นี้ไปรันในช่อง SQL Editor ของ Supabase เพื่ออัปเกรดระบบโดยไม่สูญเสียข้อมูลเดิม!
-- =====================================================================

-- 1. สร้างตารางบันทึกประวัติความปลอดภัยและการกระทำระบบ (Audit Logs)
CREATE TABLE IF NOT EXISTS audit_logs (
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

-- ลบ Policy เดิมหากเคยสร้างไว้
DROP POLICY IF EXISTS "Allow public insert access to audit_logs" ON audit_logs;
DROP POLICY IF EXISTS "Allow read access to audit_logs for admin" ON audit_logs;

-- สร้างสิทธิ์การเข้าใช้งาน
CREATE POLICY "Allow public insert access to audit_logs" ON audit_logs FOR INSERT WITH CHECK (true);
CREATE POLICY "Allow read access to audit_logs for admin" ON audit_logs FOR SELECT USING (true);


-- 2. ปรับปรุง Stored Procedure ให้รองรับการบันทึก IP และ User Agent ลงใน Audit Logs อัตโนมัติ
CREATE OR REPLACE FUNCTION register_student_atomic(
    p_club_id UUID,
    p_student_id TEXT,
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
BEGIN
    -- ทำความสะอาดรหัสนักเรียน (ลบเว้นวรรค)
    v_student_id_cleaned := TRIM(p_student_id);
    IF v_student_id_cleaned = '' THEN
        v_student_id_cleaned := NULL;
    END IF;

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

    -- 2. ป้องกันสิทธิ์การลงทะเบียนซ้ำซ้อน
    -- 2.1 ตรวจสอบกรณีใช้เลขประจำตัวนักเรียน
    IF v_student_id_cleaned IS NOT NULL THEN
        SELECT EXISTS (
            SELECT 1 FROM registrations WHERE student_id = v_student_id_cleaned
        ) INTO v_already_registered;
        
        IF v_already_registered THEN
            RETURN jsonb_build_object('success', false, 'message', 'รหัสนักเรียน ' || v_student_id_cleaned || ' นี้ได้ทำการลงทะเบียนเรียนชุมนุมไปเรียบร้อยแล้ว ห้ามสมัครซ้ำ');
        END IF;
    END IF;

    -- 2.2 ตรวจสอบกรณีชื่อและนามสกุล (ป้องกันสมัครซ้ำด้วยชื่อ)
    SELECT EXISTS (
        SELECT 1 FROM registrations 
        WHERE TRIM(first_name) = TRIM(p_first_name) AND TRIM(last_name) = TRIM(p_last_name)
    ) INTO v_already_registered;

    IF v_already_registered THEN
        RETURN jsonb_build_object('success', false, 'message', 'นักเรียนชื่อ ' || p_first_name || ' ' || p_last_name || ' ได้ทำการลงทะเบียนเรียนชุมนุมไปเรียบร้อยแล้ว');
    END IF;

    -- 3. ตรวจสอบโควตาที่นั่งและล็อกข้อมูลชุมนุม (Row Lock) เพื่อป้องกันข้อมูลขัดแย้งขณะยิงเข้ามาพร้อมกันเยอะๆ
    SELECT name, capacity, enrolled_count 
    INTO v_club_name, v_capacity, v_enrolled
    FROM clubs
    WHERE id = p_club_id
    FOR UPDATE; -- สำคัญมาก! บล็อกและจัดคิวข้อมูลเพื่อให้ประมวลผลทีละคิวตรงชุมนุมนี้

    IF v_capacity IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'ไม่พบชุมนุมที่คุณเลือกในระบบ');
    END IF;

    IF v_enrolled >= v_capacity THEN
        RETURN jsonb_build_object('success', false, 'message', 'ขออภัย ชุมนุม "' || v_club_name || '" เต็มโควตาแล้ว กรุณาเลือกชุมนุมอื่น');
    END IF;

    -- 4. ตรวจสอบสถานะการยืนยันตัวตน (ถ้ามีใน DB นักเรียน = verified, ถ้าไม่มี = pending)
    IF v_student_id_cleaned IS NOT NULL THEN
        SELECT EXISTS (
            SELECT 1 FROM students WHERE student_id = v_student_id_cleaned
        ) INTO v_student_exists;
    ELSE
        v_student_exists := false;
    END IF;

    IF v_student_exists THEN
        v_status := 'verified';
    ELSE
        v_status := 'pending';
    END IF;

    -- 5. ดำเนินการสมัคร: เพิ่มชื่อนักเรียนในตารางการลงทะเบียน
    INSERT INTO registrations (club_id, student_id, first_name, last_name, level, registration_status)
    VALUES (p_club_id, v_student_id_cleaned, TRIM(p_first_name), TRIM(p_last_name), TRIM(p_level), v_status)
    RETURNING id INTO v_registered_id;

    -- 6. อัปเดตยอดผู้สมัครในแถวของชุมนุมให้เรียบร้อย
    UPDATE clubs
    SET enrolled_count = enrolled_count + 1
    WHERE id = p_club_id;

    -- 7. บันทึกประวัติความปลอดภัย (Audit Log)
    INSERT INTO audit_logs (student_id, student_name, action, club_name, ip_address, user_agent, details)
    VALUES (
        v_student_id_cleaned,
        TRIM(p_first_name) || ' ' || TRIM(p_last_name),
        CASE WHEN v_status = 'verified' THEN 'REGISTER_SUCCESS' ELSE 'REGISTER_PENDING' END,
        v_club_name,
        COALESCE(p_ip_address, 'Unknown IP'),
        COALESCE(p_user_agent, 'Unknown Device'),
        'นักเรียนทำการลงทะเบียนด้วยตนเอง (ระดับห้อง: ' || p_level || ', สถานะสิทธิ์: ' || v_status || ')'
    );

    -- ส่งกลับผลลัพธ์สำเร็จ
    RETURN jsonb_build_object(
        'success', true, 
        'message', 'ลงทะเบียนเรียนชุมนุม "' || v_club_name || '" สำเร็จแล้ว', 
        'status', v_status,
        'registration_id', v_registered_id
    );

EXCEPTION WHEN OTHERS THEN
    -- เกิดข้อผิดพลาด ปลดการทำงานและ Rollback อัตโนมัติ
    RETURN jsonb_build_object('success', false, 'message', 'เกิดข้อผิดพลาดในการประมวลผล กรุณาลองใหม่อีกครั้ง (' || SQLERRM || ')');
END;
$$;
