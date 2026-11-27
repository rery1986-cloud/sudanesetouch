-- Stage 2 ads + video. Run as one migration, exactly as written.
-- 1) rich ad fields (type, owner name, subtitle, cta, items, video...) live in one jsonb column
ALTER TABLE public.advertisements ADD COLUMN IF NOT EXISTS meta jsonb NOT NULL DEFAULT '{}'::jsonb;

-- 2) reset the access rules for ads to a known, safe set
ALTER TABLE public.advertisements ENABLE ROW LEVEL SECURITY;
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT policyname FROM pg_policies WHERE schemaname = 'public' AND tablename = 'advertisements' LOOP
    EXECUTE format('DROP POLICY %I ON public.advertisements', r.policyname);
  END LOOP;
END
$$;
REVOKE ALL ON public.advertisements FROM anon, authenticated;
GRANT SELECT (id, title, description, image_url, target_url, placement, status, starts_at, ends_at, created_at, meta)
  ON public.advertisements TO anon;
GRANT SELECT (id, advertiser_user_id, title, description, image_url, target_url, placement, status, starts_at, ends_at, created_at, updated_at, meta, budget, impressions, clicks)
  ON public.advertisements TO authenticated;
GRANT INSERT (title, description, image_url, target_url, placement, status, starts_at, ends_at, meta)
  ON public.advertisements TO authenticated;
GRANT UPDATE (title, description, image_url, target_url, placement, status, starts_at, ends_at, meta)
  ON public.advertisements TO authenticated;
GRANT DELETE ON public.advertisements TO authenticated;

CREATE POLICY ads_anon_select ON public.advertisements FOR SELECT TO anon
  USING (status = 'active' AND (starts_at IS NULL OR starts_at <= now()) AND (ends_at IS NULL OR ends_at >= now()));
CREATE POLICY ads_auth_select ON public.advertisements FOR SELECT TO authenticated
  USING (
    (status = 'active' AND (starts_at IS NULL OR starts_at <= now()) AND (ends_at IS NULL OR ends_at >= now()))
    OR advertiser_user_id = (SELECT auth.uid())
    OR private.is_platform_admin()
  );
CREATE POLICY ads_auth_insert ON public.advertisements FOR INSERT TO authenticated
  WITH CHECK (advertiser_user_id = (SELECT auth.uid()) OR private.is_platform_admin());
CREATE POLICY ads_auth_update ON public.advertisements FOR UPDATE TO authenticated
  USING (advertiser_user_id = (SELECT auth.uid()) OR private.is_platform_admin())
  WITH CHECK (advertiser_user_id = (SELECT auth.uid()) OR private.is_platform_admin());
CREATE POLICY ads_auth_delete ON public.advertisements FOR DELETE TO authenticated
  USING (advertiser_user_id = (SELECT auth.uid()) OR private.is_platform_admin());

-- 3) media bucket: allow short videos (mp4/webm up to 50 MB) next to images
UPDATE storage.buckets
SET file_size_limit = 52428800,
    allowed_mime_types = ARRAY['image/jpeg','image/png','image/webp','video/mp4','video/webm']
WHERE id = 'media';

-- 4) portfolio items can later be a video
ALTER TABLE public.portfolio_items ADD COLUMN IF NOT EXISTS media_type text NOT NULL DEFAULT 'image';
ALTER TABLE public.portfolio_items DROP CONSTRAINT IF EXISTS portfolio_items_media_type_chk;
ALTER TABLE public.portfolio_items ADD CONSTRAINT portfolio_items_media_type_chk CHECK (media_type IN ('image','video'));
GRANT SELECT (media_type) ON public.portfolio_items TO anon, authenticated;
GRANT INSERT (media_type) ON public.portfolio_items TO authenticated;
