-- Fix: anon cannot read merchants.user_id, so split the products select policy by role.
DROP POLICY IF EXISTS products_public_select ON public.products;
DROP POLICY IF EXISTS products_anon_select ON public.products;
CREATE POLICY products_anon_select ON public.products FOR SELECT TO anon
  USING (status = 'published' AND EXISTS (SELECT 1 FROM public.merchants m WHERE m.id = merchant_id AND m.verification_status = 'approved' AND m.is_available));
DROP POLICY IF EXISTS products_auth_select ON public.products;
CREATE POLICY products_auth_select ON public.products FOR SELECT TO authenticated
  USING (
    (status = 'published' AND EXISTS (SELECT 1 FROM public.merchants m WHERE m.id = merchant_id AND m.verification_status = 'approved' AND m.is_available))
    OR EXISTS (SELECT 1 FROM public.merchants m WHERE m.id = merchant_id AND m.user_id = (SELECT auth.uid()))
    OR private.is_platform_admin()
  );
