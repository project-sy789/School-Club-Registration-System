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
    "semester": "1/2569",
    "admin_password": "admin",
    "logo_base64": null
}'::jsonb),
('registration_period', '{
    "is_active": true,
    "start_time": "2026-05-20T08:30:00",
    "end_time": "2026-05-25T16:30:00"
}'::jsonb);


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
    level TEXT NOT NULL -- เช่น ม.4/1, ม.5/2
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
    created_at TIMESTAMPTZ DEFAULT now(),
    -- ห้ามชื่อ-นามสกุลเดียวกันลงทะเบียนซ้ำในระบบ
    CONSTRAINT unique_student_name UNIQUE (first_name, last_name)
);

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
    -- จะถือว่าซ้ำก็ต่อเมื่อชื่อ-นามสกุลตรงกัน และ (มีฝ่ายใดฝ่ายหนึ่งไม่มีรหัสประจำตัว หรือทั้งสองฝ่ายมีรหัสประจำตัวตรงกัน)
    SELECT EXISTS (
        SELECT 1 FROM registrations 
        WHERE TRIM(first_name) = TRIM(p_first_name) 
          AND TRIM(last_name) = TRIM(p_last_name)
          AND (
              student_id IS NULL 
              OR v_student_id_cleaned IS NULL 
              OR student_id = v_student_id_cleaned
          )
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
    INSERT INTO registrations (club_id, student_id, prefix, first_name, last_name, level, registration_status)
    VALUES (p_club_id, v_student_id_cleaned, TRIM(p_prefix), TRIM(p_first_name), TRIM(p_last_name), TRIM(p_level), v_status)
    RETURNING id INTO v_registered_id;

    -- 6. อัปเดตยอดผู้สมัครในแถวของชุมนุมให้เรียบร้อย
    UPDATE clubs
    SET enrolled_count = enrolled_count + 1
    WHERE id = p_club_id;

    -- 7. บันทึกประวัติความปลอดภัย (Audit Log)
    INSERT INTO audit_logs (student_id, student_name, action, club_name, ip_address, user_agent, details)
    VALUES (
        v_student_id_cleaned,
        COALESCE(TRIM(p_prefix), '') || TRIM(p_first_name) || ' ' || TRIM(p_last_name),
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
