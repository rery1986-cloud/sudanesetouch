-- 000018 disputes. Client or provider files a dispute on a booking. Moderators handle it, escalate to admin, admin is final.
CREATE TABLE IF NOT EXISTS public.disputes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id uuid NOT NULL REFERENCES public.bookings (id) ON DELETE CASCADE,
  opened_by uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  opener_role text NOT NULL CHECK (opener_role IN ('client', 'provider')),
  against_user_id uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  category text NOT NULL CHECK (category IN ('no_show', 'quality', 'payment', 'behavior', 'cancellation', 'other')),
  details text NOT NULL CHECK (char_length(btrim(details)) BETWEEN 10 AND 2000),
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'in_review', 'escalated', 'resolved')),
  assigned_to uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  assigned_at timestamptz,
  escalated_at timestamptz,
  escalation_note text,
  resolution text,
  resolved_by uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  resolved_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS disputes_status_idx ON public.disputes (status, created_at DESC);
CREATE INDEX IF NOT EXISTS disputes_assigned_idx ON public.disputes (assigned_to);
CREATE UNIQUE INDEX IF NOT EXISTS disputes_one_open_per_user ON public.disputes (booking_id, opened_by) WHERE status <> 'resolved';
ALTER TABLE public.disputes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.disputes FROM anon, authenticated;

CREATE OR REPLACE FUNCTION private.is_moderator()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$ SELECT EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = (SELECT auth.uid()) AND p.role = 'moderator' AND p.is_active); $$;
REVOKE ALL ON FUNCTION private.is_moderator() FROM PUBLIC, anon, authenticated;

-- A review cannot be hidden or shown while a dispute on its booking is unresolved.
CREATE OR REPLACE FUNCTION public.admin_set_review_status(p_id uuid, p_status text, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE pid uuid;
BEGIN
  IF NOT private.is_platform_admin() THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF p_status NOT IN ('published', 'hidden') THEN RAISE EXCEPTION 'invalid status'; END IF;
  IF EXISTS (SELECT 1 FROM public.disputes d JOIN public.reviews v ON v.booking_id = d.booking_id WHERE v.id = p_id AND d.status <> 'resolved') THEN
    RAISE EXCEPTION 'التقييم مقفل لوجود نزاع غير محسوم على هذا الحجز';
  END IF;
  UPDATE public.reviews SET status = p_status, hidden_reason = CASE WHEN p_status = 'hidden' THEN p_reason ELSE NULL END, updated_at = now()
  WHERE id = p_id RETURNING provider_id INTO pid;
  IF pid IS NOT NULL THEN PERFORM private.recalc_provider_rating(pid); END IF;
  RETURN jsonb_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.file_dispute(p_booking_id uuid, p_category text, p_details text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  actor uuid := (SELECT auth.uid());
  bk public.bookings%ROWTYPE;
  cust_user uuid; prov_user uuid; orole text; other uuid; did uuid;
BEGIN
  IF actor IS NULL THEN RAISE EXCEPTION 'سجّلي الدخول أولاً'; END IF;
  SELECT * INTO bk FROM public.bookings WHERE id = p_booking_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'الحجز غير موجود'; END IF;
  SELECT c.user_id INTO cust_user FROM public.customers c WHERE c.id = bk.customer_id;
  SELECT sp.user_id INTO prov_user FROM public.service_providers sp WHERE sp.id = bk.provider_id;
  IF actor = cust_user THEN orole := 'client'; other := prov_user;
  ELSIF actor = prov_user THEN orole := 'provider'; other := cust_user;
  ELSE RAISE EXCEPTION 'لا يمكنك فتح نزاع على هذا الحجز'; END IF;
  IF bk.status NOT IN ('confirmed', 'completed', 'cancelled') THEN RAISE EXCEPTION 'لا يمكن فتح نزاع على حجز بهذه الحالة'; END IF;
  IF EXISTS (SELECT 1 FROM public.disputes WHERE booking_id = p_booking_id AND opened_by = actor AND status <> 'resolved') THEN
    RAISE EXCEPTION 'لديك نزاع مفتوح على هذا الحجز بالفعل';
  END IF;
  INSERT INTO public.disputes (booking_id, opened_by, opener_role, against_user_id, category, details)
  VALUES (p_booking_id, actor, orole, other, p_category, btrim(p_details)) RETURNING id INTO did;
  RETURN jsonb_build_object('id', did);
END;
$$;

CREATE OR REPLACE FUNCTION public.my_disputes()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE r jsonb; actor uuid := (SELECT auth.uid());
BEGIN
  IF actor IS NULL THEN RETURN '[]'::jsonb; END IF;
  SELECT coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) INTO r FROM (
    SELECT d.id, d.booking_id, d.category, d.status, d.opener_role, (d.opened_by = actor) AS mine,
           CASE WHEN d.status = 'resolved' THEN d.resolution END AS resolution, d.created_at
    FROM public.disputes d WHERE d.opened_by = actor OR d.against_user_id = actor
    ORDER BY d.created_at DESC LIMIT 200
  ) t;
  RETURN r;
END;
$$;

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
           b.status AS booking_status, b.scheduled_at, b.total_amount, b.currency, sp.display_name AS provider_name,
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

CREATE OR REPLACE FUNCTION public.admin_list_moderators()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE r jsonb;
BEGIN
  IF NOT private.is_platform_admin() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) INTO r FROM (
    SELECT p.id, p.full_name, p.email, p.scope_country, p.scope_city,
           (SELECT count(*) FROM public.disputes d WHERE d.assigned_to = p.id AND d.status IN ('in_review', 'escalated')) AS active_disputes
    FROM public.profiles p WHERE p.role = 'moderator' AND p.is_active ORDER BY p.full_name
  ) t;
  RETURN r;
