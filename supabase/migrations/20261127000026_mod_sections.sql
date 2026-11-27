-- Moderator sections (providers, ads and bazaars), permission-filtered. Run as one migration, exactly as written.
-- Adds only new objects. No existing data is changed.
CREATE TABLE IF NOT EXISTS public.moderator_settings (
  id boolean PRIMARY KEY DEFAULT true CHECK (id),
  can_approve boolean NOT NULL DEFAULT false
);
INSERT INTO public.moderator_settings (id, can_approve) VALUES (true, false) ON CONFLICT (id) DO NOTHING;
ALTER TABLE public.moderator_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.moderator_settings FROM anon, authenticated;

CREATE OR REPLACE FUNCTION private.mod_has_perm(p_perm text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$ SELECT EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = (SELECT auth.uid()) AND p.role = 'moderator' AND p.is_active AND p.permissions @> jsonb_build_array(p_perm)); $$;
REVOKE ALL ON FUNCTION private.mod_has_perm(text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.mod_can_approve()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$ SELECT coalesce((SELECT can_approve FROM public.moderator_settings WHERE id), false); $$;
REVOKE ALL ON FUNCTION private.mod_can_approve() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.mod_dashboard_flags()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  IF NOT private.is_moderator() THEN RAISE EXCEPTION 'not allowed'; END IF;
  RETURN jsonb_build_object('can_approve', private.mod_can_approve());
END;
$$;

CREATE OR REPLACE FUNCTION public.mod_list_users(p_type text DEFAULT 'service_provider')
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE r jsonb;
BEGIN
  IF NOT private.mod_has_perm('manage_providers') THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF p_type IS DISTINCT FROM 'service_provider' THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) INTO r FROM (
    SELECT p.id, p.email, p.full_name, p.city, p.district, p.country_name, p.specialty,
           p.approval_status, p.created_at,
           sp.id AS provider_id, sp.verification_status AS provider_status
    FROM public.profiles p
    JOIN public.service_providers sp ON sp.user_id = p.id
    WHERE p.account_type = 'service_provider'
    ORDER BY p.created_at DESC LIMIT 1000
  ) t;
  RETURN r;
END;
$$;

CREATE OR REPLACE FUNCTION public.mod_list_ads()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE r jsonb;
BEGIN
  IF NOT private.mod_has_perm('manage_ads') THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) INTO r FROM (
    SELECT a.id, a.title, a.placement, a.status, a.created_at, ap.full_name AS advertiser_name
    FROM public.advertisements a
    LEFT JOIN public.profiles ap ON ap.id = a.advertiser_user_id
    ORDER BY a.created_at DESC LIMIT 1000
  ) t;
  RETURN r;
END;
$$;

CREATE OR REPLACE FUNCTION public.mod_list_bazaars()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE r jsonb;
BEGIN
  IF NOT private.mod_has_perm('manage_ads') THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) INTO r FROM (
    SELECT z.name, z.venue, z.city, z.starts_at, z.ends_at, z.status, z.created_at, op.full_name AS organizer_name
    FROM public.bazaars z
    LEFT JOIN public.profiles op ON op.id = z.organizer_user_id
    ORDER BY z.created_at DESC LIMIT 1000
  ) t;
  RETURN r;
END;
$$;

CREATE OR REPLACE FUNCTION public.mod_set_provider_status(p_provider_id uuid, p_status text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  IF NOT (private.mod_has_perm('manage_providers') AND private.mod_can_approve()) THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF p_status NOT IN ('pending','approved','rejected') THEN RAISE EXCEPTION 'invalid status'; END IF;
  UPDATE public.service_providers SET verification_status = p_status WHERE id = p_provider_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'provider not found'; END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.mod_set_ad_status(p_ad_id uuid, p_status text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  IF NOT (private.mod_has_perm('manage_ads') AND private.mod_can_approve()) THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF p_status NOT IN ('pending','active','paused','rejected') THEN RAISE EXCEPTION 'invalid status'; END IF;
  UPDATE public.advertisements SET status = p_status WHERE id = p_ad_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'ad not found'; END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.mod_dashboard_flags(), public.mod_list_users(text), public.mod_list_ads(), public.mod_list_bazaars(),
  public.mod_set_provider_status(uuid, text), public.mod_set_ad_status(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mod_dashboard_flags(), public.mod_list_users(text), public.mod_list_ads(), public.mod_list_bazaars(),
  public.mod_set_provider_status(uuid, text), public.mod_set_ad_status(uuid, text) TO authenticated;
