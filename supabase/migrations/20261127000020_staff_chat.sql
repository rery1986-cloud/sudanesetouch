-- 000020 staff chat. Admin <-> moderator private chat, reusing conversations and messages from 000010.
ALTER TABLE public.conversations ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'direct';
ALTER TABLE public.conversations DROP CONSTRAINT IF EXISTS conversations_kind_chk;
ALTER TABLE public.conversations ADD CONSTRAINT conversations_kind_chk CHECK (kind IN ('direct', 'staff'));

-- who the caller can message: admin sees active moderators, a moderator sees the admins
CREATE OR REPLACE FUNCTION public.staff_directory()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE r jsonb;
BEGIN
  IF private.is_platform_admin() THEN
    SELECT coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) INTO r FROM (
      SELECT p.id, coalesce(nullif(btrim(p.full_name), ''), p.email) AS name, 'moderator'::text AS role
      FROM public.profiles p WHERE p.role = 'moderator' AND p.is_active ORDER BY p.full_name
    ) t;
  ELSIF private.is_moderator() THEN
    SELECT coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) INTO r FROM (
      SELECT a.user_id AS id, coalesce(nullif(btrim(p.full_name), ''), 'الإدارة') AS name, 'admin'::text AS role
      FROM public.platform_admins a LEFT JOIN public.profiles p ON p.id = a.user_id
    ) t;
  ELSE
    RAISE EXCEPTION 'not allowed';
  END IF;
  RETURN r;
END;
$$;

CREATE OR REPLACE FUNCTION public.start_staff_conversation(p_other uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE actor uuid := (SELECT auth.uid()); cust uuid; prov uuid; cid uuid;
BEGIN
  IF actor IS NULL THEN RAISE EXCEPTION 'login required'; END IF;
  IF private.is_platform_admin() THEN
    IF NOT EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = p_other AND p.role = 'moderator' AND p.is_active) THEN
      RAISE EXCEPTION 'المشرفة غير موجودة أو غير فعالة';
    END IF;
    cust := actor; prov := p_other;
  ELSIF private.is_moderator() THEN
    IF NOT EXISTS (SELECT 1 FROM public.platform_admins a WHERE a.user_id = p_other) THEN
      RAISE EXCEPTION 'يمكن للمشرفة مراسلة الإدارة فقط';
    END IF;
    cust := p_other; prov := actor;
  ELSE
    RAISE EXCEPTION 'not allowed';
  END IF;
  INSERT INTO public.conversations (customer_user_id, provider_user_id, kind)
  VALUES (cust, prov, 'staff')
  ON CONFLICT (customer_user_id, provider_user_id) DO UPDATE SET kind = 'staff'
  RETURNING id INTO cid;
  RETURN cid;
END;
$$;

CREATE OR REPLACE FUNCTION public.my_staff_chats()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE r jsonb; actor uuid := (SELECT auth.uid());
BEGIN
  IF actor IS NULL THEN RETURN '[]'::jsonb; END IF;
  SELECT coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) INTO r FROM (
    SELECT c.id, c.last_message_at,
           CASE WHEN c.customer_user_id = actor THEN c.provider_user_id ELSE c.customer_user_id END AS other_id,
           coalesce(nullif(btrim(o.full_name), ''), o.email, 'الإدارة') AS other_name,
           (SELECT count(*) FROM public.messages m WHERE m.conversation_id = c.id AND m.read_at IS NULL AND m.sender_id <> actor) AS unread
    FROM public.conversations c
    LEFT JOIN public.profiles o ON o.id = CASE WHEN c.customer_user_id = actor THEN c.provider_user_id ELSE c.customer_user_id END
    WHERE c.kind = 'staff' AND actor IN (c.customer_user_id, c.provider_user_id)
    ORDER BY c.last_message_at DESC LIMIT 100
  ) t;
  RETURN r;
END;
$$;

REVOKE ALL ON FUNCTION public.staff_directory(), public.start_staff_conversation(uuid), public.my_staff_chats() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_directory(), public.start_staff_conversation(uuid), public.my_staff_chats() TO authenticated;
