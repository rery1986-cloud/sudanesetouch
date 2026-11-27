-- Stage 2 merchant products. Run as one migration, exactly as written.
CREATE TABLE IF NOT EXISTS public.products (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  merchant_id uuid NOT NULL REFERENCES public.merchants(id) ON DELETE CASCADE,
  name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 150),
  description text,
  category text,
  price numeric(12,2) NOT NULL CHECK (price >= 0),
  currency text NOT NULL DEFAULT 'SAR',
  image_url text,
  status text NOT NULL DEFAULT 'published' CHECK (status IN ('draft','published','archived')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS products_merchant_idx ON public.products (merchant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS products_status_idx ON public.products (status, created_at DESC);
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.products FROM anon, authenticated;
GRANT SELECT ON public.products TO anon, authenticated;
GRANT INSERT (merchant_id, name, description, category, price, currency, image_url, status) ON public.products TO authenticated;
GRANT UPDATE (name, description, category, price, currency, image_url, status) ON public.products TO authenticated;
GRANT DELETE ON public.products TO authenticated;

DROP POLICY IF EXISTS products_public_select ON public.products;
CREATE POLICY products_public_select ON public.products FOR SELECT TO anon, authenticated
  USING (
    (status = 'published' AND EXISTS (SELECT 1 FROM public.merchants m WHERE m.id = merchant_id AND m.verification_status = 'approved' AND m.is_available))
    OR EXISTS (SELECT 1 FROM public.merchants m WHERE m.id = merchant_id AND m.user_id = (SELECT auth.uid()))
    OR private.is_platform_admin()
  );
DROP POLICY IF EXISTS products_owner_insert ON public.products;
CREATE POLICY products_owner_insert ON public.products FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM public.merchants m WHERE m.id = merchant_id AND m.user_id = (SELECT auth.uid())));
DROP POLICY IF EXISTS products_owner_update ON public.products;
CREATE POLICY products_owner_update ON public.products FOR UPDATE TO authenticated
  USING (EXISTS (SELECT 1 FROM public.merchants m WHERE m.id = merchant_id AND m.user_id = (SELECT auth.uid())) OR private.is_platform_admin())
  WITH CHECK (EXISTS (SELECT 1 FROM public.merchants m WHERE m.id = merchant_id AND m.user_id = (SELECT auth.uid())) OR private.is_platform_admin());
DROP POLICY IF EXISTS products_owner_delete ON public.products;
CREATE POLICY products_owner_delete ON public.products FOR DELETE TO authenticated
  USING (EXISTS (SELECT 1 FROM public.merchants m WHERE m.id = merchant_id AND m.user_id = (SELECT auth.uid())) OR private.is_platform_admin());

CREATE OR REPLACE FUNCTION private.touch_products_updated_at()
RETURNS trigger LANGUAGE plpgsql SET search_path = ''
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS touch_products ON public.products;
CREATE TRIGGER touch_products BEFORE UPDATE ON public.products
  FOR EACH ROW EXECUTE FUNCTION private.touch_products_updated_at();

-- the merchant's own row (creates a pending one if signup did not), plus profile sync
CREATE OR REPLACE FUNCTION public.ensure_my_merchant(p_business_name text, p_city text)
RETURNS TABLE (id uuid, business_name text, verification_status text, is_available boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE actor uuid := (SELECT auth.uid()); mid uuid;
BEGIN
  IF actor IS NULL THEN RAISE EXCEPTION 'login required'; END IF;
  SELECT m.id INTO mid FROM public.merchants m WHERE m.user_id = actor;
  IF mid IS NULL THEN
    INSERT INTO public.merchants (user_id, display_name, business_name, city, verification_status)
    VALUES (actor, coalesce(nullif(p_business_name, ''), 'تاجرة'), nullif(p_business_name, ''), nullif(p_city, ''), 'pending')
    RETURNING public.merchants.id INTO mid;
  ELSE
    UPDATE public.merchants m SET business_name = coalesce(nullif(p_business_name, ''), m.business_name),
      city = coalesce(nullif(p_city, ''), m.city) WHERE m.id = mid;
  END IF;
  RETURN QUERY SELECT m.id, m.business_name, m.verification_status, m.is_available FROM public.merchants m WHERE m.id = mid;
END;
$$;

-- phone: owner, admin, or any signed-in user once the merchant is approved
CREATE OR REPLACE FUNCTION public.get_merchant_contact(p_merchant_id uuid)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE actor uuid := (SELECT auth.uid()); phone text;
BEGIN
  IF actor IS NULL THEN RETURN NULL; END IF;
  SELECT m.contact_phone INTO phone FROM public.merchants m
  WHERE m.id = p_merchant_id AND (m.user_id = actor OR private.is_platform_admin()
    OR (m.verification_status = 'approved' AND m.is_available));
  RETURN phone;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.ensure_my_merchant(text, text), public.get_merchant_contact(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ensure_my_merchant(text, text), public.get_merchant_contact(uuid) TO authenticated;
