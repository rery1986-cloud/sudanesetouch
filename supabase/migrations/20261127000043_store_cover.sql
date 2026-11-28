-- Store profile: add a cover image column to merchants and let visitors read it. Changes no existing data. Run as one migration, exactly as written.
ALTER TABLE public.merchants ADD COLUMN IF NOT EXISTS cover_url text;
GRANT SELECT (cover_url) ON public.merchants TO anon, authenticated;
GRANT INSERT (cover_url) ON public.merchants TO authenticated;
GRANT UPDATE (cover_url) ON public.merchants TO authenticated;
