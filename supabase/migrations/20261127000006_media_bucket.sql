-- Storage bucket for photos: public read; each user writes only inside a folder named with their user id.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('media', 'media', true, 5242880, ARRAY['image/jpeg','image/png','image/webp'])
ON CONFLICT (id) DO NOTHING;
DROP POLICY IF EXISTS media_public_read ON storage.objects;
CREATE POLICY media_public_read ON storage.objects FOR SELECT TO anon, authenticated USING (bucket_id = 'media');
DROP POLICY IF EXISTS media_owner_insert ON storage.objects;
CREATE POLICY media_owner_insert ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'media' AND (storage.foldername(name))[1] = (SELECT auth.uid())::text);
DROP POLICY IF EXISTS media_owner_update ON storage.objects;
CREATE POLICY media_owner_update ON storage.objects FOR UPDATE TO authenticated
  USING (bucket_id = 'media' AND (storage.foldername(name))[1] = (SELECT auth.uid())::text);
DROP POLICY IF EXISTS media_owner_delete ON storage.objects;
CREATE POLICY media_owner_delete ON storage.objects FOR DELETE TO authenticated
  USING (bucket_id = 'media' AND (storage.foldername(name))[1] = (SELECT auth.uid())::text);
