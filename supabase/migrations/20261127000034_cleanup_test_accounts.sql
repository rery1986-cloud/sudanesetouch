-- One-time cleanup: delete the 9 TEST accounts (and every row that belongs to them) so the database holds real users only.
-- Exact email match only. Nothing else is touched. Runs in ONE transaction: any error cancels everything.
DO $$
DECLARE
  emails text[] := ARRAY[
    'rery1986+clienttest1@gmail.com','rery1986+probe1@gmail.com','rery1986+auditcheck@gmail.com',
    'rery1986+modtest1@gmail.com','rery1986+modtest2@gmail.com','rery1986+test1@gmail.com',
    'rery1986+provtest1@gmail.com','rery1986+fetest3@gmail.com','rery1986+test2@gmail.com'
  ];
  r record; n int := 0;
BEGIN
  FOR r IN SELECT id, email FROM auth.users WHERE lower(email) = ANY (emails) ORDER BY email LOOP
    IF EXISTS (SELECT 1 FROM public.platform_admins WHERE user_id = r.id) OR lower(r.email) NOT LIKE 'rery1986+%' THEN
      RAISE EXCEPTION 'refusing to delete %', r.email;
    END IF;
    PERFORM private.purge_refs('auth.users'::regclass, 'id', ARRAY[r.id::text], 0);
    DELETE FROM public.profiles WHERE id = r.id;
    DELETE FROM auth.users WHERE id = r.id;
    INSERT INTO public.account_deletions (account_type, deleted_by) VALUES ('test', 'cleanup');
    n := n + 1;
    RAISE NOTICE 'deleted %', r.email;
  END LOOP;
  IF n > 9 THEN RAISE EXCEPTION 'too many accounts matched: %', n; END IF;
END $$;
