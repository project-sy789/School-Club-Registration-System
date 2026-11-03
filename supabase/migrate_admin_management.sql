-- Admin account cleanup and resend support.
-- Run after migrate_backend_hardening.sql.

CREATE OR REPLACE FUNCTION public.admin_remove_user(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_email TEXT;
BEGIN
    IF NOT is_admin() THEN
        RETURN jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'ไม่มีสิทธิ์ผู้ดูแลระบบ');
    END IF;
    IF p_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'ไม่พบผู้ดูแลที่ต้องการลบ');
    END IF;
    IF p_user_id = auth.uid() THEN
        RETURN jsonb_build_object('success', false, 'code', 'SELF_REMOVE', 'message', 'ไม่สามารถลบสิทธิ์บัญชีที่กำลังใช้งานอยู่ได้');
    END IF;

    SELECT email INTO v_email FROM auth.users WHERE id = p_user_id;
    DELETE FROM admin_users WHERE user_id = p_user_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'ไม่พบผู้ดูแลที่ต้องการลบ');
    END IF;

    INSERT INTO audit_logs (action, details)
    VALUES ('ADMIN_REMOVED', 'ลบสิทธิ์ผู้ดูแลระบบ: ' || COALESCE(v_email, p_user_id::TEXT));

    RETURN jsonb_build_object('success', true, 'user_id', p_user_id, 'email', v_email);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_remove_user(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_remove_user(UUID) TO authenticated;
