-- 000019 visitor visibility fix. Visitors (anon) could not read portfolio_items: the old policy looked at service_providers.user_id, which anon cannot read. Split into one policy per role.
DROP POLICY IF EXISTS portfolio_public_select ON public.portfolio_items;
CREATE POLICY portfolio_public_select ON public.portfolio_items FOR SELECT TO anon
  USING (EXISTS (SELECT 1 FROM public.service_providers sp WHERE sp.id = provider_id AND sp.verification_status = 'approved'));
DROP POLICY IF EXISTS portfolio_auth_select ON public.portfolio_items;
CREATE POLICY portfolio_auth_select ON public.portfolio_items FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.service_providers sp WHERE sp.id = provider_id AND sp.verification_status = 'approved')
         OR EXISTS (SELECT 1 FROM public.service_providers sp WHERE sp.id = provider_id AND sp.user_id = (SELECT auth.uid()))
         OR private.is_platform_admin());
