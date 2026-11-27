-- Regional moderators are provisioned by an administrator or a trusted server only.
-- They are intentionally excluded from public sign-up metadata handling.
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS region text;

ALTER TABLE public.profiles
  DROP CONSTRAINT IF EXISTS profiles_role_check;

ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_role_check
  CHECK (role IN ('client', 'provider', 'merchant', 'moderator'));

COMMENT ON COLUMN public.profiles.region IS
  'Administrative region/ولاية for a moderator scope; never set from public sign-up.';
