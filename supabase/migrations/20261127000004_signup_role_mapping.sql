CREATE OR REPLACE FUNCTION private.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  requested_type text;
  source_value text;
  user_name text;
  user_phone text;
  user_city text;
  user_district text;
  user_specialty text;
  user_country_code text;
  user_country_name text;
  referrer uuid;
begin
  requested_type := lower(coalesce(
    nullif(new.raw_user_meta_data ->> 'account_type', ''),
    case lower(coalesce(new.raw_user_meta_data ->> 'role', ''))
      when 'provider' then 'service_provider'
      when 'merchant' then 'merchant'
      else 'client' end));
  if requested_type not in ('client', 'service_provider', 'merchant') then
    requested_type := 'client';
  end if;

  source_value := lower(coalesce(new.raw_user_meta_data ->> 'registration_source', 'direct'));
  if source_value not in ('direct','admin_invite','provider_invite','customer_invite','referral') then
    source_value := 'direct';
  end if;

  user_name := nullif(btrim(coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name', '')), '');
  user_phone := nullif(btrim(coalesce(new.raw_user_meta_data ->> 'phone', new.raw_user_meta_data ->> 'phone_private', '')), '');
  user_city := nullif(btrim(coalesce(new.raw_user_meta_data ->> 'city', '')), '');
  user_district := nullif(btrim(coalesce(new.raw_user_meta_data ->> 'district', '')), '');
  user_specialty := nullif(btrim(coalesce(new.raw_user_meta_data ->> 'specialty', '')), '');
  user_country_code := nullif(btrim(coalesce(new.raw_user_meta_data ->> 'country_code', '')), '');
  user_country_name := nullif(btrim(coalesce(new.raw_user_meta_data ->> 'country_name', '')), '');
  referrer := case when coalesce(new.raw_user_meta_data ->> 'referred_by','') ~* '^[0-9a-f-]{36}$'
    then (new.raw_user_meta_data ->> 'referred_by')::uuid else null end;

  insert into public.profiles
    (id, email, full_name, account_type, phone, phone_private, city, district, specialty,
     approval_status, account_status, registration_source, referred_by, country_code, country_name,
     profile_completed, last_login_at)
  values
    (new.id, lower(new.email), user_name, requested_type, user_phone, user_phone, user_city, user_district,
     user_specialty, case when requested_type in ('service_provider','merchant') then 'pending' else 'approved' end,
     case when user_name is null then 'incomplete' else 'active' end, source_value, referrer,
     user_country_code, user_country_name,
     user_name is not null, new.last_sign_in_at)
  on conflict (id) do update set
    email = coalesce(excluded.email, public.profiles.email),
    full_name = coalesce(excluded.full_name, public.profiles.full_name),
    account_type = excluded.account_type,
    phone = coalesce(excluded.phone, public.profiles.phone),
    phone_private = coalesce(excluded.phone_private, public.profiles.phone_private),
    city = coalesce(excluded.city, public.profiles.city),
    district = coalesce(excluded.district, public.profiles.district),
    specialty = coalesce(excluded.specialty, public.profiles.specialty),
    country_code = coalesce(excluded.country_code, public.profiles.country_code),
    country_name = coalesce(excluded.country_name, public.profiles.country_name),
    registration_source = case when public.profiles.registration_source = 'direct' then excluded.registration_source else public.profiles.registration_source end,
    referred_by = coalesce(public.profiles.referred_by, excluded.referred_by),
    approval_status = excluded.approval_status,
    account_status = case when public.profiles.account_status = 'suspended' then 'suspended' else excluded.account_status end,
    profile_completed = public.profiles.profile_completed or excluded.profile_completed,
    last_login_at = coalesce(excluded.last_login_at, public.profiles.last_login_at),
    updated_at = now();

  if requested_type = 'client' then
    insert into public.customers (user_id) values (new.id) on conflict (user_id) do nothing;
  elsif requested_type = 'service_provider' then
    insert into public.service_providers
      (user_id, display_name, bio, service_categories, city, district, contact_phone, verification_status)
    values (new.id, coalesce(user_name, split_part(coalesce(new.email, 'مقدم خدمة'), '@', 1)),
      nullif(new.raw_user_meta_data ->> 'service_description',''),
      case when user_specialty is null then '{}'::text[] else array[user_specialty] end,
      user_city, user_district, user_phone, 'pending')
    on conflict (user_id) do update set
      display_name = coalesce(excluded.display_name, public.service_providers.display_name),
      bio = coalesce(excluded.bio, public.service_providers.bio),
      service_categories = case when cardinality(excluded.service_categories) > 0 then excluded.service_categories else public.service_providers.service_categories end,
      city = coalesce(excluded.city, public.service_providers.city),
      district = coalesce(excluded.district, public.service_providers.district),
      contact_phone = coalesce(excluded.contact_phone, public.service_providers.contact_phone);
  elsif requested_type = 'merchant' then
    insert into public.merchants
      (user_id, display_name, business_name, description, city, district, contact_phone, verification_status)
    values (new.id, coalesce(user_name, split_part(coalesce(new.email, 'تاجر'), '@', 1)),
      user_name, nullif(new.raw_user_meta_data ->> 'business_description',''), user_city, user_district, user_phone, 'pending')
    on conflict (user_id) do update set
      display_name = coalesce(excluded.display_name, public.merchants.display_name),
      business_name = coalesce(excluded.business_name, public.merchants.business_name),
      description = coalesce(excluded.description, public.merchants.description),
      city = coalesce(excluded.city, public.merchants.city),
      district = coalesce(excluded.district, public.merchants.district),
      contact_phone = coalesce(excluded.contact_phone, public.merchants.contact_phone);
  end if;

  return new;
end;
$function$
