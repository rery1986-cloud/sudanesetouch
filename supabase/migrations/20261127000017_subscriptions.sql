-- 000017 subscriptions foundation. Everything is OFF until the admin switches subscriptions_enabled on.
CREATE TABLE IF NOT EXISTS public.subscription_settings (
  id int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  subscriptions_enabled boolean NOT NULL DEFAULT false,
  trial_months int NOT NULL DEFAULT 3 CHECK (trial_months BETWEEN 0 AND 24),
  bank_name text, bank_holder text, bank_iban text, bank_note text,
  commission_enabled boolean NOT NULL DEFAULT false,
  commission_percent numeric(4,1) NOT NULL DEFAULT 0 CHECK (commission_percent >= 0 AND commission_percent <= 30)
);
INSERT INTO public.subscription_settings (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
ALTER TABLE public.subscription_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.subscription_settings FROM anon, authenticated;

CREATE TABLE IF NOT EXISTS public.subscription_plans (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  audience text NOT NULL CHECK (audience IN ('provider', 'merchant')),
  code text NOT NULL CHECK (code IN ('monthly', 'quarterly', 'yearly')),
  name_ar text NOT NULL,
  months int NOT NULL CHECK (months > 0),
  price numeric(10,2) NOT NULL CHECK (price >= 0),
  currency char(3) NOT NULL DEFAULT 'SAR',
  features text[] NOT NULL DEFAULT '{}',
  badge text,
  is_active boolean NOT NULL DEFAULT true,
  sort int NOT NULL DEFAULT 0,
  UNIQUE (audience, code)
);
ALTER TABLE public.subscription_plans ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.subscription_plans FROM anon, authenticated;

INSERT INTO public.subscription_plans (audience, code, name_ar, months, price, features, badge, sort) VALUES
 ('provider', 'monthly', 'الباقة الشهرية', 1, 49, ARRAY['ظهور ملفك وخدماتك في البحث','استقبال الحجوزات بلا حد','محادثة مباشرة مع العميلات','معرض أعمال وتقييمات حقيقية','إدارة الخدمات والأسعار'], NULL, 1),
 ('provider', 'quarterly', 'باقة 3 أشهر', 3, 129, ARRAY['كل مزايا الباقة الشهرية','سعر أوفر من الاشتراك الشهري','استقرار حسابك 3 أشهر بلا تجديد شهري','شارة الباقة المميزة (قريباً)'], 'الأكثر طلباً', 2),
 ('provider', 'yearly', 'الباقة السنوية', 12, 449, ARRAY['كل مزايا باقة 3 أشهر','أكبر توفير مقارنة بالشهري','سنة كاملة بلا تجديد','أولوية في الدعم (قريباً)'], 'أفضل قيمة', 3),
 ('merchant', 'monthly', 'الباقة الشهرية', 1, 59, ARRAY['متجرك ومنتجاتك ظاهرة في السوق','محادثة مباشرة مع العميلات','صفحة متجر خاصة بك','إدارة المنتجات والأسعار'], NULL, 1),
 ('merchant', 'quarterly', 'باقة 3 أشهر', 3, 159, ARRAY['كل مزايا الباقة الشهرية','سعر أوفر من الاشتراك الشهري','استقرار متجرك 3 أشهر بلا تجديد شهري','شارة الباقة المميزة (قريباً)'], 'الأكثر طلباً', 2),
 ('merchant', 'yearly', 'الباقة السنوية', 12, 549, ARRAY['كل مزايا باقة 3 أشهر','أكبر توفير مقارنة بالشهري','سنة كاملة بلا تجديد','أولوية في الدعم (قريباً)'], 'أفضل قيمة', 3)
ON CONFLICT (audience, code) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.subscription_payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  plan_id uuid NOT NULL REFERENCES public.subscription_plans (id),
  months int NOT NULL,
  amount numeric(10,2) NOT NULL,
  currency char(3) NOT NULL,
  method text NOT NULL DEFAULT 'bank_transfer',
  receipt_path text NOT NULL,
  note text,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
  admin_note text,
  reviewed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS subscription_payments_user_idx ON public.subscription_payments (user_id, created_at DESC);
ALTER TABLE public.subscription_payments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.subscription_payments FROM anon, authenticated;

CREATE TABLE IF NOT EXISTS public.subscriptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  plan_id uuid REFERENCES public.subscription_plans (id),
  payment_id uuid REFERENCES public.subscription_payments (id),
  starts_at timestamptz NOT NULL,
  ends_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS subscriptions_user_idx ON public.subscriptions (user_id, ends_at DESC);
ALTER TABLE public.subscriptions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.subscriptions FROM anon, authenticated;

ALTER TABLE public.service_providers ADD COLUMN IF NOT EXISTS subscription_paused boolean NOT NULL DEFAULT false;
ALTER TABLE public.merchants ADD COLUMN IF NOT EXISTS subscription_paused boolean NOT NULL DEFAULT false;
GRANT SELECT (subscription_paused) ON public.service_providers TO anon, authenticated;
GRANT SELECT (subscription_paused) ON public.merchants TO anon, authenticated;

CREATE OR REPLACE FUNCTION private.keep_paused_unavailable()
RETURNS trigger LANGUAGE plpgsql SET search_path = ''
AS $$
BEGIN
  IF NEW.subscription_paused AND NEW.is_available THEN NEW.is_available := false; END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS keep_paused_unavailable ON public.service_providers;
CREATE TRIGGER keep_paused_unavailable BEFORE UPDATE ON public.service_providers FOR EACH ROW EXECUTE FUNCTION private.keep_paused_unavailable();
DROP TRIGGER IF EXISTS keep_paused_unavailable ON public.merchants;
CREATE TRIGGER keep_paused_unavailable BEFORE UPDATE ON public.merchants FOR EACH ROW EXECUTE FUNCTION private.keep_paused_unavailable();

CREATE OR REPLACE FUNCTION private.sub_live(p_user uuid)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE s public.subscription_settings%ROWTYPE; created timestamptz;
BEGIN
  SELECT * INTO s FROM public.subscription_settings WHERE id = 1;
  IF NOT FOUND OR NOT s.subscriptions_enabled THEN RETURN true; END IF;
  IF EXISTS (SELECT 1 FROM public.platform_admins a WHERE a.user_id = p_user) THEN RETURN true; END IF;
  IF EXISTS (SELECT 1 FROM public.subscriptions x WHERE x.user_id = p_user AND x.ends_at > now()) THEN RETURN true; END IF;
  SELECT u.created_at INTO created FROM auth.users u WHERE u.id = p_user;
  IF created IS NULL THEN RETURN true; END IF;
  RETURN created + make_interval(months => s.trial_months) > now();
END;
$$;

CREATE OR REPLACE FUNCTION private.sub_sync_all()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  UPDATE public.service_providers sp SET subscription_paused = NOT private.sub_live(sp.user_id), is_available = private.sub_live(sp.user_id)
   WHERE sp.subscription_paused <> (NOT private.sub_live(sp.user_id));
  UPDATE public.merchants m SET subscription_paused = NOT private.sub_live(m.user_id), is_available = private.sub_live(m.user_id)
   WHERE m.subscription_paused <> (NOT private.sub_live(m.user_id));
END;
$$;

CREATE OR REPLACE FUNCTION public.sync_subscription_state()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  IF (SELECT auth.uid()) IS NULL THEN RAISE EXCEPTION 'not allowed'; END IF;
  PERFORM private.sub_sync_all();
  RETURN jsonb_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.my_subscription_status()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  actor uuid := (SELECT auth.uid());
  s public.subscription_settings%ROWTYPE;
  created timestamptz; atype text; aud text; trial_end timestamptz; sub_end timestamptz; st text;
BEGIN
  IF actor IS NULL THEN RETURN jsonb_build_object('enabled', false); END IF;
  SELECT * INTO s FROM public.subscription_settings WHERE id = 1;
  SELECT p.account_type INTO atype FROM public.profiles p WHERE p.id = actor;
  aud := CASE atype WHEN 'service_provider' THEN 'provider' WHEN 'merchant' THEN 'merchant' ELSE NULL END;
  IF aud IS NULL OR NOT s.subscriptions_enabled THEN RETURN jsonb_build_object('enabled', false, 'audience', aud); END IF;
  SELECT u.created_at INTO created FROM auth.users u WHERE u.id = actor;
  trial_end := created + make_interval(months => s.trial_months);
  SELECT max(x.ends_at) INTO sub_end FROM public.subscriptions x WHERE x.user_id = actor;
  st := CASE WHEN sub_end IS NOT NULL AND sub_end > now() THEN 'active' WHEN trial_end > now() THEN 'trial' ELSE 'paused' END;
  RETURN jsonb_build_object('enabled', true, 'audience', aud, 'status', st, 'trial_ends_at', trial_end, 'sub_ends_at', sub_end,
    'days_left', CASE st WHEN 'trial' THEN ceil(extract(epoch FROM (trial_end - now())) / 86400.0) WHEN 'active' THEN ceil(extract(epoch FROM (sub_end - now())) / 86400.0) ELSE 0 END,
    'pending_payment', EXISTS (SELECT 1 FROM public.subscription_payments pp WHERE pp.user_id = actor AND pp.status = 'pending'));
END;
$$;

CREATE OR REPLACE FUNCTION public.get_subscription_plans()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE actor uuid := (SELECT auth.uid()); s public.subscription_settings%ROWTYPE; atype text; aud text;
BEGIN
  IF actor IS NULL THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO s FROM public.subscription_settings WHERE id = 1;
  IF private.is_platform_admin() THEN aud := NULL;
  ELSE
    IF NOT s.subscriptions_enabled THEN RETURN jsonb_build_object('enabled', false, 'plans', '[]'::jsonb); END IF;
    SELECT p.account_type INTO atype FROM public.profiles p WHERE p.id = actor;
    aud := CASE atype WHEN 'service_provider' THEN 'provider' WHEN 'merchant' THEN 'merchant' ELSE 'none' END;
  END IF;
  RETURN jsonb_build_object('enabled', s.subscriptions_enabled,
    'bank', jsonb_build_object('name', s.bank_name, 'holder', s.bank_holder, 'iban', s.bank_iban, 'note', s.bank_note),
    'plans', (SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.audience, t.sort), '[]'::jsonb) FROM (
       SELECT id, audience, code, name_ar, months, price, currency, features, badge, sort, is_active FROM public.subscription_plans
       WHERE aud IS NULL OR (is_active AND audience = aud)) t));
