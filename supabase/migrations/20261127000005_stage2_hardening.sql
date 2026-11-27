-- Stage 2 hardening, part 1 of 4. Run as one migration, exactly as written.
-- Stage 2 hardening on the live schema (additive; no data changes).
-- Tables: service_providers, merchants, service_offers, bookings, advertisements.

-- 0) helper: updated_at
CREATE OR REPLACE FUNCTION public.touch_updated_at()
RETURNS trigger LANGUAGE plpgsql SET search_path = ''
AS $$ BEGIN NEW.updated_at := now(); RETURN NEW; END; $$;

-- 1) new columns (photos, booking place) and booking numbers
ALTER TABLE public.service_providers ADD COLUMN IF NOT EXISTS avatar_url text;
ALTER TABLE public.merchants ADD COLUMN IF NOT EXISTS avatar_url text;
ALTER TABLE public.service_offers ADD COLUMN IF NOT EXISTS image_url text;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS location_type text;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS address text;
CREATE SEQUENCE IF NOT EXISTS public.booking_number_seq;

-- 2) value checks
ALTER TABLE public.service_providers DROP CONSTRAINT IF EXISTS service_providers_status_chk;
ALTER TABLE public.service_providers ADD CONSTRAINT service_providers_status_chk CHECK (verification_status IN ('pending','approved','rejected'));
ALTER TABLE public.merchants DROP CONSTRAINT IF EXISTS merchants_status_chk;
ALTER TABLE public.merchants ADD CONSTRAINT merchants_status_chk CHECK (verification_status IN ('pending','approved','rejected'));
ALTER TABLE public.service_offers DROP CONSTRAINT IF EXISTS service_offers_status_chk;
ALTER TABLE public.service_offers ADD CONSTRAINT service_offers_status_chk CHECK (status IN ('draft','published','archived'));
ALTER TABLE public.service_offers DROP CONSTRAINT IF EXISTS service_offers_price_chk;
ALTER TABLE public.service_offers ADD CONSTRAINT service_offers_price_chk CHECK (price >= 0 AND discount_percent >= 0 AND discount_percent <= 100);
ALTER TABLE public.advertisements DROP CONSTRAINT IF EXISTS advertisements_status_chk;
ALTER TABLE public.advertisements ADD CONSTRAINT advertisements_status_chk CHECK (status IN ('draft','pending','active','paused','rejected','ended'));
ALTER TABLE public.bookings DROP CONSTRAINT IF EXISTS bookings_location_type_chk;
ALTER TABLE public.bookings ADD CONSTRAINT bookings_location_type_chk CHECK (location_type IS NULL OR location_type IN ('home','provider_place'));

-- 3) column grants: owners cannot touch approval status, rating or ids; phone numbers are not public
REVOKE ALL ON public.service_providers FROM anon, authenticated;
GRANT SELECT (id, display_name, bio, service_categories, city, district, is_available, average_rating, avatar_url, verification_status, created_at)
  ON public.service_providers TO anon;
GRANT SELECT (id, user_id, display_name, bio, service_categories, city, district, is_available, average_rating, avatar_url, verification_status, created_at, updated_at)
  ON public.service_providers TO authenticated;
GRANT INSERT (user_id, display_name, bio, service_categories, city, district, contact_phone, is_available, avatar_url)
  ON public.service_providers TO authenticated;
GRANT UPDATE (display_name, bio, service_categories, city, district, contact_phone, is_available, avatar_url)
  ON public.service_providers TO authenticated;

REVOKE ALL ON public.merchants FROM anon, authenticated;
GRANT SELECT (id, display_name, business_name, description, city, district, is_available, avatar_url, verification_status, created_at)
  ON public.merchants TO anon;
GRANT SELECT (id, user_id, display_name, business_name, description, city, district, is_available, avatar_url, verification_status, created_at, updated_at)
  ON public.merchants TO authenticated;
GRANT INSERT (user_id, display_name, business_name, description, city, district, contact_phone, is_available, avatar_url)
  ON public.merchants TO authenticated;
GRANT UPDATE (display_name, business_name, description, city, district, contact_phone, is_available, avatar_url)
  ON public.merchants TO authenticated;

REVOKE ALL ON public.service_offers FROM anon, authenticated;
GRANT SELECT ON public.service_offers TO anon, authenticated;
GRANT INSERT (provider_id, title, description, category, price, currency, duration_minutes, discount_percent, status, starts_at, ends_at, image_url)
  ON public.service_offers TO authenticated;
