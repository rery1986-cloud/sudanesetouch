-- Account deletion: self-service (any signed-in client/provider/merchant) and admin-only. Run as one migration, exactly as written.
-- Hard delete: removes the auth user, the profile and every row that points to them. Everything runs in ONE transaction:
-- if any step fails, nothing is deleted. Admins and moderators can never be deleted with these functions.
CREATE TABLE IF NOT EXISTS public.account_deletions (
  id bigserial PRIMARY KEY,
  account_type text,
  deleted_by text NOT NULL,
  deleted_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.account_deletions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.account_deletions FROM anon, authenticated;

CREATE OR REPLACE FUNCTION private.purge_refs(p_table regclass, p_col text, p_vals text[], p_depth int)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE fk record; pk text; ids text[];
BEGIN
  IF p_depth > 6 OR p_vals IS NULL OR cardinality(p_vals) = 0 THEN RETURN; END IF;
  FOR fk IN
    SELECT c.conrelid AS child_oid, c.conrelid::regclass::text AS child, a.attname AS childcol
    FROM pg_constraint c
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
    JOIN pg_attribute pa ON pa.attrelid = c.confrelid AND pa.attnum = c.confkey[1]
    WHERE c.contype = 'f' AND c.confrelid = p_table AND cardinality(c.conkey) = 1
      AND pa.attname = p_col AND c.confdeltype IN ('c', 'r', 'a')
  LOOP
    SELECT pka.attname INTO pk
    FROM pg_index i JOIN pg_attribute pka ON pka.attrelid = i.indrelid AND pka.attnum = i.indkey[0]
    WHERE i.indrelid = fk.child_oid AND i.indisprimary AND i.indnatts = 1;
    IF pk IS NOT NULL THEN
      EXECUTE format('SELECT coalesce(array_agg(%I::text), ''{}''::text[]) FROM %s WHERE %I::text = ANY($1)', pk, fk.child, fk.childcol)
        INTO ids USING p_vals;
      IF cardinality(ids) > 0 THEN
        PERFORM private.purge_refs(fk.child_oid::regclass, pk, ids, p_depth + 1);
        EXECUTE format('DELETE FROM %s WHERE %I::text = ANY($1)', fk.child, pk) USING ids;
      END IF;
    ELSE
      EXECUTE format('DELETE FROM %s WHERE %I::text = ANY($1)', fk.child, fk.childcol) USING p_vals;
    END IF;
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION private.delete_account_core(p_uid uuid, p_by text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_type text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = p_uid) THEN RAISE EXCEPTION 'user not found'; END IF;
  SELECT account_type INTO v_type FROM public.profiles WHERE id = p_uid;
  IF coalesce(v_type, '') IN ('admin', 'moderator')
     OR EXISTS (SELECT 1 FROM public.platform_admins WHERE user_id = p_uid) THEN
    RAISE EXCEPTION 'protected account';
  END IF;
  PERFORM private.purge_refs('auth.users'::regclass, 'id', ARRAY[p_uid::text], 0);
  DELETE FROM public.profiles WHERE id = p_uid;
  DELETE FROM auth.users WHERE id = p_uid;
  INSERT INTO public.account_deletions (account_type, deleted_by) VALUES (v_type, p_by);
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_my_account()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE actor uuid := auth.uid();
BEGIN
  IF actor IS NULL THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF EXISTS (
    SELECT 1 FROM public.bookings b JOIN public.customers c ON c.id = b.customer_id
    WHERE c.user_id = actor AND b.status NOT IN ('completed', 'cancelled', 'rejected')
  ) OR EXISTS (
    SELECT 1 FROM public.bookings b JOIN public.service_providers sp ON sp.id = b.provider_id
    WHERE sp.user_id = actor AND b.status NOT IN ('completed', 'cancelled', 'rejected')
  ) THEN
    RAISE EXCEPTION 'active_bookings';
  END IF;
  PERFORM private.delete_account_core(actor, 'self');
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_delete_user(p_user_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  IF NOT private.is_platform_admin() THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF p_user_id = auth.uid() THEN RAISE EXCEPTION 'protected account'; END IF;
  PERFORM private.delete_account_core(p_user_id, 'admin');
END;
$$;

REVOKE ALL ON FUNCTION private.purge_refs(regclass, text, text[], int), private.delete_account_core(uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.delete_my_account(), public.admin_delete_user(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_my_account(), public.admin_delete_user(uuid) TO authenticated;
