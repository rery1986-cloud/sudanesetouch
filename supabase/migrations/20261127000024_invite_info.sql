-- Invite landing info: lets the invite page show the region before signup. Run as one migration, exactly as written.
-- Read-only function. It reveals scope and permissions only to someone who holds the secret token.
CREATE OR REPLACE FUNCTION public.get_open_invitation_info(p_token text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE inv public.user_invitations%rowtype;
BEGIN
  SELECT * INTO inv FROM public.user_invitations
   WHERE token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex')
     AND metadata ->> 'open' = 'true' AND status IN ('sent', 'opened')
     AND revoked_at IS NULL AND accepted_at IS NULL AND expires_at > now();
  IF NOT FOUND THEN RETURN jsonb_build_object('valid', false); END IF;
  RETURN jsonb_build_object('valid', true, 'scope_country', inv.metadata ->> 'scope_country',
                            'scope_region', inv.metadata ->> 'scope_region', 'permissions', coalesce(inv.metadata -> 'permissions', '[]'::jsonb));
END;
$$;
REVOKE ALL ON FUNCTION public.get_open_invitation_info(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_open_invitation_info(text) TO anon, authenticated;
