-- =============================================================
-- Migration: ลบชุมนุมซ้ำ + เพิ่ม UNIQUE constraint บนชื่อชุมนุม
-- วิธีใช้: คัดลอกทั้งหมดไปวางใน Supabase SQL Editor แล้วกด Run
-- =============================================================

BEGIN;

-- 1. ย้าย registrations จากแถวซ้ำไปยังแถวหลัก (เก็บแถวที่ enrolled_count สูงสุด, ถ้าเท่ากันเก็บ created_at เก่าสุด)
WITH ranked AS (
    SELECT
        id,
        name,
        ROW_NUMBER() OVER (
            PARTITION BY name
            ORDER BY enrolled_count DESC, created_at ASC
        ) AS rn
    FROM clubs
),
winners AS (
    SELECT id, name FROM ranked WHERE rn = 1
),
losers AS (
    SELECT r.id, r.name FROM ranked r WHERE r.rn > 1
)
UPDATE registrations
SET club_id = w.id
FROM losers l
JOIN winners w ON w.name = l.name
WHERE registrations.club_id = l.id;

-- 2. ลบแถวซ้ำ (เหลือไว้เฉพาะแถวหลัก)
WITH ranked AS (
    SELECT
        id,
        name,
        ROW_NUMBER() OVER (
            PARTITION BY name
            ORDER BY enrolled_count DESC, created_at ASC
        ) AS rn
    FROM clubs
)
DELETE FROM clubs
WHERE id IN (SELECT id FROM ranked WHERE rn > 1);

-- 3. เพิ่ม UNIQUE constraint
ALTER TABLE clubs ADD CONSTRAINT clubs_name_unique UNIQUE (name);

COMMIT;
