-- Store profile: add an optional store QR image (for example a TikTok QR) to merchants, and let visitors read it. Changes no existing data. Run as one migration, exactly as written.
ALTER TABLE public.merchants ADD COLUMN IF NOT EXISTS qr_url text;
GRANT SELECT (qr_url) ON public.merchants TO anon, authenticated;
GRANT INSERT (qr_url) ON public.merchants TO authenticated;
GRANT UPDATE (qr_url) ON public.merchants TO authenticated;
