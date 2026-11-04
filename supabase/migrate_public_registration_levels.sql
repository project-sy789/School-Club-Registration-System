-- Public classroom dropdown helper
-- Run after setup_database.sql and migrate_backend_hardening.sql.
-- This exposes only distinct classroom labels; students remain protected by RLS.

CREATE OR REPLACE FUNCTION public.get_registration_levels()
RETURNS TABLE(level TEXT)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT DISTINCT btrim(s.level)::TEXT AS level
    FROM public.students AS s
    WHERE s.status = 'active'
      AND NULLIF(btrim(s.level), '') IS NOT NULL
    ORDER BY 1;
$$;

REVOKE ALL ON FUNCTION public.get_registration_levels() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_registration_levels() TO anon, authenticated;
