-- Protect real accounts from accidental deletion (Mawada's accounts). Admin/moderator accounts and the caller's own account were already protected.
-- Run as one migration, exactly as written. Only replaces one function; deletes nothing.
CREATE OR REPLACE FUNCTION private.delete_account_core(p_uid uuid, p_by text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_type text; v_email text; v_name text;
BEGIN
  SELECT email INTO v_email FROM auth.users WHERE id = p_uid;
  IF NOT FOUND THEN RAISE EXCEPTION 'user not found'; END IF;
  SELECT account_type, full_name INTO v_type, v_name FROM public.profiles WHERE id = p_uid;
  IF coalesce(v_type, '') IN ('admin', 'moderator')
     OR EXISTS (SELECT 1 FROM public.platform_admins WHERE user_id = p_uid) THEN
    RAISE EXCEPTION 'protected account';
  END IF;
  IF lower(coalesce(v_email, '')) LIKE 'mawada%' OR lower(coalesce(v_name, '')) LIKE '%mawada%'
     OR coalesce(v_name, '') LIKE '%مودة%' OR coalesce(v_name, '') LIKE '%موده%' THEN
    RAISE EXCEPTION 'protected account';
  END IF;
  PERFORM private.purge_refs('auth.users'::regclass, 'id', ARRAY[p_uid::text], 0);
  DELETE FROM public.profiles WHERE id = p_uid;
  DELETE FROM auth.users WHERE id = p_uid;
  INSERT INTO public.account_deletions (account_type, deleted_by) VALUES (v_type, p_by);
END;
$$;
