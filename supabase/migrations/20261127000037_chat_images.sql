-- Photo attachments in chat. Run as one migration, exactly as written.
-- Adds messages.image_path, a PRIVATE storage bucket "chat-images" (jpeg/png/webp, max 3 MB),
-- and policies so only the two chat participants (and the admin, read only) can upload/see a conversation's photos.
-- Moderators and other users cannot read them. No existing data is changed.
ALTER TABLE public.messages ADD COLUMN IF NOT EXISTS image_path text;
ALTER TABLE public.messages DROP CONSTRAINT IF EXISTS messages_body_check;
ALTER TABLE public.messages ADD CONSTRAINT messages_body_check CHECK (char_length(body) <= 2000);
ALTER TABLE public.messages DROP CONSTRAINT IF EXISTS messages_body_or_image;
ALTER TABLE public.messages ADD CONSTRAINT messages_body_or_image CHECK (char_length(body) >= 1 OR image_path IS NOT NULL);
GRANT INSERT (conversation_id, body, image_path) ON public.messages TO authenticated;

CREATE OR REPLACE FUNCTION private.messages_before_insert()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  NEW.sender_id := (SELECT auth.uid());
  NEW.read_at := NULL;
  NEW.created_at := now();
  IF NEW.image_path IS NOT NULL AND left(NEW.image_path, 37) <> NEW.conversation_id::text || '/' THEN
    RAISE EXCEPTION 'invalid image path';
  END IF;
  RETURN NEW;
END;
$$;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('chat-images', 'chat-images', false, 3145728, ARRAY['image/jpeg','image/png','image/webp'])
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS chatimg_participant_insert ON storage.objects;
CREATE POLICY chatimg_participant_insert ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'chat-images' AND EXISTS (SELECT 1 FROM public.conversations c
    WHERE c.id::text = (storage.foldername(name))[1]
      AND ((SELECT auth.uid()) = c.customer_user_id OR (SELECT auth.uid()) = c.provider_user_id)));
DROP POLICY IF EXISTS chatimg_participant_select ON storage.objects;
CREATE POLICY chatimg_participant_select ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'chat-images' AND (EXISTS (SELECT 1 FROM public.conversations c
    WHERE c.id::text = (storage.foldername(name))[1]
      AND ((SELECT auth.uid()) = c.customer_user_id OR (SELECT auth.uid()) = c.provider_user_id))
    OR private.is_platform_admin()));
