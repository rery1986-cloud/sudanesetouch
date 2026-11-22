DROP POLICY IF EXISTS platform_admins_select_self ON public.platform_admins;
CREATE POLICY platform_admins_select_self
  ON public.platform_admins
  FOR SELECT
  TO authenticated
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS app_state_admin_select ON public.app_state;
CREATE POLICY app_state_admin_select
  ON public.app_state
  FOR SELECT
  TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.platform_admins
    WHERE user_id = (SELECT auth.uid())
  ));

DROP POLICY IF EXISTS app_state_admin_insert ON public.app_state;
CREATE POLICY app_state_admin_insert
  ON public.app_state
  FOR INSERT
  TO authenticated
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.platform_admins
    WHERE user_id = (SELECT auth.uid())
  ));

DROP POLICY IF EXISTS app_state_admin_update ON public.app_state;
CREATE POLICY app_state_admin_update
  ON public.app_state
  FOR UPDATE
  TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.platform_admins
    WHERE user_id = (SELECT auth.uid())
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.platform_admins
    WHERE user_id = (SELECT auth.uid())
  ));
