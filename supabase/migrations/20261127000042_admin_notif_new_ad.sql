-- When a provider or merchant sends a new ad request (status pending), the admin gets a notification.
-- Adds one trigger function and one trigger. Changes no existing data. Run as one migration, exactly as written.
CREATE OR REPLACE FUNCTION private.notify_admin_new_ad()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  IF NEW.status = 'pending' THEN
    INSERT INTO public.admin_notifications (kind, title, body, ref_user_id)
    VALUES ('ad', 'طلب إعلان جديد: ' || left(coalesce(NEW.title, ''), 80), coalesce(NEW.meta->>'owner_name', ''), NEW.advertiser_user_id);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_admin_new_ad ON public.advertisements;
CREATE TRIGGER trg_notify_admin_new_ad
  AFTER INSERT ON public.advertisements
  FOR EACH ROW EXECUTE FUNCTION private.notify_admin_new_ad();
