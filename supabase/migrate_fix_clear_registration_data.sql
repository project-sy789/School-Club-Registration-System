-- Fix the admin reset tool for existing installations.
-- Clears registrations only, preserves audit_logs, students, and clubs.
-- The explicit WHERE clauses are required by Supabase's safe-update guard.
BEGIN;

CREATE OR REPLACE FUNCTION public.admin_clear_registration_data(p_confirmation TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_deleted INTEGER;
    v_updated INTEGER;
BEGIN
    IF NOT is_admin() THEN
        RETURN jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'ไม่มีสิทธิ์ผู้ดูแลระบบ');
    END IF;
    IF p_confirmation <> 'CLEAR REGISTRATIONS' THEN
        RETURN jsonb_build_object('success', false, 'code', 'CONFIRMATION_REQUIRED', 'message', 'คำยืนยันไม่ถูกต้อง');
    END IF;

    DELETE FROM public.registrations WHERE id IS NOT NULL;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;

    UPDATE public.clubs
    SET enrolled_count = 0
    WHERE id IS NOT NULL;
    GET DIAGNOSTICS v_updated = ROW_COUNT;

    INSERT INTO public.audit_logs (action, details)
    VALUES ('REGISTRATION_DATA_CLEARED',
            'ล้างเฉพาะรายการลงทะเบียน: ' || v_deleted || ' รายการ; เก็บ audit logs เดิมไว้');

    RETURN jsonb_build_object(
        'success', true,
        'registrations_deleted', v_deleted,
        'clubs_updated', v_updated
    );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_clear_registration_data(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_clear_registration_data(TEXT) TO authenticated;

COMMIT;
