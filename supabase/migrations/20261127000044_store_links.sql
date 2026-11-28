-- Store profile: add public store email and social links to merchants, and let visitors read them. Changes no existing data. Run as one migration, exactly as written.
ALTER TABLE public.merchants ADD COLUMN IF NOT EXISTS store_email text;
ALTER TABLE public.merchants ADD COLUMN IF NOT EXISTS social_links jsonb NOT NULL DEFAULT '{}'::jsonb;
GRANT SELECT (store_email, social_links) ON public.merchants TO anon, authenticated;
GRANT INSERT (store_email, social_links) ON public.merchants TO authenticated;
GRANT UPDATE (store_email, social_links) ON public.merchants TO authenticated;