GRANT UPDATE (title, description, category, price, currency, duration_minutes, discount_percent, status, starts_at, ends_at, image_url)
  ON public.service_offers TO authenticated;

-- 4) offers are public only when published AND the provider is approved and available
DROP POLICY IF EXISTS offers_public_published ON public.service_offers;
CREATE POLICY offers_public_published ON public.service_offers
  FOR SELECT TO anon, authenticated
  USING (status = 'published' AND EXISTS (
    SELECT 1 FROM public.service_providers sp
    WHERE sp.id = service_offers.provider_id AND sp.verification_status = 'approved' AND sp.is_available));

-- 5) updated_at triggers
DROP TRIGGER IF EXISTS touch_service_providers ON public.service_providers;
CREATE TRIGGER touch_service_providers BEFORE UPDATE ON public.service_providers FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();
DROP TRIGGER IF EXISTS touch_merchants ON public.merchants;
CREATE TRIGGER touch_merchants BEFORE UPDATE ON public.merchants FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();
DROP TRIGGER IF EXISTS touch_service_offers ON public.service_offers;
CREATE TRIGGER touch_service_offers BEFORE UPDATE ON public.service_offers FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();
-- Stage 2 hardening, part 2 of 4. Run as one migration, exactly as written.
-- 6) bookings guard: price, provider and status are set by the server
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
DROP TRIGGER IF EXISTS bookings_guard ON public.bookings;
CREATE TRIGGER bookings_guard BEFORE INSERT OR UPDATE ON public.bookings
  FOR EACH ROW EXECUTE FUNCTION public.bookings_guard();

-- 7) advertisements guard: advertisers cannot activate their own ads or edit counters
CREATE OR REPLACE FUNCTION public.advertisements_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE actor uuid := (SELECT auth.uid());
BEGIN
  IF actor IS NULL OR private.is_platform_admin() THEN RETURN NEW; END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status NOT IN ('draft','pending') THEN NEW.status := 'pending'; END IF;
    NEW.impressions := 0; NEW.clicks := 0; NEW.advertiser_user_id := actor;
  ELSE
    NEW.impressions := OLD.impressions; NEW.clicks := OLD.clicks; NEW.advertiser_user_id := OLD.advertiser_user_id;
    IF NEW.status IS DISTINCT FROM OLD.status AND NOT (NEW.status IN ('draft','pending') AND OLD.status IN ('draft','pending','rejected','paused')) THEN
      NEW.status := OLD.status;
    END IF;
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.advertisements_guard() FROM PUBLIC;
DROP TRIGGER IF EXISTS advertisements_guard ON public.advertisements;
CREATE TRIGGER advertisements_guard BEFORE INSERT OR UPDATE ON public.advertisements
  FOR EACH ROW EXECUTE FUNCTION public.advertisements_guard();
