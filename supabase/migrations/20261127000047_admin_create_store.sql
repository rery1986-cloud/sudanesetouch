-- Admin-created stores: a store can exist without an owner account until the merchant registers, then the admin links it by email.
-- Run as one migration, exactly as written. Changes no existing data. Only a platform admin can call the new functions.
ALTER TABLE public.merchants ALTER COLUMN user_id DROP NOT NULL;
ALTER TABLE public.merchants ADD COLUMN IF NOT EXISTS managed_by_admin boolean NOT NULL DEFAULT false;
GRANT SELECT (managed_by_admin) ON public.merchants TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_create_store(p_fields jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_name text; v_id uuid; v_status text;
BEGIN
  IF NOT private.is_platform_admin() THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF p_fields IS NULL OR jsonb_typeof(p_fields) <> 'object' THEN RAISE EXCEPTION 'bad fields'; END IF;
  v_name := left(btrim(coalesce(p_fields->>'business_name', '')), 100);
  IF v_name = '' THEN RAISE EXCEPTION 'name required'; END IF;
  v_status := CASE WHEN p_fields->>'verification_status' = 'pending' THEN 'pending' ELSE 'approved' END;
  INSERT INTO public.merchants (user_id, display_name, business_name, city, district, description, contact_phone, store_email, social_links, avatar_url, cover_url, qr_url, verification_status, is_available, managed_by_admin)
  VALUES (NULL, v_name, v_name,
    left(btrim(coalesce(p_fields->>'city', '')), 80),
    left(btrim(coalesce(p_fields->>'district', '')), 80),
    left(btrim(coalesce(p_fields->>'description', '')), 600),
    nullif(left(btrim(coalesce(p_fields->>'contact_phone', '')), 30), ''),
    left(btrim(coalesce(p_fields->>'store_email', '')), 120),
    CASE WHEN jsonb_typeof(p_fields->'social_links') = 'object' THEN p_fields->'social_links' ELSE '{}'::jsonb END,
    nullif(btrim(coalesce(p_fields->>'avatar_url', '')), ''),
    nullif(btrim(coalesce(p_fields->>'cover_url', '')), ''),
    nullif(btrim(coalesce(p_fields->>'qr_url', '')), ''),
    v_status, true, true)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_update_merchant(p_merchant_id uuid, p_fields jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_name text;
BEGIN
  IF NOT private.is_platform_admin() THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF p_fields IS NULL OR jsonb_typeof(p_fields) <> 'object' THEN RAISE EXCEPTION 'bad fields'; END IF;
  IF jsonb_exists(p_fields, 'business_name') THEN
    v_name := left(btrim(coalesce(p_fields->>'business_name', '')), 100);
    IF v_name = '' THEN RAISE EXCEPTION 'name required'; END IF;
  END IF;
  UPDATE public.merchants m SET
    business_name = coalesce(v_name, m.business_name),
    city = CASE WHEN jsonb_exists(p_fields, 'city') THEN left(btrim(coalesce(p_fields->>'city', '')), 80) ELSE m.city END,
    district = CASE WHEN jsonb_exists(p_fields, 'district') THEN left(btrim(coalesce(p_fields->>'district', '')), 80) ELSE m.district END,
    description = CASE WHEN jsonb_exists(p_fields, 'description') THEN left(btrim(coalesce(p_fields->>'description', '')), 600) ELSE m.description END,
    contact_phone = CASE WHEN jsonb_exists(p_fields, 'contact_phone') THEN nullif(left(btrim(coalesce(p_fields->>'contact_phone', '')), 30), '') ELSE m.contact_phone END,
    store_email = CASE WHEN jsonb_exists(p_fields, 'store_email') THEN left(btrim(coalesce(p_fields->>'store_email', '')), 120) ELSE m.store_email END,
    social_links = CASE WHEN jsonb_exists(p_fields, 'social_links') AND jsonb_typeof(p_fields->'social_links') = 'object' THEN p_fields->'social_links' ELSE m.social_links END,
    avatar_url = CASE WHEN jsonb_exists(p_fields, 'avatar_url') THEN nullif(btrim(coalesce(p_fields->>'avatar_url', '')), '') ELSE m.avatar_url END,
    cover_url = CASE WHEN jsonb_exists(p_fields, 'cover_url') THEN nullif(btrim(coalesce(p_fields->>'cover_url', '')), '') ELSE m.cover_url END,
    qr_url = CASE WHEN jsonb_exists(p_fields, 'qr_url') THEN nullif(btrim(coalesce(p_fields->>'qr_url', '')), '') ELSE m.qr_url END
  WHERE m.id = p_merchant_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'merchant not found'; END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_add_product(p_merchant_id uuid, p_fields jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_name text; v_price numeric; v_id uuid;
BEGIN
  IF NOT private.is_platform_admin() THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF p_fields IS NULL OR jsonb_typeof(p_fields) <> 'object' THEN RAISE EXCEPTION 'bad fields'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.merchants WHERE id = p_merchant_id) THEN RAISE EXCEPTION 'merchant not found'; END IF;
  v_name := left(btrim(coalesce(p_fields->>'name', '')), 150);
  IF v_name = '' THEN RAISE EXCEPTION 'name required'; END IF;
  v_price := (p_fields->>'price')::numeric;
  IF v_price IS NULL OR v_price < 0 THEN RAISE EXCEPTION 'bad price'; END IF;
  INSERT INTO public.products (merchant_id, name, description, category, price, currency, image_url, status)
  VALUES (p_merchant_id, v_name, left(coalesce(p_fields->>'description', ''), 1000), left(coalesce(p_fields->>'category', ''), 60), v_price,
    coalesce(nullif(left(btrim(coalesce(p_fields->>'currency', '')), 10), ''), 'SAR'), nullif(btrim(coalesce(p_fields->>'image_url', '')), ''), 'published')
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_link_store(p_merchant_id uuid, p_email text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_uid uuid; v_old uuid;
BEGIN
  IF NOT private.is_platform_admin() THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.merchants WHERE id = p_merchant_id AND user_id IS NULL) THEN RAISE EXCEPTION 'store not found or already linked'; END IF;
  SELECT p.id INTO v_uid FROM public.profiles p WHERE lower(p.email) = lower(btrim(p_email)) AND p.account_type = 'merchant' LIMIT 1;
  IF v_uid IS NULL THEN RAISE EXCEPTION 'merchant account not found'; END IF;
  SELECT m.id INTO v_old FROM public.merchants m WHERE m.user_id = v_uid;
  IF v_old IS NOT NULL THEN
    IF EXISTS (SELECT 1 FROM public.products WHERE merchant_id = v_old) THEN RAISE EXCEPTION 'account already has a store with products'; END IF;
    DELETE FROM public.merchants WHERE id = v_old;
  END IF;
  UPDATE public.merchants SET user_id = v_uid WHERE id = p_merchant_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_delete_store(p_merchant_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  IF NOT private.is_platform_admin() THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.merchants WHERE id = p_merchant_id AND user_id IS NULL AND managed_by_admin) THEN RAISE EXCEPTION 'only an unlinked admin-made store can be deleted here'; END IF;
  DELETE FROM public.products WHERE merchant_id = p_merchant_id;
  DELETE FROM public.merchants WHERE id = p_merchant_id;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_create_store(jsonb), public.admin_update_merchant(uuid, jsonb), public.admin_add_product(uuid, jsonb), public.admin_link_store(uuid, text), public.admin_delete_store(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_create_store(jsonb), public.admin_update_merchant(uuid, jsonb), public.admin_add_product(uuid, jsonb), public.admin_link_store(uuid, text), public.admin_delete_store(uuid) TO authenticated;
