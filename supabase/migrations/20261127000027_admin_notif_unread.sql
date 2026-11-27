-- Admin: details of one account, opened from the new-signup notification. Run as one migration, exactly as written.
-- Adds one read-only function. No data is changed. The notification table and trigger already exist (migration 7).
CREATE OR REPLACE FUNCTION public.admin_get_user_detail(p_user_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE r jsonb;
BEGIN
  IF NOT private.is_platform_admin() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT to_jsonb(t) INTO r FROM (
    SELECT p.id, p.email, p.full_name, p.account_type, p.role,
           coalesce(p.phone_private, p.phone) AS phone, p.city, p.district, p.country_name, p.specialty,
           p.approval_status, p.account_status, p.registration_source, p.created_at, p.last_login_at,
           u.last_sign_in_at, u.email_confirmed_at,
           sp.id AS provider_id, sp.verification_status AS provider_status,
           m.id AS merchant_id, coalesce(m.business_name, m.display_name) AS merchant_name, m.verification_status AS merchant_status,
           (SELECT count(*) FROM public.bookings b JOIN public.customers c ON c.id = b.customer_id WHERE c.user_id = p.id) AS bookings_as_client,
           (SELECT count(*) FROM public.bookings b WHERE b.provider_id = sp.id) AS bookings_as_provider
    FROM public.profiles p
    LEFT JOIN auth.users u ON u.id = p.id
    LEFT JOIN public.service_providers sp ON sp.user_id = p.id
    LEFT JOIN public.merchants m ON m.user_id = p.id
    WHERE p.id = p_user_id
  ) t;
  IF r IS NULL THEN RAISE EXCEPTION 'user not found'; END IF;
  RETURN r;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_get_user_detail(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_get_user_detail(uuid) TO authenticated;

-- Unread chat count: only conversations the user takes part in. The admin can read every conversation, so the old count included other people's chats that the admin can never open or mark as read.
CREATE OR REPLACE FUNCTION public.my_unread_chat_count()
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT count(*)::int FROM public.messages m JOIN public.conversations c ON c.id = m.conversation_id
  WHERE m.read_at IS NULL AND m.sender_id <> (SELECT auth.uid())
    AND (SELECT auth.uid()) IN (c.customer_user_id, c.provider_user_id);
$$;
REVOKE ALL ON FUNCTION public.my_unread_chat_count() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_unread_chat_count() TO authenticated;