END;
$$;

CREATE OR REPLACE FUNCTION public.staff_take_dispute(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE actor uuid := (SELECT auth.uid()); n int;
BEGIN
  IF NOT (private.is_platform_admin() OR private.is_moderator()) THEN RAISE EXCEPTION 'not allowed'; END IF;
  UPDATE public.disputes SET assigned_to = actor, assigned_at = now(), status = 'in_review', updated_at = now()
  WHERE id = p_id AND assigned_to IS NULL AND status = 'open';
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 THEN RAISE EXCEPTION 'النزاع غير متاح للاستلام'; END IF;
  RETURN jsonb_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_assign_dispute(p_id uuid, p_moderator uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE n int;
BEGIN
  IF NOT private.is_platform_admin() THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = p_moderator AND p.role = 'moderator' AND p.is_active) THEN
    RAISE EXCEPTION 'المشرفة غير موجودة أو غير فعالة';
  END IF;
  UPDATE public.disputes SET assigned_to = p_moderator, assigned_at = now(), status = 'in_review', escalated_at = NULL, updated_at = now()
  WHERE id = p_id AND status <> 'resolved';
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 THEN RAISE EXCEPTION 'النزاع غير موجود أو محسوم'; END IF;
  RETURN jsonb_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.staff_escalate_dispute(p_id uuid, p_note text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE actor uuid := (SELECT auth.uid()); n int; bno bigint; mname text;
BEGIN
  IF NOT private.is_moderator() THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF char_length(btrim(coalesce(p_note, ''))) < 5 THEN RAISE EXCEPTION 'اكتبي سبب التصعيد'; END IF;
  UPDATE public.disputes SET status = 'escalated', escalated_at = now(), escalation_note = btrim(p_note), updated_at = now()
  WHERE id = p_id AND assigned_to = actor AND status = 'in_review';
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 THEN RAISE EXCEPTION 'لا يمكنك تصعيد هذا النزاع'; END IF;
  SELECT b.booking_number INTO bno FROM public.disputes d JOIN public.bookings b ON b.id = d.booking_id WHERE d.id = p_id;
  SELECT full_name INTO mname FROM public.profiles WHERE id = actor;
  INSERT INTO public.admin_notifications (kind, title, body, ref_user_id)
  VALUES ('dispute_escalated', 'نزاع مُصعَّد يحتاج قرارك (حجز #' || coalesce(bno::text, '') || ')',
          'صعّدته المشرفة: ' || coalesce(mname, '') || ' | السبب: ' || btrim(p_note), actor);
  RETURN jsonb_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.staff_resolve_dispute(p_id uuid, p_resolution text, p_review_action text DEFAULT 'keep')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  actor uuid := (SELECT auth.uid()); adm boolean := private.is_platform_admin();
  d public.disputes%ROWTYPE; rid uuid; pid uuid;
BEGIN
  IF NOT (adm OR private.is_moderator()) THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF char_length(btrim(coalesce(p_resolution, ''))) < 5 THEN RAISE EXCEPTION 'اكتبي قرار الحسم'; END IF;
  IF p_review_action NOT IN ('keep', 'hide') THEN RAISE EXCEPTION 'invalid review action'; END IF;
  SELECT * INTO d FROM public.disputes WHERE id = p_id FOR UPDATE;
  IF NOT FOUND OR d.status = 'resolved' THEN RAISE EXCEPTION 'النزاع غير موجود أو محسوم'; END IF;
  IF NOT adm THEN
    IF d.assigned_to IS DISTINCT FROM actor THEN RAISE EXCEPTION 'هذا النزاع ليس مسنداً لك'; END IF;
    IF d.status = 'escalated' THEN RAISE EXCEPTION 'النزاع مُصعَّد للإدارة'; END IF;
  END IF;
  UPDATE public.disputes SET status = 'resolved', resolution = btrim(p_resolution), resolved_by = actor, resolved_at = now(), updated_at = now()
  WHERE id = p_id;
  IF p_review_action = 'hide' THEN
    UPDATE public.reviews SET status = 'hidden', hidden_reason = 'نزاع محسوم', updated_at = now()
    WHERE booking_id = d.booking_id RETURNING provider_id INTO pid;
    IF pid IS NOT NULL THEN PERFORM private.recalc_provider_rating(pid); END IF;
  END IF;
  RETURN jsonb_build_object('ok', true);
END;
$$;

REVOKE ALL ON FUNCTION public.file_dispute(uuid, text, text), public.my_disputes(), public.staff_list_disputes(),
  public.admin_list_moderators(), public.staff_take_dispute(uuid), public.admin_assign_dispute(uuid, uuid),
  public.staff_escalate_dispute(uuid, text), public.staff_resolve_dispute(uuid, text, text), public.admin_set_review_status(uuid, text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.file_dispute(uuid, text, text), public.my_disputes(), public.staff_list_disputes(),
  public.admin_list_moderators(), public.staff_take_dispute(uuid), public.admin_assign_dispute(uuid, uuid),
  public.staff_escalate_dispute(uuid, text), public.staff_resolve_dispute(uuid, text, text), public.admin_set_review_status(uuid, text, text)
  TO authenticated;
