-- 000015 discount codes. One single-use code per completed booking. Provider funds the discount. Cap 20%.
CREATE TABLE IF NOT EXISTS public.discount_settings (
  id int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  issue_enabled boolean NOT NULL DEFAULT false,
  issue_percent numeric(4,1) NOT NULL DEFAULT 5 CHECK (issue_percent >= 1 AND issue_percent <= 20),
  validity_days int NOT NULL DEFAULT 30 CHECK (validity_days >= 1 AND validity_days <= 365)
);
INSERT INTO public.discount_settings (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
ALTER TABLE public.discount_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.discount_settings FROM anon, authenticated;

CREATE TABLE IF NOT EXISTS public.discount_codes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text NOT NULL UNIQUE,
  percent numeric(4,1) NOT NULL CHECK (percent > 0 AND percent <= 20),
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  source_booking_id uuid,
  valid_from timestamptz NOT NULL DEFAULT now(),
  valid_to timestamptz NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  used_booking_id uuid,
  used_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS discount_codes_source_booking_uq ON public.discount_codes (source_booking_id) WHERE source_booking_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS discount_codes_user_idx ON public.discount_codes (user_id);
ALTER TABLE public.discount_codes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.discount_codes FROM anon, authenticated;

ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS discount_code text;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS discount_percent numeric(4,1) NOT NULL DEFAULT 0;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS discount_amount numeric(12,2) NOT NULL DEFAULT 0;
GRANT INSERT (discount_code) ON public.bookings TO authenticated;

CREATE OR REPLACE FUNCTION public.bookings_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  actor uuid := (SELECT auth.uid());
  is_admin boolean := false;
  is_customer boolean := false;
  is_provider boolean := false;
  off public.service_offers%ROWTYPE;
  prov public.service_providers%ROWTYPE;
  dc public.discount_codes%ROWTYPE;
  want_code text;
BEGIN
  IF actor IS NULL THEN
    IF TG_OP = 'INSERT' AND NEW.booking_number IS NULL THEN NEW.booking_number := nextval('public.booking_number_seq'); END IF;
    RETURN NEW;
  END IF;
  is_admin := private.is_platform_admin();

  IF TG_OP = 'INSERT' THEN
    IF NEW.booking_number IS NULL THEN NEW.booking_number := nextval('public.booking_number_seq'); END IF;
    IF is_admin THEN RETURN NEW; END IF;
    IF NEW.offer_id IS NULL THEN RAISE EXCEPTION 'offer is required'; END IF;
    SELECT * INTO off FROM public.service_offers WHERE id = NEW.offer_id;
    IF NOT FOUND OR off.status <> 'published' THEN RAISE EXCEPTION 'offer not available'; END IF;
    SELECT * INTO prov FROM public.service_providers WHERE id = off.provider_id;
    IF NOT FOUND OR prov.verification_status <> 'approved' OR NOT prov.is_available THEN RAISE EXCEPTION 'provider not available'; END IF;
    IF prov.user_id = actor THEN RAISE EXCEPTION 'cannot book your own service'; END IF;
    IF NEW.scheduled_at <= now() THEN RAISE EXCEPTION 'booking time must be in the future'; END IF;
    NEW.provider_id := off.provider_id;
    NEW.total_amount := round(off.price * (1 - off.discount_percent / 100), 2);
    NEW.currency := off.currency;
    NEW.status := 'pending';
    NEW.provider_notes := NULL;
    want_code := upper(btrim(coalesce(NEW.discount_code, '')));
    NEW.discount_code := NULL;
    NEW.discount_percent := 0;
    NEW.discount_amount := 0;
    IF want_code <> '' THEN
      SELECT * INTO dc FROM public.discount_codes WHERE code = want_code FOR UPDATE;
      IF NOT FOUND OR NOT dc.is_active OR dc.used_booking_id IS NOT NULL OR dc.user_id <> actor
         OR now() < dc.valid_from OR now() > dc.valid_to THEN
        RAISE EXCEPTION 'invalid discount code';
      END IF;
      NEW.discount_code := dc.code;
      NEW.discount_percent := least(dc.percent, 20);
      NEW.discount_amount := round(NEW.total_amount * NEW.discount_percent / 100, 2);
      NEW.total_amount := NEW.total_amount - NEW.discount_amount;
      UPDATE public.discount_codes SET used_booking_id = NEW.id, used_at = now() WHERE id = dc.id;
    END IF;
    RETURN NEW;
  END IF;

  -- UPDATE
  NEW.updated_at := now();
  IF is_admin THEN RETURN NEW; END IF;
  IF NEW.id IS DISTINCT FROM OLD.id OR NEW.booking_number IS DISTINCT FROM OLD.booking_number
     OR NEW.customer_id IS DISTINCT FROM OLD.customer_id OR NEW.provider_id IS DISTINCT FROM OLD.provider_id
     OR NEW.offer_id IS DISTINCT FROM OLD.offer_id OR NEW.scheduled_at IS DISTINCT FROM OLD.scheduled_at
     OR NEW.total_amount IS DISTINCT FROM OLD.total_amount OR NEW.currency IS DISTINCT FROM OLD.currency
     OR NEW.location_type IS DISTINCT FROM OLD.location_type OR NEW.address IS DISTINCT FROM OLD.address
     OR NEW.discount_code IS DISTINCT FROM OLD.discount_code OR NEW.discount_percent IS DISTINCT FROM OLD.discount_percent
     OR NEW.discount_amount IS DISTINCT FROM OLD.discount_amount
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'these booking fields cannot be changed';
  END IF;
  is_customer := EXISTS (SELECT 1 FROM public.customers c WHERE c.id = OLD.customer_id AND c.user_id = actor);
  is_provider := EXISTS (SELECT 1 FROM public.service_providers sp WHERE sp.id = OLD.provider_id AND sp.user_id = actor);
  IF is_customer THEN
    IF NEW.provider_notes IS DISTINCT FROM OLD.provider_notes THEN RAISE EXCEPTION 'not allowed'; END IF;
    IF NEW.status IS DISTINCT FROM OLD.status AND NOT (NEW.status = 'cancelled' AND OLD.status IN ('pending','confirmed')) THEN
      RAISE EXCEPTION 'status change not allowed';
    END IF;
    RETURN NEW;
  ELSIF is_provider THEN
    IF NEW.customer_notes IS DISTINCT FROM OLD.customer_notes THEN RAISE EXCEPTION 'not allowed'; END IF;
    IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
         (OLD.status = 'pending' AND NEW.status IN ('confirmed','rejected'))
      OR (OLD.status = 'confirmed' AND NEW.status IN ('in_progress','completed','no_show','cancelled'))
      OR (OLD.status = 'in_progress' AND NEW.status = 'completed')) THEN
      RAISE EXCEPTION 'status change not allowed';
    END IF;
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'not allowed';
END;
$$;
REVOKE ALL ON FUNCTION public.bookings_guard() FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.discount_after_booking_update()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE s public.discount_settings%ROWTYPE; cust_user uuid;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN RETURN NEW; END IF;
  IF NEW.status = 'completed' THEN
    SELECT * INTO s FROM public.discount_settings WHERE id = 1;
    IF FOUND AND s.issue_enabled THEN
      SELECT c.user_id INTO cust_user FROM public.customers c WHERE c.id = NEW.customer_id;
      IF cust_user IS NOT NULL THEN
        INSERT INTO public.discount_codes (code, percent, user_id, source_booking_id, valid_to)
        VALUES ('LM' || upper(substr(md5(random()::text || clock_timestamp()::text || NEW.id::text), 1, 8)),
                least(s.issue_percent, 20), cust_user, NEW.id, now() + make_interval(days => s.validity_days))
        ON CONFLICT DO NOTHING;
      END IF;
    END IF;
  ELSIF NEW.status IN ('cancelled', 'rejected', 'no_show') THEN
    UPDATE public.discount_codes SET used_booking_id = NULL, used_at = NULL WHERE used_booking_id = NEW.id;
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.discount_after_booking_update() FROM PUBLIC;
DROP TRIGGER IF EXISTS discount_after_booking_update ON public.bookings;
CREATE TRIGGER discount_after_booking_update AFTER UPDATE OF status ON public.bookings
  FOR EACH ROW EXECUTE FUNCTION public.discount_after_booking_update();

