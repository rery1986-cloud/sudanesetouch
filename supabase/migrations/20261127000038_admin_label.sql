-- Staff chats: when the other side is a platform admin, show the name "الإدارة" instead of the admin's personal name/email.
-- Replaces one read-only function; changes no data. Run as one migration, exactly as written.
CREATE OR REPLACE FUNCTION public.my_staff_chats()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE r jsonb; actor uuid := (SELECT auth.uid());
BEGIN
  IF actor IS NULL THEN RETURN '[]'::jsonb; END IF;
  SELECT coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) INTO r FROM (
    SELECT c.id, c.last_message_at,
           CASE WHEN c.customer_user_id = actor THEN c.provider_user_id ELSE c.customer_user_id END AS other_id,
           CASE WHEN EXISTS (SELECT 1 FROM public.platform_admins pa
                             WHERE pa.user_id = CASE WHEN c.customer_user_id = actor THEN c.provider_user_id ELSE c.customer_user_id END)
                THEN 'الإدارة'
                ELSE coalesce(nullif(btrim(o.full_name), ''), o.email, 'الإدارة') END AS other_name,
           (SELECT count(*) FROM public.messages m WHERE m.conversation_id = c.id AND m.read_at IS NULL AND m.sender_id <> actor) AS unread
    FROM public.conversations c
    LEFT JOIN public.profiles o ON o.id = CASE WHEN c.customer_user_id = actor THEN c.provider_user_id ELSE c.customer_user_id END
    WHERE c.kind = 'staff' AND actor IN (c.customer_user_id, c.provider_user_id)
    ORDER BY c.last_message_at DESC LIMIT 100
  ) t;
  RETURN r;
END;
$$;
REVOKE ALL ON FUNCTION public.my_staff_chats() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_staff_chats() TO authenticated;
