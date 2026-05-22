-- =============================================================
-- Migration: เพิ่มคอลัมน์ prefix (คำนำหน้าชื่อ) ให้ตาราง students
-- แก้ปัญหา: 500 error เวลา Bulk Import นักเรียน เพราะฐานข้อมูลเก่ายังไม่มีคอลัมน์ prefix
-- วิธีใช้: คัดลอกทั้งหมดไปวางใน Supabase SQL Editor แล้วกด Run
-- =============================================================

BEGIN;

-- 1. เพิ่มคอลัมน์ prefix แบบ idempotent (รันซ้ำได้โดยไม่ error)
ALTER TABLE students ADD COLUMN IF NOT EXISTS prefix TEXT;

-- 2. ผ่อนปรน NOT NULL บน last_name / level เผื่อ CSV เก่าที่บางแถวเว้นว่าง
--    (ถ้าต้องการบังคับเหมือนเดิม ให้ลบสองบรรทัดนี้ออก)
ALTER TABLE students ALTER COLUMN last_name DROP NOT NULL;
ALTER TABLE students ALTER COLUMN level DROP NOT NULL;

COMMIT;
