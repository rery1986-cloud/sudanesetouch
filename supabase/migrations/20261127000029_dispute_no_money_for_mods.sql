-- Moderators must not see money in disputes: amount and currency are returned only to the admin. Replaces one read-only function; no data is changed.
CREATE OR REPLACE FUNCTION public.staff_list_disputes()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE r jsonb; actor uuid := (SELECT auth.uid()); adm boolean := private.is_platform_admin();
BEGIN
  IF NOT (adm OR private.is_moderator()) THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) INTO r FROM (
    SELECT d.id, d.booking_id, d.category, d.details, d.status, d.opener_role, d.created_at, d.assigned_to,
           d.assigned_at, d.escalated_at, d.escalation_note, d.resolution, d.resolved_at,
           (d.assigned_to = actor) AS is_mine,
           po.full_name AS opener_name, ag.full_name AS against_name, am.full_name AS assigned_name,
           b.status AS booking_status, b.scheduled_at, CASE WHEN adm THEN b.total_amount END AS total_amount, CASE WHEN adm THEN b.currency END AS currency, sp.display_name AS provider_name,
           v.id AS review_id, v.rating AS review_rating, v.comment AS review_comment, v.status AS review_status
    FROM public.disputes d
    JOIN public.bookings b ON b.id = d.booking_id
    LEFT JOIN public.service_providers sp ON sp.id = b.provider_id
    LEFT JOIN public.profiles po ON po.id = d.opened_by
    LEFT JOIN public.profiles ag ON ag.id = d.against_user_id
    LEFT JOIN public.profiles am ON am.id = d.assigned_to
    LEFT JOIN public.reviews v ON v.booking_id = d.booking_id
    WHERE adm OR (d.assigned_to = actor) OR (d.assigned_to IS NULL AND d.status = 'open')
    ORDER BY (d.status = 'escalated') DESC, (d.status = 'resolved'), d.created_at DESC LIMIT 500
  ) t;
  RETURN r;
END;
$$;
REVOKE ALL ON FUNCTION public.staff_list_disputes() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_list_disputes() TO authenticated;
