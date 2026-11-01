-- Keep admin bulk registration compatible with the phone-first Pending flow.
-- Existing student IDs still import as verified; rows without a real ID must
-- provide a 10-digit phone so the student can recover the reservation later.
BEGIN;

CREATE OR REPLACE FUNCTION public.bulk_register_atomic(
    p_rows JSONB,
    p_ip_address TEXT DEFAULT NULL,
    p_user_agent TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, private, pg_temp
AS $$
DECLARE
    v_row JSONB;
    v_club_id UUID;
    v_club_name TEXT;
    v_capacity INTEGER;
    v_enrolled INTEGER;
    v_input_club_name TEXT;
    v_student_id_cleaned TEXT;
    v_phone TEXT;
    v_student_exists BOOLEAN;
    v_first_name TEXT;
    v_last_name TEXT;
    v_prefix TEXT;
    v_level TEXT;
    v_status TEXT;
    v_pending_contact_hash TEXT;
    v_pending_contact_hint TEXT;
    v_phone_secret BYTEA;
    v_inserted_count INT := 0;
    v_skipped JSONB := '[]'::jsonb;
    v_failed JSONB := '[]'::jsonb;
    v_current_year TEXT;
    v_current_sem TEXT;
    v_scope TEXT;
BEGIN
    SELECT COALESCE(value->>'academic_year', '2569'),
           COALESCE(value->>'semester', '1'),
           CASE WHEN value->>'registration_scope' = 'academic_year' THEN 'academic_year' ELSE 'semester' END
    INTO v_current_year, v_current_sem, v_scope
    FROM settings WHERE key = 'school_config';

    FOR v_row IN SELECT * FROM jsonb_array_elements(COALESCE(p_rows, '[]'::jsonb)) LOOP
        BEGIN
            v_student_id_cleaned := NULLIF(btrim(COALESCE(v_row->>'student_id', '')), '');
            v_phone := regexp_replace(
                btrim(COALESCE(v_row->>'phone', v_row->>'เบอร์โทร', '')),
                '[^0-9]', '', 'g'
            );
            IF v_phone ~ '^66[0-9]{9}$' THEN
                v_phone := '0' || substr(v_phone, 3);
            ELSIF v_phone ~ '^[0-9]{9}$' THEN
                v_phone := '0' || v_phone;
            END IF;
            v_phone := NULLIF(v_phone, '');

            -- Accept the old template's phone-in-student_id convention once,
            -- but never store a phone in registrations.student_id.
            IF v_student_id_cleaned ~ '^0[0-9]{9}$' AND v_phone IS NULL THEN
                v_phone := v_student_id_cleaned;
                v_student_id_cleaned := NULL;
            END IF;

            v_prefix := NULLIF(btrim(COALESCE(v_row->>'prefix', '')), '');
            v_first_name := btrim(COALESCE(v_row->>'first_name', ''));
            v_last_name := btrim(COALESCE(v_row->>'last_name', ''));
            v_level := btrim(COALESCE(v_row->>'level', ''));
            v_input_club_name := btrim(COALESCE(v_row->>'club_name', ''));

            IF v_first_name = '' OR v_last_name = '' OR v_input_club_name = '' OR v_level = '' THEN
                v_failed := v_failed || jsonb_build_object('row', v_row, 'reason', 'ข้อมูลไม่ครบ (ต้องมี first_name, last_name, level, club_name)');
                CONTINUE;
            END IF;

            SELECT id, name, capacity, enrolled_count
            INTO v_club_id, v_club_name, v_capacity, v_enrolled
            FROM clubs
            WHERE lower(btrim(name)) = lower(v_input_club_name)
            LIMIT 1
            FOR UPDATE;

            IF v_club_id IS NULL THEN
                v_failed := v_failed || jsonb_build_object('row', v_row, 'reason', 'ไม่พบชุมนุมชื่อ "' || v_input_club_name || '" ในระบบ');
                CONTINUE;
            END IF;

            IF v_scope = 'academic_year' THEN
                SELECT COUNT(*) INTO v_enrolled
                FROM registrations
                WHERE club_id = v_club_id AND academic_year = v_current_year;
            END IF;

            IF v_enrolled >= v_capacity THEN
                v_skipped := v_skipped || jsonb_build_object('row', v_row, 'reason', 'ชุมนุม "' || v_club_name || '" เต็มโควตา (' || v_enrolled || '/' || v_capacity || ')');
                CONTINUE;
            END IF;

            v_pending_contact_hash := NULL;
            v_pending_contact_hint := NULL;
            IF v_student_id_cleaned IS NOT NULL THEN
                PERFORM pg_advisory_xact_lock(hashtextextended(
                    'registration-student:' || v_current_year || ':' || v_student_id_cleaned, 0));
                IF EXISTS (
                    SELECT 1 FROM registrations
                    WHERE student_id = v_student_id_cleaned
                      AND academic_year = v_current_year
                      AND (v_scope = 'academic_year' OR semester = v_current_sem)
                ) THEN
                    v_skipped := v_skipped || jsonb_build_object('row', v_row, 'reason', CASE WHEN v_scope = 'academic_year' THEN 'รหัสนักเรียน ' || v_student_id_cleaned || ' ลงทะเบียนปีนี้ไปแล้ว' ELSE 'รหัสนักเรียน ' || v_student_id_cleaned || ' ลงทะเบียนเทอมนี้ไปแล้ว' END);
                    CONTINUE;
                END IF;
                SELECT EXISTS (
                    SELECT 1 FROM students
                    WHERE student_id = v_student_id_cleaned AND status = 'active'
                ) INTO v_student_exists;
            ELSE
                v_student_exists := false;
            END IF;

            v_status := CASE WHEN v_student_exists THEN 'verified' ELSE 'pending' END;
            IF v_status = 'pending' THEN
                IF v_phone IS NULL OR v_phone !~ '^0[0-9]{9}$' THEN
                    v_failed := v_failed || jsonb_build_object('row', v_row, 'reason', 'นักเรียนที่ยังไม่มีรหัสต้องมีเบอร์โทร 10 หลักที่ขึ้นต้นด้วย 0');
                    CONTINUE;
                END IF;
                SELECT secret INTO v_phone_secret
                FROM private.registration_secrets
                WHERE name = 'pending_phone_hmac';
                v_pending_contact_hash := encode(hmac(
                    convert_to(v_phone || ':' || lower(v_first_name) || ':' || lower(v_last_name) || ':' || lower(v_level), 'UTF8'),
                    v_phone_secret,
                    'sha256'::text
                ), 'hex');
                v_pending_contact_hint := right(v_phone, 4);
                PERFORM pg_advisory_xact_lock(hashtextextended(
                    'registration-contact:' || v_current_year || ':' || v_pending_contact_hash, 0));
                IF EXISTS (
                    SELECT 1 FROM registrations
                    WHERE pending_contact_hash = v_pending_contact_hash
                      AND academic_year = v_current_year
                      AND (v_scope = 'academic_year' OR semester = v_current_sem)
                ) THEN
                    v_skipped := v_skipped || jsonb_build_object('row', v_row, 'reason', 'เบอร์โทรนี้มีรายการสมัครในรอบนี้แล้ว');
                    CONTINUE;
                END IF;
                v_student_id_cleaned := NULL;
            END IF;

            INSERT INTO registrations (
                club_id, student_id, pending_contact_hash, pending_contact_hint,
                prefix, first_name, last_name, level,
                registration_status, academic_year, semester
            )
            VALUES (
                v_club_id, v_student_id_cleaned, v_pending_contact_hash, v_pending_contact_hint,
                v_prefix, v_first_name, v_last_name, v_level,
                v_status, v_current_year, v_current_sem
            );

            UPDATE clubs c
            SET enrolled_count = (
                SELECT COUNT(*) FROM registrations r
                WHERE r.club_id = c.id
                  AND r.academic_year = v_current_year
                  AND (v_scope = 'academic_year' OR r.semester = v_current_sem)
            )
            WHERE c.id = v_club_id;
            v_inserted_count := v_inserted_count + 1;
        EXCEPTION WHEN OTHERS THEN
            v_failed := v_failed || jsonb_build_object('row', v_row, 'reason', SQLERRM);
        END;
    END LOOP;

    INSERT INTO audit_logs (action, ip_address, user_agent, details)
    VALUES ('BULK_REGISTRATION_IMPORT', left(COALESCE(p_ip_address, 'Unknown IP'), 128),
            left(COALESCE(p_user_agent, 'Unknown Device'), 500),
            'Bulk import ' || CASE WHEN v_scope = 'academic_year' THEN 'ปีการศึกษา ' || v_current_year ELSE 'เทอม ' || v_current_sem || '/' || v_current_year END
            || ': สำเร็จ ' || v_inserted_count || ', ข้าม ' || jsonb_array_length(v_skipped)
            || ', ผิดพลาด ' || jsonb_array_length(v_failed));

    RETURN jsonb_build_object('success', true, 'inserted', v_inserted_count,
                              'skipped', v_skipped, 'failed', v_failed);
END;
$$;

REVOKE ALL ON FUNCTION public.bulk_register_atomic(JSONB, TEXT, TEXT) FROM PUBLIC, anon, authenticated;

COMMIT;
