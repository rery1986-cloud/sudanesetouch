-- 000014 admin overview. Read-only functions. Admin only. No data changes.
CREATE OR REPLACE FUNCTION public.admin_overview()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE r jsonb;
BEGIN
  IF NOT private.is_platform_admin() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT jsonb_build_object(
    'generated_at', now(),
    'users_total', (SELECT count(*) FROM public.profiles),
    'clients_total', (SELECT count(*) FROM public.profiles WHERE account_type = 'client'),
    'providers_total', (SELECT count(*) FROM public.profiles WHERE account_type = 'service_provider'),
    'merchants_total', (SELECT count(*) FROM public.profiles WHERE account_type = 'merchant'),
    'providers_pending', (SELECT count(*) FROM public.service_providers WHERE verification_status = 'pending'),
    'merchants_pending', (SELECT count(*) FROM public.merchants WHERE verification_status = 'pending'),
    'signups_24h', (SELECT count(*) FROM public.profiles WHERE created_at > now() - interval '24 hours'),
    'signups_7d', (SELECT count(*) FROM public.profiles WHERE created_at > now() - interval '7 days'),
    'signups_30d', (SELECT count(*) FROM public.profiles WHERE created_at > now() - interval '30 days'),
    'online_15m', (SELECT count(*) FROM auth.users WHERE last_sign_in_at > now() - interval '15 minutes'),
    'active_24h', (SELECT count(*) FROM auth.users WHERE last_sign_in_at > now() - interval '24 hours'),
    'bookings_total', (SELECT count(*) FROM public.bookings),
    'bookings_by_status', (SELECT coalesce(jsonb_object_agg(s.status, s.c), '{}'::jsonb) FROM (SELECT status, count(*) AS c FROM public.bookings GROUP BY status) s),
    'ads_by_status', (SELECT coalesce(jsonb_object_agg(s.status, s.c), '{}'::jsonb) FROM (SELECT status, count(*) AS c FROM public.advertisements GROUP BY status) s),
    'bazaars_by_status', (SELECT coalesce(jsonb_object_agg(s.status, s.c), '{}'::jsonb) FROM (SELECT status, count(*) AS c FROM public.bazaars GROUP BY status) s),
    'income_by_currency', (SELECT coalesce(jsonb_agg(jsonb_build_object('currency', s.currency, 'total', s.t, 'count', s.c)), '[]'::jsonb)
        FROM (SELECT currency, sum(total_amount) AS t, count(*) AS c FROM public.bookings WHERE status = 'completed' GROUP BY currency) s),
    'income_by_category', (SELECT coalesce(jsonb_agg(jsonb_build_object('category', s.cat, 'currency', s.currency, 'total', s.t, 'count', s.c)), '[]'::jsonb)
        FROM (SELECT coalesce(o.category, 'غير محدد') AS cat, b.currency, sum(b.total_amount) AS t, count(*) AS c
              FROM public.bookings b LEFT JOIN public.service_offers o ON o.id = b.offer_id
              WHERE b.status = 'completed' GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 20) s),
    'commission_by_currency', (SELECT coalesce(jsonb_agg(jsonb_build_object('currency', s.currency, 'gross', s.g, 'commission', s.cm, 'count', s.c)), '[]'::jsonb)
        FROM (SELECT currency, sum(gross_amount) AS g, sum(platform_commission) AS cm, count(*) AS c FROM public.revenues GROUP BY currency) s),
    'signups_daily', (SELECT coalesce(jsonb_agg(jsonb_build_object('day', s.d, 'n', s.n) ORDER BY s.d), '[]'::jsonb)
        FROM (SELECT created_at::date AS d, count(*) AS n FROM public.profiles WHERE created_at > now() - interval '14 days' GROUP BY 1) s)
  ) INTO r;
  RETURN r;
END;
$$;

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
           sp.verification_status AS provider_status, sp.average_rating AS rating,
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

CREATE OR REPLACE FUNCTION public.admin_list_bookings()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE r jsonb;
BEGIN
  IF NOT private.is_platform_admin() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) INTO r FROM (
    SELECT b.booking_number, b.status, b.scheduled_at, b.total_amount, b.currency, b.created_at,
           cp.full_name AS client_name, cp.email AS client_email,
           sp.display_name AS provider_name, o.title AS service, o.category
    FROM public.bookings b
    LEFT JOIN public.customers c ON c.id = b.customer_id
    LEFT JOIN public.profiles cp ON cp.id = c.user_id
    LEFT JOIN public.service_providers sp ON sp.id = b.provider_id
    LEFT JOIN public.service_offers o ON o.id = b.offer_id
    ORDER BY b.created_at DESC LIMIT 1000
  ) t;
  RETURN r;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_list_revenues()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE r jsonb;
BEGIN
  IF NOT private.is_platform_admin() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) INTO r FROM (
    SELECT rv.gross_amount, rv.platform_commission, rv.provider_net_amount, rv.currency, rv.payment_status,
           rv.payment_method, rv.paid_at, rv.created_at, b.booking_number, sp.display_name AS provider_name
    FROM public.revenues rv
    LEFT JOIN public.bookings b ON b.id = rv.booking_id
    LEFT JOIN public.service_providers sp ON sp.id = rv.provider_id
    ORDER BY rv.created_at DESC LIMIT 1000
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
    SELECT a.title, a.placement, a.budget, a.status, a.impressions, a.clicks, a.created_at,
           ap.full_name AS advertiser_name
    FROM public.advertisements a
    LEFT JOIN public.profiles ap ON ap.id = a.advertiser_user_id
    ORDER BY a.created_at DESC LIMIT 1000
  ) t;
  RETURN r;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_list_bazaars()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE r jsonb;
BEGIN
  IF NOT private.is_platform_admin() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) INTO r FROM (
    SELECT z.name, z.venue, z.city, z.starts_at, z.ends_at, z.status, z.created_at,
           op.full_name AS organizer_name
    FROM public.bazaars z
    LEFT JOIN public.profiles op ON op.id = z.organizer_user_id
    ORDER BY z.created_at DESC LIMIT 1000
  ) t;
  RETURN r;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_overview(), public.admin_list_users(text), public.admin_list_bookings(),
  public.admin_list_revenues(), public.admin_list_ads(), public.admin_list_bazaars() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_overview(), public.admin_list_users(text), public.admin_list_bookings(),
  public.admin_list_revenues(), public.admin_list_ads(), public.admin_list_bazaars() TO authenticated;
