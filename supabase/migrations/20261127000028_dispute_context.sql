-- Dispute details for staff: booking, parties and the chat between the two parties. Run as one migration, exactly as written.
-- Adds one read-only function. No data is changed. Phone numbers are not returned.
CREATE OR REPLACE FUNCTION public.dispute_context(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  actor uuid := (SELECT auth.uid()); adm boolean := private.is_platform_admin();
  d public.disputes%ROWTYPE; b public.bookings%ROWTYPE;
  cust uuid; prov uuid; pname text; cname text; svc text; msgs jsonb;
BEGIN
  IF NOT (adm OR private.is_moderator()) THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO d FROM public.disputes WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'dispute not found'; END IF;
  IF NOT (adm OR d.assigned_to = actor OR (d.assigned_to IS NULL AND d.status = 'open')) THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO b FROM public.bookings WHERE id = d.booking_id;
  SELECT c.user_id INTO cust FROM public.customers c WHERE c.id = b.customer_id;
  SELECT sp.user_id, sp.display_name INTO prov, pname FROM public.service_providers sp WHERE sp.id = b.provider_id;
  SELECT so.title INTO svc FROM public.service_offers so WHERE so.id = b.offer_id;
  SELECT pr.full_name INTO cname FROM public.profiles pr WHERE pr.id = cust;
  SELECT coalesce(jsonb_agg(jsonb_build_object('role', t.role, 'body', t.body, 'created_at', t.created_at) ORDER BY t.created_at), '[]'::jsonb) INTO msgs
  FROM (
    SELECT CASE WHEN m.sender_id = cust THEN 'client' ELSE 'provider' END AS role, m.body, m.created_at
    FROM public.messages m JOIN public.conversations cv ON cv.id = m.conversation_id
    WHERE cv.customer_user_id = cust AND cv.provider_user_id = prov
    ORDER BY m.created_at DESC LIMIT 40
  ) t;
  RETURN jsonb_build_object(
    'service', svc, 'scheduled_at', b.scheduled_at, 'location_type', b.location_type, 'address', b.address,
    'customer_notes', b.customer_notes, 'provider_notes', b.provider_notes,
    'customer_name', cname, 'provider_name', pname, 'messages', msgs);
END;
$$;
REVOKE ALL ON FUNCTION public.dispute_context(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.dispute_context(uuid) TO authenticated;
