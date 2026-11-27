-- 000016 reviews. One review per completed booking, written by the client. Auto-published, admin can hide.
CREATE TABLE IF NOT EXISTS public.reviews (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id uuid NOT NULL UNIQUE REFERENCES public.bookings (id) ON DELETE CASCADE,
  provider_id uuid NOT NULL REFERENCES public.service_providers (id) ON DELETE CASCADE,
  customer_user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  reviewer_name text,
  quality smallint NOT NULL CHECK (quality BETWEEN 1 AND 5),
  punctuality smallint NOT NULL CHECK (punctuality BETWEEN 1 AND 5),
  cleanliness smallint NOT NULL CHECK (cleanliness BETWEEN 1 AND 5),
  attitude smallint NOT NULL CHECK (attitude BETWEEN 1 AND 5),
  photo_accuracy smallint NOT NULL CHECK (photo_accuracy BETWEEN 1 AND 5),
  rating numeric(2,1) NOT NULL CHECK (rating BETWEEN 1 AND 5),
  comment text NOT NULL CHECK (char_length(btrim(comment)) BETWEEN 3 AND 1000),
  status text NOT NULL DEFAULT 'published' CHECK (status IN ('published', 'hidden')),
  hidden_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS reviews_provider_idx ON public.reviews (provider_id, created_at DESC);
ALTER TABLE public.reviews ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.reviews FROM anon, authenticated;
GRANT SELECT (id, provider_id, rating, quality, punctuality, cleanliness, attitude, photo_accuracy, comment, reviewer_name, created_at)
  ON public.reviews TO anon, authenticated;
DROP POLICY IF EXISTS reviews_public_select ON public.reviews;
CREATE POLICY reviews_public_select ON public.reviews FOR SELECT TO anon, authenticated USING (status = 'published');

CREATE OR REPLACE FUNCTION private.recalc_provider_rating(p_provider uuid)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = ''
AS $$
  UPDATE public.service_providers sp
  SET average_rating = coalesce((SELECT round(avg(r.rating), 1) FROM public.reviews r WHERE r.provider_id = p_provider AND r.status = 'published'), 0)
  WHERE sp.id = p_provider;
$$;

CREATE OR REPLACE FUNCTION public.submit_review(p_booking_id uuid, p_quality int, p_punctuality int, p_cleanliness int,
  p_attitude int, p_photo_accuracy int, p_comment text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  actor uuid := (SELECT auth.uid());
  bk public.bookings%ROWTYPE;
  cust_user uuid;
  rname text;
  rid uuid;
BEGIN
  IF actor IS NULL THEN RAISE EXCEPTION 'سجّلي الدخول أولاً'; END IF;
  SELECT * INTO bk FROM public.bookings WHERE id = p_booking_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'الحجز غير موجود'; END IF;
  SELECT c.user_id INTO cust_user FROM public.customers c WHERE c.id = bk.customer_id;
  IF cust_user IS DISTINCT FROM actor THEN RAISE EXCEPTION 'لا يمكنك تقييم هذا الحجز'; END IF;
  IF bk.status <> 'completed' THEN RAISE EXCEPTION 'لا يمكن التقييم إلا بعد إتمام الحجز'; END IF;
  IF EXISTS (SELECT 1 FROM public.reviews WHERE booking_id = p_booking_id) THEN RAISE EXCEPTION 'تم تقييم هذا الحجز مسبقاً'; END IF;
  SELECT split_part(btrim(coalesce(p.full_name, '')), ' ', 1) INTO rname FROM public.profiles p WHERE p.id = actor;
  INSERT INTO public.reviews (booking_id, provider_id, customer_user_id, reviewer_name, quality, punctuality, cleanliness, attitude, photo_accuracy, rating, comment)
  VALUES (p_booking_id, bk.provider_id, actor, nullif(rname, ''), p_quality, p_punctuality, p_cleanliness, p_attitude, p_photo_accuracy,
          round((p_quality + p_punctuality + p_cleanliness + p_attitude + p_photo_accuracy) / 5.0, 1), btrim(p_comment))
  RETURNING id INTO rid;
  PERFORM private.recalc_provider_rating(bk.provider_id);
  RETURN jsonb_build_object('id', rid);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_list_reviews()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE r jsonb;
BEGIN
  IF NOT private.is_platform_admin() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) INTO r FROM (
    SELECT v.id, v.rating, v.comment, v.status, v.hidden_reason, v.created_at,
           sp.display_name AS provider_name, p.full_name AS client_name
    FROM public.reviews v
    LEFT JOIN public.service_providers sp ON sp.id = v.provider_id
    LEFT JOIN public.profiles p ON p.id = v.customer_user_id
    ORDER BY v.created_at DESC LIMIT 1000
  ) t;
  RETURN r;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_review_status(p_id uuid, p_status text, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE pid uuid;
BEGIN
  IF NOT private.is_platform_admin() THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF p_status NOT IN ('published', 'hidden') THEN RAISE EXCEPTION 'invalid status'; END IF;
  UPDATE public.reviews SET status = p_status, hidden_reason = CASE WHEN p_status = 'hidden' THEN p_reason ELSE NULL END, updated_at = now()
  WHERE id = p_id RETURNING provider_id INTO pid;
  IF pid IS NOT NULL THEN PERFORM private.recalc_provider_rating(pid); END IF;
  RETURN jsonb_build_object('ok', true);
END;
$$;

REVOKE ALL ON FUNCTION private.recalc_provider_rating(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.submit_review(uuid, int, int, int, int, int, text), public.admin_list_reviews(),
  public.admin_set_review_status(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.submit_review(uuid, int, int, int, int, int, text), public.admin_list_reviews(),
  public.admin_set_review_status(uuid, text, text) TO authenticated;