CREATE OR REPLACE FUNCTION public.my_discount_codes()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('code', code, 'percent', percent, 'valid_to', valid_to) ORDER BY valid_to), '[]'::jsonb)
  FROM public.discount_codes
  WHERE user_id = (SELECT auth.uid()) AND is_active AND used_booking_id IS NULL AND now() BETWEEN valid_from AND valid_to;
$$;

CREATE OR REPLACE FUNCTION public.validate_discount_code(p_code text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE dc public.discount_codes%ROWTYPE;
BEGIN
  SELECT * INTO dc FROM public.discount_codes WHERE code = upper(btrim(coalesce(p_code, '')));
  IF NOT FOUND OR NOT dc.is_active OR dc.used_booking_id IS NOT NULL OR dc.user_id <> (SELECT auth.uid())
     OR now() < dc.valid_from OR now() > dc.valid_to THEN
    RETURN jsonb_build_object('valid', false);
  END IF;
  RETURN jsonb_build_object('valid', true, 'percent', dc.percent);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_get_discount_settings()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE r jsonb;
BEGIN
  IF NOT private.is_platform_admin() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT to_jsonb(s) INTO r FROM public.discount_settings s WHERE id = 1;
  RETURN r;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_discount_settings(p_enabled boolean, p_percent numeric, p_days int)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  IF NOT private.is_platform_admin() THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF p_percent < 1 OR p_percent > 20 THEN RAISE EXCEPTION 'percent must be between 1 and 20'; END IF;
  IF p_days < 1 OR p_days > 365 THEN RAISE EXCEPTION 'days must be between 1 and 365'; END IF;
  UPDATE public.discount_settings SET issue_enabled = p_enabled, issue_percent = p_percent, validity_days = p_days WHERE id = 1;
  RETURN jsonb_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_list_discount_codes()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE r jsonb;
BEGIN
  IF NOT private.is_platform_admin() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) INTO r FROM (
    SELECT d.id, d.code, d.percent, d.valid_to, d.is_active, d.used_at, d.created_at,
           p.full_name AS client_name, p.email AS client_email
    FROM public.discount_codes d LEFT JOIN public.profiles p ON p.id = d.user_id
    ORDER BY d.created_at DESC LIMIT 1000
  ) t;
  RETURN r;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_discount_code_active(p_id uuid, p_active boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  IF NOT private.is_platform_admin() THEN RAISE EXCEPTION 'not allowed'; END IF;
  UPDATE public.discount_codes SET is_active = p_active WHERE id = p_id;
  RETURN jsonb_build_object('ok', true);
END;
$$;

REVOKE ALL ON FUNCTION public.my_discount_codes(), public.validate_discount_code(text), public.admin_get_discount_settings(),
  public.admin_set_discount_settings(boolean, numeric, int), public.admin_list_discount_codes(),
  public.admin_set_discount_code_active(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_discount_codes(), public.validate_discount_code(text), public.admin_get_discount_settings(),
  public.admin_set_discount_settings(boolean, numeric, int), public.admin_list_discount_codes(),
  public.admin_set_discount_code_active(uuid, boolean) TO authenticated;
