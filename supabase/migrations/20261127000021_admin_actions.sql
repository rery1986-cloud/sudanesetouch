-- Admin approvals: expose provider/merchant/ad ids in admin lists. Run as one migration, exactly as written.
-- Approve/reject uses the existing admin-only RPCs: set_provider_status, set_merchant_status, set_ad_status.
CREATE OR REPLACE FUNCTION public.admin_list_users(p_type text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE r jsonb;
BEGIN
  IF NOT private.is_platform_admin() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) INTO r FROM (
    SELECT p.id, p.email, p.full_name, p.account_type,
           coalesce(p.phone_private, p.phone) AS phone, p.city, p.district, p.country_name, p.specialty,
           p.approval_status, p.account_status, p.registration_source, p.created_at, p.last_login_at,
           u.last_sign_in_at,
           sp.id AS provider_id, sp.verification_status AS provider_status, sp.average_rating AS rating,
           m.id AS merchant_id,
           coalesce(m.business_name, m.display_name) AS merchant_name, m.verification_status AS merchant_status,
           (SELECT count(*) FROM public.bookings b JOIN public.customers c ON c.id = b.customer_id WHERE c.user_id = p.id) AS bookings_as_client,
           (SELECT count(*) FROM public.bookings b WHERE b.provider_id = sp.id) AS bookings_as_provider
    FROM public.profiles p
    LEFT JOIN auth.users u ON u.id = p.id
    LEFT JOIN public.service_providers sp ON sp.user_id = p.id
    LEFT JOIN public.merchants m ON m.user_id = p.id
    WHERE p_type IS NULL OR p.account_type = p_type
    ORDER BY p.created_at DESC LIMIT 1000
  ) t;
  RETURN r;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_list_ads()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE r jsonb;
BEGIN
  IF NOT private.is_platform_admin() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) INTO r FROM (
    SELECT a.id, a.title, a.placement, a.budget, a.status, a.impressions, a.clicks, a.created_at,
           ap.full_name AS advertiser_name
    FROM public.advertisements a
    LEFT JOIN public.profiles ap ON ap.id = a.advertiser_user_id
    ORDER BY a.created_at DESC LIMIT 1000
  ) t;
  RETURN r;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_list_users(text), public.admin_list_ads() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_users(text), public.admin_list_ads() TO authenticated;
