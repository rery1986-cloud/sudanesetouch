-- Admin: edit a store profile (name, city, description, links, images). Run as one migration, exactly as written.
-- Adds one function. Changes no data. Only a platform admin can call it. Products are edited directly (existing admin policies already allow it).
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
    store_email = CASE WHEN jsonb_exists(p_fields, 'store_email') THEN left(btrim(coalesce(p_fields->>'store_email', '')), 120) ELSE m.store_email END,
    social_links = CASE WHEN jsonb_exists(p_fields, 'social_links') AND jsonb_typeof(p_fields->'social_links') = 'object' THEN p_fields->'social_links' ELSE m.social_links END,
    avatar_url = CASE WHEN jsonb_exists(p_fields, 'avatar_url') THEN nullif(btrim(coalesce(p_fields->>'avatar_url', '')), '') ELSE m.avatar_url END,
    cover_url = CASE WHEN jsonb_exists(p_fields, 'cover_url') THEN nullif(btrim(coalesce(p_fields->>'cover_url', '')), '') ELSE m.cover_url END,
    qr_url = CASE WHEN jsonb_exists(p_fields, 'qr_url') THEN nullif(btrim(coalesce(p_fields->>'qr_url', '')), '') ELSE m.qr_url END
  WHERE m.id = p_merchant_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'merchant not found'; END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_update_merchant(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_update_merchant(uuid, jsonb) TO authenticated;
