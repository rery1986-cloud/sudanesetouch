-- Extends my_chat_names: also returns the other person's full name, city, area and photo.
-- The phone is returned ONLY when a confirmed/in-progress/completed booking exists between the two. Read-only function, no data changed.
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
                ELSE nullif(btrim(cp.full_name), '') END AS other_name,
           CASE WHEN c.customer_user_id = actor THEN nullif(btrim(coalesce(sp.city, pp.city)), '') ELSE nullif(btrim(cp.city), '') END AS other_city,
           CASE WHEN c.customer_user_id = actor THEN nullif(btrim(coalesce(sp.district, pp.district)), '') ELSE nullif(btrim(cp.district), '') END AS other_district,
           CASE WHEN c.customer_user_id = actor THEN sp.avatar_url ELSE NULL END AS other_avatar,
           CASE WHEN EXISTS (SELECT 1 FROM public.bookings b JOIN public.customers cu ON cu.id = b.customer_id
                             WHERE b.provider_id = c.provider_id AND cu.user_id = c.customer_user_id
                               AND b.status IN ('confirmed','in_progress','completed'))
                THEN CASE WHEN c.customer_user_id = actor THEN sp.contact_phone ELSE cp.phone_private END
                ELSE NULL END AS other_phone
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
