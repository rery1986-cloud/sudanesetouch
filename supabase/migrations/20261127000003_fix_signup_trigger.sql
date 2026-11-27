DROP TRIGGER IF EXISTS on_auth_user_created_public_profile ON auth.users;
CREATE OR REPLACE FUNCTION public.handle_new_public_profile()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$ BEGIN RETURN NEW; END; $$;
