-- Stage 2 in-app chat (client <-> provider). Run as one migration, exactly as written.
CREATE TABLE IF NOT EXISTS public.conversations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  provider_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  provider_id uuid REFERENCES public.service_providers(id) ON DELETE SET NULL,
  last_message_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (customer_user_id, provider_user_id),
  CHECK (customer_user_id <> provider_user_id)
);
CREATE TABLE IF NOT EXISTS public.messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id uuid NOT NULL REFERENCES public.conversations(id) ON DELETE CASCADE,
  sender_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  body text NOT NULL CHECK (char_length(body) BETWEEN 1 AND 2000),
  read_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS messages_conv_idx ON public.messages (conversation_id, created_at);
CREATE INDEX IF NOT EXISTS conversations_cust_idx ON public.conversations (customer_user_id, last_message_at DESC);
CREATE INDEX IF NOT EXISTS conversations_prov_idx ON public.conversations (provider_user_id, last_message_at DESC);
ALTER TABLE public.conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.conversations, public.messages FROM anon, authenticated;
GRANT SELECT ON public.conversations, public.messages TO authenticated;
GRANT INSERT (conversation_id, body) ON public.messages TO authenticated;

DROP POLICY IF EXISTS conversations_participants_select ON public.conversations;
CREATE POLICY conversations_participants_select ON public.conversations FOR SELECT TO authenticated
  USING (customer_user_id = (SELECT auth.uid()) OR provider_user_id = (SELECT auth.uid()) OR private.is_platform_admin());
DROP POLICY IF EXISTS messages_participants_select ON public.messages;
CREATE POLICY messages_participants_select ON public.messages FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.conversations c WHERE c.id = conversation_id
    AND (c.customer_user_id = (SELECT auth.uid()) OR c.provider_user_id = (SELECT auth.uid()) OR private.is_platform_admin())));
DROP POLICY IF EXISTS messages_participants_insert ON public.messages;
CREATE POLICY messages_participants_insert ON public.messages FOR INSERT TO authenticated
  WITH CHECK (sender_id = (SELECT auth.uid()) AND EXISTS (SELECT 1 FROM public.conversations c WHERE c.id = conversation_id
    AND (c.customer_user_id = (SELECT auth.uid()) OR c.provider_user_id = (SELECT auth.uid()))));

CREATE OR REPLACE FUNCTION private.messages_before_insert()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  NEW.sender_id := (SELECT auth.uid());
  NEW.read_at := NULL;
  NEW.created_at := now();
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS messages_before_insert ON public.messages;
CREATE TRIGGER messages_before_insert BEFORE INSERT ON public.messages
  FOR EACH ROW EXECUTE FUNCTION private.messages_before_insert();

CREATE OR REPLACE FUNCTION private.messages_after_insert()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  UPDATE public.conversations SET last_message_at = now() WHERE id = NEW.conversation_id;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS messages_after_insert ON public.messages;
CREATE TRIGGER messages_after_insert AFTER INSERT ON public.messages
  FOR EACH ROW EXECUTE FUNCTION private.messages_after_insert();

-- client opens (or reuses) a conversation with an approved provider
CREATE OR REPLACE FUNCTION public.start_conversation(p_provider_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE actor uuid := (SELECT auth.uid()); puid uuid; cid uuid;
BEGIN
  IF actor IS NULL THEN RAISE EXCEPTION 'login required'; END IF;
  SELECT user_id INTO puid FROM public.service_providers WHERE id = p_provider_id AND verification_status = 'approved';
  IF puid IS NULL THEN RAISE EXCEPTION 'provider not available'; END IF;
  IF puid = actor THEN RAISE EXCEPTION 'cannot message yourself'; END IF;
  INSERT INTO public.conversations (customer_user_id, provider_user_id, provider_id)
  VALUES (actor, puid, p_provider_id)
  ON CONFLICT (customer_user_id, provider_user_id) DO UPDATE SET provider_id = EXCLUDED.provider_id
  RETURNING id INTO cid;
  RETURN cid;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_conversation_read(p_conversation_id uuid)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = ''
AS $$
  UPDATE public.messages m SET read_at = now()
  WHERE m.conversation_id = p_conversation_id AND m.read_at IS NULL AND m.sender_id <> (SELECT auth.uid())
    AND EXISTS (SELECT 1 FROM public.conversations c WHERE c.id = p_conversation_id
      AND (SELECT auth.uid()) IN (c.customer_user_id, c.provider_user_id));
$$;
REVOKE EXECUTE ON FUNCTION public.start_conversation(uuid), public.mark_conversation_read(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.start_conversation(uuid), public.mark_conversation_read(uuid) TO authenticated;
ALTER PUBLICATION supabase_realtime ADD TABLE public.messages;
