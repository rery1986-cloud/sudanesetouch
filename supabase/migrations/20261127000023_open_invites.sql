-- Open moderator invite links (single use, 7 days). Run as one migration, exactly as written.
-- Built on the live user_invitations table. No data is changed.
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS permissions jsonb NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS country text;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS region text;

CREATE OR REPLACE FUNCTION public.create_open_moderator_invitation(
  p_country text, p_region text, p_permissions jsonb, p_token_hash text
)
RETURNS TABLE (id uuid, expires_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE new_id uuid; new_exp timestamptz := now() + interval '7 days'; perms jsonb := coalesce(p_permissions, '[]'::jsonb);
BEGIN
  IF NOT coalesce((SELECT private.is_platform_admin()), false) THEN RAISE EXCEPTION 'not authorized' USING errcode = '42501'; END IF;
  IF coalesce(trim(p_token_hash), '') = '' THEN RAISE EXCEPTION 'invalid invitation'; END IF;
  IF jsonb_typeof(perms) <> 'array' OR EXISTS (
       SELECT 1 FROM jsonb_array_elements_text(perms) x(v)
       WHERE x.v NOT IN ('manage_ads', 'manage_providers', 'manage_reports', 'manage_categories')) THEN
    RAISE EXCEPTION 'invalid permissions';
  END IF;
  IF (SELECT count(*) FROM public.user_invitations u
       WHERE u.metadata ->> 'open' = 'true' AND u.status IN ('sent', 'opened') AND u.revoked_at IS NULL AND u.expires_at > now()) >= 20 THEN
    RAISE EXCEPTION 'too many open invitations, revoke some first';
  END IF;
  INSERT INTO public.user_invitations (email, invited_role, invitation_type, token_hash, invited_by, invited_by_name, expires_at, metadata)
  VALUES ('open-' || gen_random_uuid()::text || '@open-invite.invalid', 'moderator', 'moderator', trim(p_token_hash), auth.uid(),
          (SELECT coalesce(pr.full_name, pr.email) FROM public.profiles pr WHERE pr.id = auth.uid()), new_exp,
          jsonb_build_object('open', 'true', 'scope_country', nullif(trim(coalesce(p_country, '')), ''),
                             'scope_region', nullif(trim(coalesce(p_region, '')), ''), 'permissions', perms))
  RETURNING user_invitations.id INTO new_id;
  INSERT INTO public.admin_audit_log (actor_user_id, actor_email, action, details)
  VALUES (auth.uid(), (SELECT au.email FROM auth.users au WHERE au.id = auth.uid()), 'invitation_created',
          jsonb_build_object('role', 'moderator', 'type', 'open_moderator', 'invitation_id', new_id));
  id := new_id; expires_at := new_exp;
  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_list_open_invitations()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE r jsonb;
BEGIN
  IF NOT coalesce((SELECT private.is_platform_admin()), false) THEN RAISE EXCEPTION 'not authorized' USING errcode = '42501'; END IF;
  SELECT coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) INTO r FROM (
    SELECT u.id, u.created_at, u.expires_at, u.accepted_at, u.metadata -> 'permissions' AS permissions,
           CASE WHEN u.accepted_at IS NOT NULL THEN 'used'
                WHEN u.revoked_at IS NOT NULL THEN 'revoked'
                WHEN u.expires_at <= now() THEN 'expired' ELSE 'active' END AS state,
           (SELECT p.full_name FROM public.profiles p WHERE p.id = u.accepted_user_id) AS accepted_name
    FROM public.user_invitations u
    WHERE u.metadata ->> 'open' = 'true'
    ORDER BY u.created_at DESC LIMIT 30
  ) t;
  RETURN r;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_revoke_open_invitation(p_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  IF NOT coalesce((SELECT private.is_platform_admin()), false) THEN RAISE EXCEPTION 'not authorized' USING errcode = '42501'; END IF;
  UPDATE public.user_invitations SET revoked_at = now(), expires_at = now()
   WHERE id = p_id AND metadata ->> 'open' = 'true' AND accepted_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'invitation not found or already used'; END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.accept_open_moderator_invitation(p_token text, p_full_name text, p_phone text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE inv public.user_invitations%rowtype;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'authentication required' USING errcode = '42501'; END IF;
  IF char_length(trim(coalesce(p_full_name, ''))) < 2 OR char_length(trim(coalesce(p_full_name, ''))) > 80 THEN RAISE EXCEPTION 'full name is required'; END IF;
  IF char_length(trim(coalesce(p_phone, ''))) < 6 OR char_length(trim(coalesce(p_phone, ''))) > 25 THEN RAISE EXCEPTION 'phone is required'; END IF;
  IF coalesce((SELECT private.is_platform_admin()), false) THEN RAISE EXCEPTION 'admin accounts cannot use this link'; END IF;
  IF EXISTS (SELECT 1 FROM public.service_providers sp WHERE sp.user_id = auth.uid())
     OR EXISTS (SELECT 1 FROM public.merchants m WHERE m.user_id = auth.uid()) THEN
    RAISE EXCEPTION 'provider and merchant accounts cannot become moderators';
  END IF;
  UPDATE public.user_invitations
     SET status = 'accepted', accepted_at = now(), accepted_user_id = auth.uid()
   WHERE token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
     AND metadata ->> 'open' = 'true' AND status IN ('sent', 'opened')
     AND revoked_at IS NULL AND accepted_at IS NULL AND expires_at > now()
  RETURNING * INTO inv;
  IF NOT FOUND THEN RAISE EXCEPTION 'invitation invalid, expired, or already used'; END IF;
  UPDATE public.profiles
     SET role = 'moderator', account_type = 'moderator', registration_source = 'admin_invite',
         full_name = trim(p_full_name), phone_private = trim(p_phone),
         scope_country = inv.metadata ->> 'scope_country', scope_region = inv.metadata ->> 'scope_region',
         country = inv.metadata ->> 'scope_country', region = inv.metadata ->> 'scope_region',
         permissions = coalesce(inv.metadata -> 'permissions', '[]'::jsonb),
         is_active = true, updated_at = now()
   WHERE id = auth.uid();
  IF NOT FOUND THEN RAISE EXCEPTION 'profile not found'; END IF;
  INSERT INTO public.admin_audit_log (actor_user_id, actor_email, action, details)
  VALUES (auth.uid(), (SELECT au.email FROM auth.users au WHERE au.id = auth.uid()), 'invitation_accepted',
          jsonb_build_object('role', 'moderator', 'type', 'open_moderator', 'invitation_id', inv.id));
  RETURN jsonb_build_object('accepted', true, 'role', 'moderator');
END;
$$;

REVOKE ALL ON FUNCTION public.create_open_moderator_invitation(text, text, jsonb, text), public.admin_list_open_invitations(),
  public.admin_revoke_open_invitation(uuid), public.accept_open_moderator_invitation(text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_open_moderator_invitation(text, text, jsonb, text), public.admin_list_open_invitations(),
  public.admin_revoke_open_invitation(uuid), public.accept_open_moderator_invitation(text, text, text) TO authenticated;