END;
$$;

CREATE OR REPLACE FUNCTION public.submit_subscription_payment(p_plan_id uuid, p_receipt_path text, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE actor uuid := (SELECT auth.uid()); s public.subscription_settings%ROWTYPE; pl public.subscription_plans%ROWTYPE; atype text; pid uuid; pname text;
BEGIN
  IF actor IS NULL THEN RAISE EXCEPTION 'سجّلي الدخول أولاً'; END IF;
  SELECT * INTO s FROM public.subscription_settings WHERE id = 1;
  IF NOT s.subscriptions_enabled THEN RAISE EXCEPTION 'الاشتراكات غير مفعلة حالياً'; END IF;
  SELECT * INTO pl FROM public.subscription_plans WHERE id = p_plan_id AND is_active;
  IF NOT FOUND THEN RAISE EXCEPTION 'الباقة غير متاحة'; END IF;
  SELECT p.account_type, p.full_name INTO atype, pname FROM public.profiles p WHERE p.id = actor;
  IF (CASE atype WHEN 'service_provider' THEN 'provider' WHEN 'merchant' THEN 'merchant' ELSE 'none' END) <> pl.audience THEN RAISE EXCEPTION 'هذه الباقة لا تناسب نوع حسابك'; END IF;
  IF p_receipt_path IS NULL OR left(p_receipt_path, length(actor::text) + 1) <> actor::text || '/' THEN RAISE EXCEPTION 'ملف الإيصال غير صالح'; END IF;
  INSERT INTO public.subscription_payments (user_id, plan_id, months, amount, currency, receipt_path, note)
  VALUES (actor, pl.id, pl.months, pl.price, pl.currency, p_receipt_path, left(p_note, 500)) RETURNING id INTO pid;
  BEGIN
    INSERT INTO public.admin_notifications (kind, title, body, ref_user_id)
    VALUES ('subscription_payment', 'إيصال اشتراك جديد: ' || coalesce(pname, ''), pl.name_ar || ' - ' || pl.price || ' ' || pl.currency, actor);
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  RETURN jsonb_build_object('id', pid);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_list_subscription_payments()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE r jsonb;
BEGIN
  IF NOT private.is_platform_admin() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) INTO r FROM (
    SELECT sp.id, sp.amount, sp.currency, sp.months, sp.receipt_path, sp.note, sp.status, sp.admin_note, sp.created_at,
           p.full_name AS user_name, p.email AS user_email, p.account_type, pl.name_ar AS plan_name
    FROM public.subscription_payments sp
    LEFT JOIN public.profiles p ON p.id = sp.user_id
    LEFT JOIN public.subscription_plans pl ON pl.id = sp.plan_id
    ORDER BY (sp.status = 'pending') DESC, sp.created_at DESC LIMIT 500
  ) t;
  RETURN r;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_review_subscription_payment(p_id uuid, p_approve boolean, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE pay public.subscription_payments%ROWTYPE; start_at timestamptz;
BEGIN
  IF NOT private.is_platform_admin() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO pay FROM public.subscription_payments WHERE id = p_id FOR UPDATE;
  IF NOT FOUND OR pay.status <> 'pending' THEN RAISE EXCEPTION 'الدفعة غير موجودة أو تمت مراجعتها'; END IF;
  UPDATE public.subscription_payments SET status = CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END, admin_note = p_note, reviewed_at = now() WHERE id = p_id;
  IF p_approve THEN
    SELECT greatest(now(), coalesce(max(x.ends_at), now())) INTO start_at FROM public.subscriptions x WHERE x.user_id = pay.user_id;
    INSERT INTO public.subscriptions (user_id, plan_id, payment_id, starts_at, ends_at)
    VALUES (pay.user_id, pay.plan_id, pay.id, start_at, start_at + make_interval(months => pay.months));
    PERFORM private.sub_sync_all();
  END IF;
  RETURN jsonb_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_get_subscription_settings()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE r jsonb;
BEGIN
  IF NOT private.is_platform_admin() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT to_jsonb(s) INTO r FROM public.subscription_settings s WHERE id = 1;
  RETURN r;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_subscription_settings(p_enabled boolean, p_trial_months int, p_bank_name text, p_bank_holder text,
  p_bank_iban text, p_bank_note text, p_commission_enabled boolean, p_commission_percent numeric)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  IF NOT private.is_platform_admin() THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF p_trial_months < 0 OR p_trial_months > 24 THEN RAISE EXCEPTION 'trial months must be 0-24'; END IF;
  IF p_commission_percent < 0 OR p_commission_percent > 30 THEN RAISE EXCEPTION 'commission must be 0-30'; END IF;
  UPDATE public.subscription_settings SET subscriptions_enabled = p_enabled, trial_months = p_trial_months,
    bank_name = nullif(btrim(p_bank_name), ''), bank_holder = nullif(btrim(p_bank_holder), ''), bank_iban = nullif(btrim(p_bank_iban), ''),
    bank_note = nullif(btrim(p_bank_note), ''), commission_enabled = p_commission_enabled, commission_percent = p_commission_percent WHERE id = 1;
  PERFORM private.sub_sync_all();
  RETURN jsonb_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_update_plan(p_id uuid, p_price numeric, p_features text[], p_is_active boolean, p_badge text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  IF NOT private.is_platform_admin() THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF p_price < 0 THEN RAISE EXCEPTION 'invalid price'; END IF;
  UPDATE public.subscription_plans SET price = p_price, features = coalesce(p_features, '{}'), is_active = p_is_active, badge = nullif(btrim(p_badge), '') WHERE id = p_id;
  RETURN jsonb_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_grant_subscription(p_user_id uuid, p_months int)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE start_at timestamptz;
BEGIN
  IF NOT private.is_platform_admin() THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF p_months < 1 OR p_months > 36 THEN RAISE EXCEPTION 'months must be 1-36'; END IF;
  SELECT greatest(now(), coalesce(max(x.ends_at), now())) INTO start_at FROM public.subscriptions x WHERE x.user_id = p_user_id;
  INSERT INTO public.subscriptions (user_id, starts_at, ends_at) VALUES (p_user_id, start_at, start_at + make_interval(months => p_months));
  PERFORM private.sub_sync_all();
  RETURN jsonb_build_object('ok', true);
END;
$$;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('receipts', 'receipts', false, 5242880, ARRAY['image/jpeg','image/png','image/webp','application/pdf'])
ON CONFLICT (id) DO NOTHING;
DROP POLICY IF EXISTS receipts_owner_insert ON storage.objects;
CREATE POLICY receipts_owner_insert ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'receipts' AND (storage.foldername(name))[1] = (SELECT auth.uid())::text);
DROP POLICY IF EXISTS receipts_owner_select ON storage.objects;
CREATE POLICY receipts_owner_select ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'receipts' AND (storage.foldername(name))[1] = (SELECT auth.uid())::text);
DROP POLICY IF EXISTS receipts_admin_select ON storage.objects;
CREATE POLICY receipts_admin_select ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'receipts' AND private.is_platform_admin());

REVOKE ALL ON FUNCTION private.sub_live(uuid), private.sub_sync_all() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sync_subscription_state(), public.my_subscription_status(), public.get_subscription_plans(),
  public.submit_subscription_payment(uuid, text, text), public.admin_list_subscription_payments(),
  public.admin_review_subscription_payment(uuid, boolean, text), public.admin_get_subscription_settings(),
  public.admin_set_subscription_settings(boolean, int, text, text, text, text, boolean, numeric),
  public.admin_update_plan(uuid, numeric, text[], boolean, text), public.admin_grant_subscription(uuid, int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sync_subscription_state(), public.my_subscription_status(), public.get_subscription_plans(),
  public.submit_subscription_payment(uuid, text, text), public.admin_list_subscription_payments(),
  public.admin_review_subscription_payment(uuid, boolean, text), public.admin_get_subscription_settings(),
  public.admin_set_subscription_settings(boolean, int, text, text, text, text, boolean, numeric),
  public.admin_update_plan(uuid, numeric, text[], boolean, text), public.admin_grant_subscription(uuid, int) TO authenticated;
