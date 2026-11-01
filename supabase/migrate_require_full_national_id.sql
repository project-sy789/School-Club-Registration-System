-- Require the full 13-digit national ID when administrators configure a student.
-- The database still stores only keyed HMACs: one for lookup and one for the
-- final four digits used by the student verification flow.
BEGIN;

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
    v_secret BYTEA;
    v_updated INTEGER;
BEGIN
    IF NOT is_admin() THEN
        RAISE EXCEPTION 'not authorized';
    END IF;
    IF v_student_id IS NULL OR v_digits !~ '^[0-9]{13}$' THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_NATIONAL_ID',
            'message', 'กรุณากรอกเลขบัตรประชาชนให้ครบ 13 หลัก'
        );
    END IF;

    SELECT secret INTO v_secret
    FROM private.registration_secrets
    WHERE name = 'student_identity_hmac';

    IF EXISTS (
        SELECT 1
        FROM students
        WHERE national_id_hash = encode(hmac(convert_to(v_digits, 'UTF8'), v_secret, 'sha256'::text), 'hex')
          AND student_id IS DISTINCT FROM v_student_id
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'DUPLICATE_NATIONAL_ID',
            'message', 'เลขบัตรประชาชนนี้ถูกผูกกับรหัสนักเรียนอื่นแล้ว'
        );
    END IF;

    UPDATE students
    SET identity_last4_hash = encode(hmac(convert_to(right(v_digits, 4), 'UTF8'), v_secret, 'sha256'::text), 'hex'),
        national_id_hash = encode(hmac(convert_to(v_digits, 'UTF8'), v_secret, 'sha256'::text), 'hex')
    WHERE student_id = v_student_id;
    GET DIAGNOSTICS v_updated = ROW_COUNT;

    IF v_updated = 0 THEN
        RETURN jsonb_build_object('success', false, 'code', 'STUDENT_NOT_FOUND', 'message', 'ไม่พบนักเรียนรหัสนี้');
    END IF;
    RETURN jsonb_build_object('success', true, 'student_id', v_student_id);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_set_student_identity_last4(TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_student_identity_last4(TEXT, TEXT) TO authenticated;

COMMIT;
