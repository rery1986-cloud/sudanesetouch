-- Reviews of the platform itself (home page). Run as one migration, exactly as written.
-- Creates one table and 5 functions. No existing data is changed. The table is closed to direct access: everything goes through the functions.
-- One review per user (editable; an edit goes back to "pending"). Visitors only get approved reviews. Only the admin approves or hides.
CREATE TABLE IF NOT EXISTS public.platform_reviews (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL UNIQUE REFERENCES auth.users (id) ON DELETE CASCADE,
  display_name text NOT NULL,
  rating smallint NOT NULL CHECK (rating BETWEEN 1 AND 5),
  comment text CHECK (comment IS NULL OR char_length(comment) <= 500),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'hidden')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS platform_reviews_status_idx ON public.platform_reviews (status, created_at DESC);
ALTER TABLE public.platform_reviews ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.platform_reviews FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.list_platform_reviews()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE r jsonb;
BEGIN
  SELECT jsonb_build_object(
    'count', (SELECT count(*) FROM public.platform_reviews WHERE status = 'approved'),
    'avg', (SELECT round(avg(rating)::numeric, 1) FROM public.platform_reviews WHERE status = 'approved'),
    'items', coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM (
        SELECT id, display_name, rating, comment, created_at
        FROM public.platform_reviews WHERE status = 'approved'
        ORDER BY created_at DESC LIMIT 30) t), '[]'::jsonb)
  ) INTO r;
  RETURN r;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_my_platform_review()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE r jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT jsonb_build_object('rating', rating, 'comment', comment, 'status', status)
  INTO r FROM public.platform_reviews WHERE user_id = auth.uid();
  RETURN r;
END;
$$;

CREATE OR REPLACE FUNCTION public.save_platform_review(p_rating int, p_comment text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  actor uuid := auth.uid();
  v_name text; v_type text; v_comment text; v_status text;
BEGIN
  IF actor IS NULL THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT full_name, account_type INTO v_name, v_type FROM public.profiles WHERE id = actor;
  IF v_type IS NULL OR v_type NOT IN ('client', 'service_provider', 'merchant') THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF p_rating IS NULL OR p_rating < 1 OR p_rating > 5 THEN RAISE EXCEPTION 'bad rating'; END IF;
  v_comment := nullif(btrim(coalesce(p_comment, '')), '');
  IF v_comment IS NOT NULL AND char_length(v_comment) > 500 THEN RAISE EXCEPTION 'comment too long'; END IF;
  v_name := coalesce(nullif(left(split_part(btrim(coalesce(v_name, '')), ' ', 1), 30), ''), 'مستخدمة');
  INSERT INTO public.platform_reviews (user_id, display_name, rating, comment, status)
  VALUES (actor, v_name, p_rating, v_comment, 'pending')
  ON CONFLICT (user_id) DO UPDATE
    SET rating = EXCLUDED.rating, comment = EXCLUDED.comment, display_name = EXCLUDED.display_name,
        status = 'pending', updated_at = now()
  RETURNING status INTO v_status;
  RETURN jsonb_build_object('status', v_status);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_list_platform_reviews()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE r jsonb;
BEGIN
  IF NOT private.is_platform_admin() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) INTO r FROM (
    SELECT v.id, v.display_name, v.rating, v.comment, v.status, v.created_at, p.email
    FROM public.platform_reviews v LEFT JOIN public.profiles p ON p.id = v.user_id
    ORDER BY (v.status = 'pending') DESC, v.created_at DESC LIMIT 200
  ) t;
  RETURN r;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_platform_review_status(p_id uuid, p_status text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  IF NOT private.is_platform_admin() THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF p_status NOT IN ('pending', 'approved', 'hidden') THEN RAISE EXCEPTION 'bad status'; END IF;
  UPDATE public.platform_reviews SET status = p_status, updated_at = now() WHERE id = p_id;
END;
$$;

REVOKE ALL ON FUNCTION public.list_platform_reviews(), public.get_my_platform_review(), public.save_platform_review(int, text),
  public.admin_list_platform_reviews(), public.admin_set_platform_review_status(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_platform_reviews() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_platform_review(), public.save_platform_review(int, text),
  public.admin_list_platform_reviews(), public.admin_set_platform_review_status(uuid, text) TO authenticated;
