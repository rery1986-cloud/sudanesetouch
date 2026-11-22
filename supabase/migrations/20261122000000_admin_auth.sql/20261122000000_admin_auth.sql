CREATE TABLE IF NOT EXISTS public.platform_admins (
  user_id uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  email text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.platform_admins ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.platform_admins FROM anon, authenticated;
GRANT SELECT ON public.platform_admins TO authenticated;

DROP POLICY IF EXISTS platform_admins_select_self ON public.platform_admins;
CREATE POLICY platform_admins_select_self
  ON public.platform_admins
  FOR SELECT
  TO authenticated
  USING (user_id = (SELECT auth.uid()));

CREATE OR REPLACE FUNCTION public.sync_platform_admin()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.email IS NOT NULL
     AND lower(NEW.email) = 'rery1986@gmail.com'
     AND NEW.email_confirmed_at IS NOT NULL THEN
    INSERT INTO public.platform_admins (user_id, email)
    VALUES (NEW.id, lower(NEW.email))
    ON CONFLICT (user_id) DO UPDATE SET email = EXCLUDED.email;
  ELSE
    DELETE FROM public.platform_admins WHERE user_id = NEW.id;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.sync_platform_admin() FROM PUBLIC;

DROP TRIGGER IF EXISTS sync_platform_admin ON auth.users;
CREATE TRIGGER sync_platform_admin
  AFTER INSERT OR UPDATE ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.sync_platform_admin();

INSERT INTO public.platform_admins (user_id, email)
SELECT id, lower(email)
FROM auth.users
WHERE lower(email) = 'rery1986@gmail.com'
  AND email_confirmed_at IS NOT NULL
ON CONFLICT (user_id) DO UPDATE SET email = EXCLUDED.email;

CREATE TABLE IF NOT EXISTS public.app_state (
  id text PRIMARY KEY,
  data jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.app_state ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.app_state FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.app_state TO authenticated;

DO $$
DECLARE
  existing_policy record;
BEGIN
  FOR existing_policy IN
    SELECT policyname
    FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'app_state'
  LOOP
    EXECUTE format('DROP POLICY %I ON public.app_state', existing_policy.policyname);
  END LOOP;
END;
$$;

CREATE POLICY app_state_admin_select
  ON public.app_state
  FOR SELECT
  TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.platform_admins
    WHERE user_id = (SELECT auth.uid())
  ));

CREATE POLICY app_state_admin_insert
  ON public.app_state
  FOR INSERT
  TO authenticated
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.platform_admins
    WHERE user_id = (SELECT auth.uid())
  ));

CREATE POLICY app_state_admin_update
  ON public.app_state
  FOR UPDATE
  TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.platform_admins
    WHERE user_id = (SELECT auth.uid())
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.platform_admins
    WHERE user_id = (SELECT auth.uid())
  ));