-- Stage 2 hardening, part 3 of 4. Run as one migration, exactly as written.
-- 8) admin-only status changes and lists (the only way to approve)
CREATE OR REPLACE FUNCTION public.set_provider_status(p_provider_id uuid, p_status text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  IF NOT private.is_platform_admin() THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF p_status NOT IN ('pending','approved','rejected') THEN RAISE EXCEPTION 'invalid status'; END IF;
  UPDATE public.service_providers SET verification_status = p_status WHERE id = p_provider_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'provider not found'; END IF;
END;
$$;
CREATE OR REPLACE FUNCTION public.set_merchant_status(p_merchant_id uuid, p_status text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  IF NOT private.is_platform_admin() THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF p_status NOT IN ('pending','approved','rejected') THEN RAISE EXCEPTION 'invalid status'; END IF;
  UPDATE public.merchants SET verification_status = p_status WHERE id = p_merchant_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'merchant not found'; END IF;
END;
$$;
CREATE OR REPLACE FUNCTION public.set_ad_status(p_ad_id uuid, p_status text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  IF NOT private.is_platform_admin() THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF p_status NOT IN ('draft','pending','active','paused','rejected','ended') THEN RAISE EXCEPTION 'invalid status'; END IF;
  UPDATE public.advertisements SET status = p_status WHERE id = p_ad_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'ad not found'; END IF;
END;
$$;
CREATE OR REPLACE FUNCTION public.admin_list_providers(p_status text DEFAULT NULL)
RETURNS TABLE (id uuid, user_id uuid, display_name text, bio text, service_categories text[], city text, district text,
               contact_phone text, verification_status text, is_available boolean, created_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  IF NOT private.is_platform_admin() THEN RAISE EXCEPTION 'not allowed'; END IF;
  RETURN QUERY SELECT sp.id, sp.user_id, sp.display_name, sp.bio, sp.service_categories, sp.city, sp.district,
    sp.contact_phone, sp.verification_status, sp.is_available, sp.created_at
    FROM public.service_providers sp WHERE p_status IS NULL OR sp.verification_status = p_status
    ORDER BY sp.created_at DESC;
END;
$$;
CREATE OR REPLACE FUNCTION public.admin_list_merchants(p_status text DEFAULT NULL)
RETURNS TABLE (id uuid, user_id uuid, display_name text, business_name text, description text, city text, district text,
               contact_phone text, verification_status text, is_available boolean, created_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  IF NOT private.is_platform_admin() THEN RAISE EXCEPTION 'not allowed'; END IF;
  RETURN QUERY SELECT m.id, m.user_id, m.display_name, m.business_name, m.description, m.city, m.district,
    m.contact_phone, m.verification_status, m.is_available, m.created_at
    FROM public.merchants m WHERE p_status IS NULL OR m.verification_status = p_status
    ORDER BY m.created_at DESC;
END;
$$;

-- 9) phone numbers: visible only to the owner, the admin, or a customer with a confirmed booking
CREATE OR REPLACE FUNCTION public.get_provider_contact(p_provider_id uuid)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE actor uuid := (SELECT auth.uid()); phone text;
BEGIN
  IF actor IS NULL THEN RETURN NULL; END IF;
  SELECT sp.contact_phone INTO phone FROM public.service_providers sp
  WHERE sp.id = p_provider_id AND (
    sp.user_id = actor
    OR private.is_platform_admin()
    OR EXISTS (SELECT 1 FROM public.bookings b JOIN public.customers c ON c.id = b.customer_id
               WHERE b.provider_id = sp.id AND c.user_id = actor AND b.status IN ('confirmed','in_progress','completed')));
  RETURN phone;
END;
$$;

REVOKE ALL ON FUNCTION public.set_provider_status(uuid, text), public.set_merchant_status(uuid, text), public.set_ad_status(uuid, text),
  public.admin_list_providers(text), public.admin_list_merchants(text), public.get_provider_contact(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_provider_status(uuid, text), public.set_merchant_status(uuid, text), public.set_ad_status(uuid, text),
  public.admin_list_providers(text), public.admin_list_merchants(text), public.get_provider_contact(uuid) TO authenticated;
-- Stage 2 hardening, part 4 of 4. Run as one migration, exactly as written.
-- 10) portfolio photos
CREATE TABLE IF NOT EXISTS public.portfolio_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_id uuid NOT NULL REFERENCES public.service_providers(id) ON DELETE CASCADE,
  image_url text NOT NULL,
  caption text,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.portfolio_items ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.portfolio_items FROM anon, authenticated;
GRANT SELECT ON public.portfolio_items TO anon, authenticated;
GRANT INSERT (provider_id, image_url, caption), DELETE ON public.portfolio_items TO authenticated;
DROP POLICY IF EXISTS portfolio_public_select ON public.portfolio_items;
CREATE POLICY portfolio_public_select ON public.portfolio_items FOR SELECT TO anon, authenticated
  USING (EXISTS (SELECT 1 FROM public.service_providers sp WHERE sp.id = provider_id AND sp.verification_status = 'approved')
         OR EXISTS (SELECT 1 FROM public.service_providers sp WHERE sp.id = provider_id AND sp.user_id = (SELECT auth.uid()))
         OR private.is_platform_admin());
DROP POLICY IF EXISTS portfolio_owner_insert ON public.portfolio_items;
CREATE POLICY portfolio_owner_insert ON public.portfolio_items FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM public.service_providers sp WHERE sp.id = provider_id AND sp.user_id = (SELECT auth.uid())));
DROP POLICY IF EXISTS portfolio_owner_delete ON public.portfolio_items;
CREATE POLICY portfolio_owner_delete ON public.portfolio_items FOR DELETE TO authenticated
  USING (EXISTS (SELECT 1 FROM public.service_providers sp WHERE sp.id = provider_id AND sp.user_id = (SELECT auth.uid())) OR private.is_platform_admin());
