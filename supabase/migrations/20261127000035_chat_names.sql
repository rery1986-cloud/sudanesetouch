-- Show the other person's name in chats. Adds one read-only function, changes no data.
-- Providers see the client's first name and city only. Clients see the provider's display name. No phone or email is returned.
-- Run as one migration, exactly as written.
CREATE OR REPLACE FUNCTION public.my_chat_names()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE r jsonb; actor uuid := (SELECT auth.uid());
BEGIN
  IF actor IS NULL THEN RETURN '[]'::jsonb; END IF;
  SELECT coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) INTO r FROM (
    SELECT c.id,
           CASE WHEN c.customer_user_id = actor
                THEN coalesce(nullif(btrim(sp.display_name), ''), nullif(btrim(pp.full_name), ''))
                ELSE nullif(split_part(btrim(cp.full_name), ' ', 1), '') END AS other_name,
           CASE WHEN c.customer_user_id = actor THEN NULL ELSE nullif(btrim(cp.city), '') END AS other_city
    FROM public.conversations c
    LEFT JOIN public.profiles cp ON cp.id = c.customer_user_id
    LEFT JOIN public.profiles pp ON pp.id = c.provider_user_id
    LEFT JOIN public.service_providers sp ON sp.id = c.provider_id
    WHERE c.kind = 'direct' AND actor IN (c.customer_user_id, c.provider_user_id)
    ORDER BY c.last_message_at DESC LIMIT 100
  ) t;
  RETURN r;
END;
$$;
REVOKE ALL ON FUNCTION public.my_chat_names() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_chat_names() TO authenticated;
