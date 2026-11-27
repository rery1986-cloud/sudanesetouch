-- Stage 2 notifications: the admin gets an in-app notification when a new user registers. Run as one migration, exactly as written.
CREATE TABLE IF NOT EXISTS public.admin_notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind text NOT NULL,
  title text NOT NULL,
  body text,
  ref_user_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  read_at timestamptz
);
CREATE INDEX IF NOT EXISTS admin_notifications_created_idx ON public.admin_notifications (created_at DESC);
ALTER TABLE public.admin_notifications ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.admin_notifications FROM anon, authenticated;
GRANT SELECT ON public.admin_notifications TO authenticated;
GRANT UPDATE (read_at) ON public.admin_notifications TO authenticated;
DROP POLICY IF EXISTS admin_notifications_select ON public.admin_notifications;
CREATE POLICY admin_notifications_select ON public.admin_notifications FOR SELECT TO authenticated
  USING (private.is_platform_admin());
DROP POLICY IF EXISTS admin_notifications_update ON public.admin_notifications;
CREATE POLICY admin_notifications_update ON public.admin_notifications FOR UPDATE TO authenticated
  USING (private.is_platform_admin()) WITH CHECK (private.is_platform_admin());

CREATE OR REPLACE FUNCTION private.notify_new_profile()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  BEGIN
    INSERT INTO public.admin_notifications (kind, title, body, ref_user_id)
    VALUES (
      'new_user',
      'تسجيل جديد: ' || coalesce(NEW.full_name, NEW.email, ''),
      'النوع: ' || coalesce(NEW.account_type, NEW.role, '') || ' | المدينة: ' || coalesce(NEW.city, '') || ' | البريد: ' || coalesce(NEW.email, ''),
      NEW.id
    );
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION private.notify_new_profile() FROM PUBLIC;
DROP TRIGGER IF EXISTS notify_new_profile ON public.profiles;
CREATE TRIGGER notify_new_profile AFTER INSERT ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION private.notify_new_profile();
