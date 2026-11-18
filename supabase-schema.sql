-- Lamsa / Sudanese Touch multi-country marketplace schema
-- Apply in Supabase SQL Editor. Never put the service_role key in the browser.
begin;

create extension if not exists pgcrypto with schema extensions;

do $$ begin
  create type public.app_role as enum ('client', 'provider', 'merchant', 'admin', 'moderator');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.approval_state as enum ('pending', 'approved', 'rejected');
exception when duplicate_object then null; end $$;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  email text not null default '',
  phone_private text,
  role public.app_role not null default 'client',
  country text,
  city text,
  district text,
  specialty text,
  store_name text,
  permissions jsonb not null default '{}'::jsonb,
  invite_token text,
  invite_accepted boolean not null default false,
  approval_status public.approval_state not null default 'pending',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.countries (
  name text primary key,
  cities text[] not null default '{}'
);
insert into public.countries(name, cities) values
('السعودية', array['الرياض','جدة','مكة','المدينة','الدمام','الخبر','أبها','الطائف']),
('مصر', array['القاهرة','الإسكندرية','الجيزة','المنصورة','أسوان']),
('الإمارات', array['دبي','أبوظبي','الشارقة','عجمان','العين']),
('السودان', array['الخرطوم','أم درمان','بحري','بورتسودان','ود مدني','كسلا','الأبيض','عطبرة'])
on conflict (name) do update set cities = excluded.cities;

create table if not exists public.merchant_ads (
  id uuid primary key default gen_random_uuid(),
  merchant_id uuid not null references public.profiles(id) on delete cascade,
  title text not null,
  description text not null default '',
  product_category text not null default 'أخرى',
  image_url text,
  logo_url text,
  owner_photo_url text,
  price numeric(12,2),
  currency text,
  country text not null,
  city text not null,
  is_hidden boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Keep invitation tokens out of profiles; only a one-way SHA-256 digest is stored here.
create table if not exists public.admin_invitations (
  id uuid primary key default gen_random_uuid(),
  email text not null,
  phone_private text,
  country text,
  city text,
  permissions jsonb not null default '{}'::jsonb,
  token_hash text not null unique,
  invited_by uuid not null references public.profiles(id),
  expires_at timestamptz not null default (now() + interval '7 days'),
  accepted_at timestamptz,
  created_at timestamptz not null default now()
);

create or replace function public.is_platform_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((auth.jwt() -> 'app_metadata' ->> 'platform_super_admin')::boolean, false)
$$;

create or replace function public.touch_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin new.updated_at = now(); return new; end $$;

create or replace function public.protect_profile_privileges()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is not null and auth.uid() = old.id and not public.is_platform_admin() then
    if new.role is distinct from old.role or new.permissions is distinct from old.permissions
       or new.is_active is distinct from old.is_active or new.invite_token is distinct from old.invite_token
       or new.invite_accepted is distinct from old.invite_accepted then
      raise exception 'Role, permissions and account status are managed by platform administrators';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists profiles_privilege_guard on public.profiles;
create trigger profiles_privilege_guard before update on public.profiles
for each row execute function public.protect_profile_privileges();
drop trigger if exists profiles_touch_updated_at on public.profiles;
create trigger profiles_touch_updated_at before update on public.profiles
for each row execute function public.touch_updated_at();
drop trigger if exists ads_touch_updated_at on public.merchant_ads;
create trigger ads_touch_updated_at before update on public.merchant_ads
for each row execute function public.touch_updated_at();

create or replace function public.handle_new_auth_user()
returns trigger language plpgsql security definer set search_path = '' as $$
declare safe_role public.app_role;
begin
  -- Public sign-up metadata can only request client/provider/merchant, never privileged roles.
  safe_role := case when new.raw_user_meta_data ->> 'role' in ('provider','merchant')
    then (new.raw_user_meta_data ->> 'role')::public.app_role else 'client'::public.app_role end;
  insert into public.profiles(id, full_name, email, phone_private, role, country, city, specialty, store_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'full_name',''), coalesce(new.email,''),
    new.raw_user_meta_data ->> 'phone_private', safe_role,
    new.raw_user_meta_data ->> 'country', new.raw_user_meta_data ->> 'city',
    new.raw_user_meta_data ->> 'specialty', new.raw_user_meta_data ->> 'store_name')
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
for each row execute function public.handle_new_auth_user();

-- Invite acceptance is single-use, email-bound and only grants the moderator role.
create or replace function public.accept_admin_invitation(raw_token text, submitted_phone text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare invitation public.admin_invitations%rowtype;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select * into invitation from public.admin_invitations
    where token_hash = encode(extensions.digest(raw_token, 'sha256'), 'hex')
      and accepted_at is null and expires_at > now() for update;
  if not found then raise exception 'Invitation is invalid, expired or already used'; end if;
  if lower(invitation.email) <> lower(coalesce(auth.jwt() ->> 'email','')) then
    raise exception 'Invitation email does not match signed-in account';
  end if;
  update public.profiles set role='moderator', email=invitation.email,
    phone_private=coalesce(nullif(submitted_phone,''), invitation.phone_private),
    country=invitation.country, city=invitation.city, permissions=invitation.permissions,
    invite_accepted=true, is_active=true, approval_status='approved'
    where id=auth.uid();
  update public.admin_invitations set accepted_at=now() where id=invitation.id;
end $$;

alter table public.profiles enable row level security;
alter table public.countries enable row level security;
alter table public.merchant_ads enable row level security;
alter table public.admin_invitations enable row level security;

drop policy if exists "profiles read self or admins" on public.profiles;
create policy "profiles read self or admins" on public.profiles for select to authenticated
using (id=auth.uid() or public.is_platform_admin() or exists (
  select 1 from public.profiles p where p.id=auth.uid() and p.role='moderator' and p.is_active
  and (p.country is null or p.country=profiles.country) and (p.city is null or p.city=profiles.city)
));
drop policy if exists "profiles update self" on public.profiles;
create policy "profiles update self" on public.profiles for update to authenticated
using (id=auth.uid() or public.is_platform_admin()) with check (id=auth.uid() or public.is_platform_admin());
drop policy if exists "countries are readable" on public.countries;
create policy "countries are readable" on public.countries for select to anon, authenticated using (true);
drop policy if exists "ads public visible or owner" on public.merchant_ads;
create policy "ads public visible or owner" on public.merchant_ads for select to anon, authenticated
using (not is_hidden or merchant_id=auth.uid() or public.is_platform_admin());
drop policy if exists "merchant manages own ads" on public.merchant_ads;
create policy "merchant manages own ads" on public.merchant_ads for all to authenticated
using (merchant_id=auth.uid() and exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='merchant' and p.is_active))
with check (merchant_id=auth.uid() and exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='merchant' and p.is_active));
drop policy if exists "platform admin manages ads" on public.merchant_ads;
create policy "platform admin manages ads" on public.merchant_ads for all to authenticated
using (public.is_platform_admin()) with check (public.is_platform_admin());
-- Invitations are server-managed only; no client policy is intentionally created.

grant select on public.countries to anon, authenticated;
grant select, update on public.profiles to authenticated;
grant select, insert, update, delete on public.merchant_ads to authenticated;
grant execute on function public.accept_admin_invitation(text,text) to authenticated;

commit;
