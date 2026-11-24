-- Secure, one-time Super Admin bootstrap for the project owner.
-- This migration does not modify existing customer, merchant, product, or order data.

CREATE TABLE IF NOT EXISTS public.platform_admin_profiles (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name text NOT NULL,
  phone text,
  username text,
  details text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.platform_admin_profiles ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.platform_admin_profiles FROM anon, authenticated;
GRANT SELECT ON public.platform_admin_profiles TO authenticated;

DROP POLICY IF EXISTS platform_admin_profiles_select_self ON public.platform_admin_profiles;
CREATE POLICY platform_admin_profiles_select_self
  ON public.platform_admin_profiles
  FOR SELECT TO authenticated
  USING (
    user_id = (SELECT auth.uid())
    AND EXISTS (
      SELECT 1 FROM public.platform_admins
      WHERE user_id = (SELECT auth.uid())
    )
  );

CREATE OR REPLACE FUNCTION public.claim_first_super_admin(
  p_full_name text,
  p_phone text DEFAULT NULL,
  p_username text DEFAULT NULL,
  p_details text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_email text;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication required';
  END IF;

  SELECT lower(email)
  INTO v_email
  FROM auth.users
  WHERE id = v_user_id;

  IF v_email IS NULL OR v_email <> 'rery1986@gmail.com' THEN
    RAISE EXCEPTION 'not authorized to create the first Super Admin';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM auth.users
    WHERE id = v_user_id
      AND email_confirmed_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'email confirmation is required';
  END IF;

  IF EXISTS (SELECT 1 FROM public.platform_admins) THEN
    RAISE EXCEPTION 'a Super Admin already exists';
  END IF;

  IF NULLIF(btrim(p_full_name), '') IS NULL THEN
    RAISE EXCEPTION 'full name is required';
  END IF;

  INSERT INTO public.platform_admin_profiles (
    user_id, full_name, phone, username, details, updated_at
  ) VALUES (
    v_user_id,
    btrim(p_full_name),
    NULLIF(btrim(COALESCE(p_phone, '')), ''),
    NULLIF(btrim(COALESCE(p_username, '')), ''),
    NULLIF(btrim(COALESCE(p_details, '')), ''),
    now()
  )
  ON CONFLICT (user_id) DO UPDATE SET
    full_name = EXCLUDED.full_name,
    phone = EXCLUDED.phone,
    username = EXCLUDED.username,
    details = EXCLUDED.details,
    updated_at = now();

  INSERT INTO public.platform_admins (user_id, email)
  VALUES (v_user_id, v_email)
  ON CONFLICT (user_id) DO UPDATE SET email = EXCLUDED.email;

  UPDATE auth.users
  SET raw_app_meta_data = COALESCE(raw_app_meta_data, '{}'::jsonb)
      || jsonb_build_object('role', 'super_admin')
  WHERE id = v_user_id;

  RETURN jsonb_build_object(
    'success', true,
    'user_id', v_user_id,
    'email', v_email,
    'role', 'super_admin'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.claim_first_super_admin(text,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.claim_first_super_admin(text,text,text,text) TO authenticated;

-- Prevent public or ordinary authenticated users from inserting admin records.
REVOKE INSERT, UPDATE, DELETE ON public.platform_admins FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.platform_admin_profiles FROM anon, authenticated;
