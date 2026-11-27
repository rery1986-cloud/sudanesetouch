CREATE TABLE IF NOT EXISTS public.profiles (
  id uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  role text NOT NULL CHECK (role IN ('client', 'provider', 'merchant')),
  full_name text NOT NULL,
  phone_private text NOT NULL,
  country text,
  city text,
  district text,
  specialty text,
  store_name text,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.profiles FROM anon, authenticated;
GRANT SELECT ON public.profiles TO authenticated;

DROP POLICY IF EXISTS profiles_select_self ON public.profiles;
CREATE POLICY profiles_select_self
  ON public.profiles
  FOR SELECT
  TO authenticated
  USING (id = (SELECT auth.uid()));

CREATE OR REPLACE FUNCTION public.handle_new_public_profile()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  metadata jsonb := coalesce(NEW.raw_user_meta_data, '{}'::jsonb);
  requested_role text := metadata ->> 'role';
BEGIN
  IF requested_role NOT IN ('client', 'provider', 'merchant') THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.profiles (
    id, role, full_name, phone_private, country, city, district, specialty, store_name
  ) VALUES (
    NEW.id,
    requested_role,
    coalesce(nullif(metadata ->> 'full_name', ''), 'مستخدم جديد'),
    coalesce(metadata ->> 'phone', ''),
    nullif(metadata ->> 'country', ''),
    nullif(metadata ->> 'city', ''),
    nullif(metadata ->> 'district', ''),
    nullif(metadata ->> 'specialty', ''),
    nullif(metadata ->> 'store_name', '')
  )
  ON CONFLICT (id) DO UPDATE SET
    role = EXCLUDED.role,
    full_name = EXCLUDED.full_name,
    phone_private = EXCLUDED.phone_private,
    country = EXCLUDED.country,
    city = EXCLUDED.city,
    district = EXCLUDED.district,
    specialty = EXCLUDED.specialty,
    store_name = EXCLUDED.store_name,
    updated_at = now();

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.handle_new_public_profile() FROM PUBLIC;
DROP TRIGGER IF EXISTS on_auth_user_created_public_profile ON auth.users;
CREATE TRIGGER on_auth_user_created_public_profile
  AFTER INSERT OR UPDATE OF raw_user_meta_data ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_public_profile();
