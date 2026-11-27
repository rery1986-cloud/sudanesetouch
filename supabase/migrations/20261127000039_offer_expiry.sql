-- Offers: a service discount stops applying after the offer's end date (ends_at). Replaces one function (bookings_guard) with a single changed line; the trigger stays attached.
-- Run as one migration, exactly as written.
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
    NEW.total_amount := round(off.price * (1 - (CASE WHEN off.ends_at IS NULL OR off.ends_at > now() THEN off.discount_percent ELSE 0 END) / 100), 2);
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
