-- Admin: turn an existing client account into a merchant account with a store, same login and password.
-- Run as one migration, exactly as written. Adds one function and changes no data. Only a platform admin can call it.
CREATE OR REPLACE FUNCTION public.admin_convert_client_to_merchant(p_user_id uuid, p_business_name text, p_city text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_name text; v_phone text; v_mid uuid; v_type text; v_role text;
BEGIN
  IF NOT private.is_platform_admin() THEN RAISE EXCEPTION 'not allowed'; END IF;
  v_name := left(btrim(coalesce(p_business_name, '')), 100);
  IF v_name = '' THEN RAISE EXCEPTION 'name required'; END IF;
  SELECT p.account_type, p.role, coalesce(p.phone_private, p.phone) INTO v_type, v_role, v_phone FROM public.profiles p WHERE p.id = p_user_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'user not found'; END IF;
  IF v_type IS DISTINCT FROM 'client' OR v_role IS DISTINCT FROM 'client' THEN RAISE EXCEPTION 'only a client account can be converted'; END IF;
  IF EXISTS (SELECT 1 FROM public.platform_admins WHERE user_id = p_user_id) THEN RAISE EXCEPTION 'admin account'; END IF;
  UPDATE public.profiles SET account_type = 'merchant', role = 'merchant', approval_status = 'pending', updated_at = now() WHERE id = p_user_id;
  SELECT m.id INTO v_mid FROM public.merchants m WHERE m.user_id = p_user_id;
  IF v_mid IS NULL THEN
    INSERT INTO public.merchants (user_id, display_name, business_name, city, contact_phone, verification_status, is_available)
    VALUES (p_user_id, v_name, v_name, nullif(left(btrim(coalesce(p_city, '')), 80), ''), v_phone, 'approved', true)
    RETURNING id INTO v_mid;
  ELSE
    UPDATE public.merchants SET business_name = v_name, city = nullif(left(btrim(coalesce(p_city, '')), 80), ''), verification_status = 'approved', is_available = true WHERE id = v_mid;
  END IF;
  RETURN v_mid;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_convert_client_to_merchant(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_convert_client_to_merchant(uuid, text, text) TO authenticated;
