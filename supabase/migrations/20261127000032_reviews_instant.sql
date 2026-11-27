-- Platform reviews show on the home page immediately (no approval step).
-- The admin can still hide a review. A hidden review stays hidden if its author edits it.
-- Changes: the default status, the save function, and ALL currently pending platform reviews become visible (one UPDATE, only on platform_reviews).
-- Abuse protection is unchanged: one review per user, rating 1-5, comment up to 500 characters, signed-in clients/providers/merchants only.
ALTER TABLE public.platform_reviews ALTER COLUMN status SET DEFAULT 'approved';

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
  VALUES (actor, v_name, p_rating, v_comment, 'approved')
  ON CONFLICT (user_id) DO UPDATE
    SET rating = EXCLUDED.rating, comment = EXCLUDED.comment, display_name = EXCLUDED.display_name,
        status = CASE WHEN public.platform_reviews.status = 'hidden' THEN 'hidden' ELSE 'approved' END,
        updated_at = now()
  RETURNING status INTO v_status;
  RETURN jsonb_build_object('status', v_status);
END;
$$;

REVOKE ALL ON FUNCTION public.save_platform_review(int, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_platform_review(int, text) TO authenticated;

UPDATE public.platform_reviews SET status = 'approved', updated_at = now() WHERE status = 'pending';
