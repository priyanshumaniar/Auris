-- ---------------------------------------------------------------------------
-- Auris - Supabase schema
--
-- Apply to your own Supabase project before enabling cloud sync:
--   Dashboard -> SQL Editor -> New query -> paste all of this -> Run
--
-- Safe to re-run: every statement is idempotent.
--
-- Design goal: a leaked anon key is not a data breach. Every table has
-- row-level security, and the policies key on the *signed-in user's profile*,
-- not on the API key. Roles and clinic separation are enforced here, in the
-- database - a modified client talking straight to the REST API still cannot
-- read another clinic's patients or delete one unless its user is an admin.
--
-- This is patient health data. Before using it on real patients, check what
-- your jurisdiction requires of you as a data controller (India: DPDP Act 2023;
-- EU: GDPR Art. 9; US: HIPAA). Auris does not make your deployment compliant.
-- ---------------------------------------------------------------------------

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------------
-- Clinics and profiles
--
-- Auris is multi-clinic. Every patient, test and threshold belongs to one
-- clinic, and every account is in at most one clinic with one role:
--
--   super_admin  The people who run Auris itself (founder, tech support).
--                Create clinics and give accounts access to them. A super
--                admin may also have a "home" clinic, where they act as its
--                admin; they cannot see any other clinic's patients.
--   admin        Everything inside their own clinic, including approving
--                the people who ask to join it.
--   clinician    Registers patients and runs tests in their clinic. Cannot
--                delete records.
--   viewer       Reads records and prints reports in their clinic.
--   pending      No access. Every new account starts here, with no clinic.
--
-- Roles are stored HERE and not in auth.users.raw_user_meta_data, because a
-- user can write their own metadata - a role kept there could be self-promoted
-- with one API call. Nobody can write to profiles or clinics directly: every
-- change goes through the functions further down, which check who is asking.
-- ---------------------------------------------------------------------------

create table if not exists public.clinics (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  created_at timestamptz not null default now()
);

alter table public.clinics add column if not exists address    text;
alter table public.clinics add column if not exists phone      text;
-- Staff enter this code when they sign up, to ask to join the clinic. It only
-- puts them on the clinic's waiting list; an admin still has to approve them.
alter table public.clinics add column if not exists join_code  text;
alter table public.clinics add column if not exists created_by uuid
  references auth.users (id) on delete set null;
create unique index if not exists idx_clinics_join_code on public.clinics (join_code);

-- A short, permanent clinic number (shown as CLN-0007) that people can quote
-- to support. Unlike the join code it never changes.
create sequence if not exists public.clinics_clinic_no_seq;
alter table public.clinics add column if not exists clinic_no integer;
do $$
declare
  c record;
begin
  for c in select id from public.clinics where clinic_no is null order by created_at loop
    update public.clinics set clinic_no = nextval('public.clinics_clinic_no_seq')
    where id = c.id;
  end loop;
end $$;
alter table public.clinics alter column clinic_no
  set default nextval('public.clinics_clinic_no_seq');
create unique index if not exists idx_clinics_clinic_no on public.clinics (clinic_no);

create table if not exists public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  -- Null for an account awaiting approval, and for a super admin without a
  -- home clinic.
  clinic_id    uuid references public.clinics (id) on delete set null,
  role         text not null default 'pending',
  display_name text,
  created_at   timestamptz not null default now()
);

-- Projects created from an older version of this file: a profile had to have
-- a clinic, deleting a clinic deleted its accounts, and fewer roles existed.
alter table public.profiles alter column clinic_id drop not null;
alter table public.profiles drop constraint if exists profiles_clinic_id_fkey;
alter table public.profiles add constraint profiles_clinic_id_fkey
  foreign key (clinic_id) references public.clinics (id) on delete set null;
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check
  check (role in ('super_admin', 'admin', 'clinician', 'viewer', 'pending'));
alter table public.profiles alter column role set default 'pending';

-- Copied from auth.users, which the app cannot read, so admins can see who
-- an account belongs to.
alter table public.profiles add column if not exists email text;
-- The clinic a pending account asked to join, by join code.
alter table public.profiles add column if not exists requested_clinic_id uuid
  references public.clinics (id) on delete set null;
-- What the person typed, kept even when it matched no clinic.
alter table public.profiles add column if not exists requested_clinic text;
alter table public.profiles add column if not exists approved_by uuid
  references auth.users (id) on delete set null;
alter table public.profiles add column if not exists approved_at timestamptz;
-- Profile details. Changes to these go through an approval (see "Profiles
-- and change requests" below); the values here are always approved ones.
alter table public.profiles add column if not exists phone           text;
alter table public.profiles add column if not exists qualification   text;
alter table public.profiles add column if not exists registration_no text;
-- Whether this person wants email alerts about approvals.
alter table public.profiles add column if not exists email_alerts boolean not null default true;

create index if not exists idx_profiles_clinic    on public.profiles (clinic_id);
create index if not exists idx_profiles_requested on public.profiles (requested_clinic_id);

-- Helper functions, marked `security definer` so they can read profiles from
-- inside a policy without the policy recursing into itself.

create or replace function public.auth_role()
  returns text language sql stable security definer set search_path = public as $$
    select coalesce((select role from public.profiles where id = auth.uid()), 'pending')
  $$;

-- The clinic whose records the signed-in user works with. Null while their
-- account is pending.
create or replace function public.auth_clinic_id()
  returns uuid language sql stable security definer set search_path = public as $$
    select clinic_id from public.profiles
    where id = auth.uid() and role <> 'pending'
  $$;

create or replace function public.auth_is_super_admin()
  returns boolean language sql stable security definer set search_path = public as $$
    select public.auth_role() = 'super_admin'
  $$;

-- May read the records of their own clinic. A super admin only has a clinic
-- if one has been set as their home clinic.
create or replace function public.auth_can_read()
  returns boolean language sql stable security definer set search_path = public as $$
    select public.auth_role() in ('super_admin', 'admin', 'clinician', 'viewer')
       and public.auth_clinic_id() is not null
  $$;

create or replace function public.auth_can_write()
  returns boolean language sql stable security definer set search_path = public as $$
    select public.auth_role() in ('super_admin', 'admin', 'clinician')
       and public.auth_clinic_id() is not null
  $$;

-- Administrator of their own clinic (a super admin is one in their home
-- clinic).
create or replace function public.auth_is_admin()
  returns boolean language sql stable security definer set search_path = public as $$
    select public.auth_role() in ('super_admin', 'admin')
       and public.auth_clinic_id() is not null
  $$;

-- ---------------------------------------------------------------------------
-- Clinical tables
-- ---------------------------------------------------------------------------

create table if not exists public.patients (
  id            text primary key,
  owner_id      uuid not null references auth.users (id) on delete cascade,
  clinic_id     uuid not null references public.clinics (id) on delete cascade,
  full_name     text not null,
  age_years     integer not null check (age_years between 0 and 130),
  sex           text not null,
  clinic_ref    text,
  date_of_birth text,
  phone         text,
  notes         text,
  created_at    text not null,
  updated_at    text not null
);

create table if not exists public.sessions (
  id               text primary key,
  owner_id         uuid not null references auth.users (id) on delete cascade,
  clinic_id        uuid not null references public.clinics (id) on delete cascade,
  patient_id       text not null references public.patients (id) on delete cascade,
  tested_at        text not null,
  clinician_name   text not null,
  -- Snapshot of the calibration in force when the test ran. Recalibrating a
  -- device later must not change what a historical audiogram means.
  calibration_json text,
  notes            text,
  is_complete      boolean not null default false,
  synced_at        timestamptz default now(),
  -- How the test was run (checklist, retests, skipped frequencies...), as
  -- JSON written by the app.
  protocol_json    text
);

create table if not exists public.thresholds (
  session_id      text not null references public.sessions (id) on delete cascade,
  owner_id        uuid not null references auth.users (id) on delete cascade,
  clinic_id       uuid not null references public.clinics (id) on delete cascade,
  ear             text not null check (ear in ('left', 'right')),
  frequency_hz    integer not null,
  -- Null means "no response at maximum output". That is a real clinical
  -- result, distinct from "not tested" (no row at all), so it is nullable.
  threshold_db_hl integer,
  no_response     boolean not null default false,
  tones_presented integer not null default 0,
  catch_trials    integer not null default 0,
  false_positives integer not null default 0,
  -- Null for an ordinary threshold; 'atFloor' (heard at the quietest level,
  -- true threshold at or below it) or 'notEstablished' (no threshold).
  qualifier       text,
  primary key (session_id, ear, frequency_hz)
);

-- Columns added after the first release. "if not exists" makes this safe to
-- run again on a project created from an older version of this file.
alter table public.sessions   add column if not exists protocol_json text;
alter table public.thresholds add column if not exists qualifier     text;

-- Records belong to the clinic, not to the account that typed them in. When an
-- account is deleted its patients and tests stay; owner_id just becomes empty.
-- (Older versions deleted them along with the account.)
alter table public.patients   alter column owner_id drop not null;
alter table public.sessions   alter column owner_id drop not null;
alter table public.thresholds alter column owner_id drop not null;
alter table public.patients   drop constraint if exists patients_owner_id_fkey;
alter table public.sessions   drop constraint if exists sessions_owner_id_fkey;
alter table public.thresholds drop constraint if exists thresholds_owner_id_fkey;
alter table public.patients   add constraint patients_owner_id_fkey
  foreign key (owner_id) references auth.users (id) on delete set null;
alter table public.sessions   add constraint sessions_owner_id_fkey
  foreign key (owner_id) references auth.users (id) on delete set null;
alter table public.thresholds add constraint thresholds_owner_id_fkey
  foreign key (owner_id) references auth.users (id) on delete set null;

create index if not exists idx_patients_clinic   on public.patients (clinic_id);
create index if not exists idx_sessions_clinic   on public.sessions (clinic_id);
create index if not exists idx_sessions_patient  on public.sessions (patient_id, tested_at desc);
create index if not exists idx_thresholds_clinic on public.thresholds (clinic_id);

-- ---------------------------------------------------------------------------
-- Row-level security
--
-- `using` decides which existing rows are visible and which may be modified;
-- `with check` decides what may be written. Both are needed - `using` alone
-- would let a client insert rows belonging to another clinic.
--
-- Clinic separation lives here: every clinical row carries a clinic_id, and
-- a user only ever reaches rows of their own clinic.
-- ---------------------------------------------------------------------------

alter table public.clinics    enable row level security;
alter table public.profiles   enable row level security;
alter table public.patients   enable row level security;
alter table public.sessions   enable row level security;
alter table public.thresholds enable row level security;

drop policy if exists clinics_read          on public.clinics;
drop policy if exists profiles_read         on public.profiles;
drop policy if exists profiles_admin_write  on public.profiles;
drop policy if exists profiles_self_rename  on public.profiles;
drop policy if exists patients_read         on public.patients;
drop policy if exists patients_write        on public.patients;
drop policy if exists patients_update       on public.patients;
drop policy if exists patients_delete       on public.patients;
drop policy if exists sessions_read         on public.sessions;
drop policy if exists sessions_write        on public.sessions;
drop policy if exists sessions_update       on public.sessions;
drop policy if exists sessions_delete       on public.sessions;
drop policy if exists thresholds_read       on public.thresholds;
drop policy if exists thresholds_write      on public.thresholds;
drop policy if exists thresholds_update     on public.thresholds;
drop policy if exists thresholds_delete     on public.thresholds;

-- --- clinics ---------------------------------------------------------------
-- Read only. Creating and editing clinics goes through the functions below.
create policy clinics_read on public.clinics
  for select using (
    public.auth_is_super_admin()
    or (id = public.auth_clinic_id() and public.auth_can_read())
  );

-- --- profiles --------------------------------------------------------------
-- Read only, for the same reason. Everyone sees their own row (so the app can
-- tell a pending user they are waiting); approved members see their clinic's
-- members; a clinic admin also sees who has asked to join; a super admin sees
-- everyone.
create policy profiles_read on public.profiles
  for select using (
    id = auth.uid()
    or public.auth_is_super_admin()
    or (clinic_id = public.auth_clinic_id() and public.auth_can_read())
    or (public.auth_is_admin()
        and role = 'pending'
        and requested_clinic_id = public.auth_clinic_id())
  );

-- The helper functions are wrapped in (select ...) so Postgres evaluates
-- them once per query rather than once per row.

-- --- patients --------------------------------------------------------------
create policy patients_read on public.patients
  for select using (clinic_id = (select public.auth_clinic_id()) and (select public.auth_can_read()));

create policy patients_write on public.patients
  for insert
  with check (clinic_id = (select public.auth_clinic_id()) and (select public.auth_can_write()));

create policy patients_update on public.patients
  for update
  using (clinic_id = (select public.auth_clinic_id()) and (select public.auth_can_write()))
  with check (clinic_id = (select public.auth_clinic_id()) and (select public.auth_can_write()));

-- Deleting a patient cascades to every test they have ever had: admins only.
create policy patients_delete on public.patients
  for delete
  using (clinic_id = (select public.auth_clinic_id()) and (select public.auth_is_admin()));

-- --- sessions --------------------------------------------------------------
create policy sessions_read on public.sessions
  for select using (clinic_id = (select public.auth_clinic_id()) and (select public.auth_can_read()));

create policy sessions_write on public.sessions
  for insert
  with check (clinic_id = (select public.auth_clinic_id()) and (select public.auth_can_write()));

create policy sessions_update on public.sessions
  for update
  using (clinic_id = (select public.auth_clinic_id()) and (select public.auth_can_write()))
  with check (clinic_id = (select public.auth_clinic_id()) and (select public.auth_can_write()));

create policy sessions_delete on public.sessions
  for delete
  using (clinic_id = (select public.auth_clinic_id()) and (select public.auth_is_admin()));

-- --- thresholds ------------------------------------------------------------
create policy thresholds_read on public.thresholds
  for select using (clinic_id = (select public.auth_clinic_id()) and (select public.auth_can_read()));

create policy thresholds_write on public.thresholds
  for insert
  with check (clinic_id = (select public.auth_clinic_id()) and (select public.auth_can_write()));

create policy thresholds_update on public.thresholds
  for update
  using (clinic_id = (select public.auth_clinic_id()) and (select public.auth_can_write()))
  with check (clinic_id = (select public.auth_clinic_id()) and (select public.auth_can_write()));

create policy thresholds_delete on public.thresholds
  for delete
  using (clinic_id = (select public.auth_clinic_id()) and (select public.auth_is_admin()));

-- ---------------------------------------------------------------------------
-- Join codes
-- ---------------------------------------------------------------------------

-- "AUR-" and five characters, leaving out ones that are easy to misread
-- (0/O, 1/I/L).
create or replace function public.new_join_code()
  returns text language plpgsql volatile set search_path = public as $$
declare
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  code text;
begin
  loop
    code := 'AUR-';
    for i in 1..5 loop
      code := code || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from public.clinics where join_code = code);
  end loop;
  return code;
end;
$$;

-- Give every existing clinic a code.
do $$
declare
  c record;
begin
  for c in select id from public.clinics where join_code is null loop
    update public.clinics set join_code = public.new_join_code() where id = c.id;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Automatic profile creation
--
-- Every signed-in user needs a profile row, because that is what the policies
-- above read. A user without one has no access at all.
--
-- Every new account starts as 'pending' with no clinic. If the person entered
-- a clinic's join code at sign-up, they go on that clinic's waiting list. A
-- super admin, or that clinic's admin, then gives them a role.
--
-- The function is `security definer`, so it can write to profiles even though
-- the signing-up user cannot.
-- ---------------------------------------------------------------------------

create or replace function public.handle_new_user()
  returns trigger language plpgsql security definer set search_path = public as $$
declare
  typed_code text := nullif(upper(trim(new.raw_user_meta_data->>'join_code')), '');
  wanted uuid;
begin
  if typed_code is not null then
    select id into wanted from public.clinics where join_code = typed_code;
  end if;

  insert into public.profiles
    (id, clinic_id, role, display_name, email, requested_clinic_id, requested_clinic)
  values (
    new.id,
    null,
    'pending',
    -- display_name comes from email sign-up; Google sign-in supplies
    -- full_name / name instead.
    coalesce(
      new.raw_user_meta_data->>'display_name',
      new.raw_user_meta_data->>'full_name',
      new.raw_user_meta_data->>'name',
      new.email
    ),
    new.email,
    wanted,
    typed_code
  )
  on conflict (id) do nothing;

  -- The code matched a clinic: put the request on its admins' list.
  if wanted is not null then
    insert into public.change_requests
      (user_id, user_email, user_name, kind, clinic_id, reviewer_level, payload)
    select new.id, new.email, p.display_name, 'join', wanted, 'clinic_admin',
           jsonb_build_object('join_code', typed_code, 'clinic_name', c.name,
                              'clinic_no', c.clinic_no)
    from public.profiles p, public.clinics c
    where p.id = new.id and c.id = wanted
    on conflict do nothing;
  end if;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Backfill: a profile for anyone who registered before this trigger existed,
-- and the email on every profile.
insert into public.profiles (id, clinic_id, role, display_name, email)
select u.id,
       null,
       'pending',
       coalesce(u.raw_user_meta_data->>'display_name',
                u.raw_user_meta_data->>'full_name',
                u.raw_user_meta_data->>'name',
                u.email),
       u.email
from auth.users u
on conflict (id) do nothing;

update public.profiles p set email = u.email
from auth.users u
where u.id = p.id and p.email is distinct from u.email;

-- ---------------------------------------------------------------------------
-- Managing clinics and access
--
-- The only way to change clinics and roles from the app. Each function checks
-- who is calling. None of them can make anyone a super admin: that is done
-- with SQL in this editor, by the project owner (see the end of this file).
-- ---------------------------------------------------------------------------

-- Super admin: create a clinic. Returns its id.
create or replace function public.create_clinic(
  p_name text, p_address text default null, p_phone text default null)
  returns uuid language plpgsql security definer set search_path = public as $$
declare
  new_id uuid;
begin
  if not public.auth_is_super_admin() then
    raise exception 'Only a super admin can create a clinic.';
  end if;
  if coalesce(trim(p_name), '') = '' then
    raise exception 'The clinic needs a name.';
  end if;
  insert into public.clinics (name, address, phone, join_code, created_by)
  values (trim(p_name), nullif(trim(p_address), ''), nullif(trim(p_phone), ''),
          public.new_join_code(), auth.uid())
  returning id into new_id;
  return new_id;
end;
$$;

-- Super admin, or the clinic's own admin: replace the join code, for example
-- after it was shared too widely. The old code stops working at once.
create or replace function public.regenerate_join_code(p_clinic uuid)
  returns text language plpgsql security definer set search_path = public as $$
declare
  code text;
begin
  if not coalesce(public.auth_is_super_admin()
                  or (public.auth_is_admin() and p_clinic = public.auth_clinic_id()),
                  false) then
    raise exception 'Only a super admin or this clinic''s admin can change its code.';
  end if;
  code := public.new_join_code();
  update public.clinics set join_code = code where id = p_clinic;
  if not found then
    raise exception 'No such clinic.';
  end if;
  return code;
end;
$$;

-- Give an account a role in a clinic.
--   * A super admin may place anyone (except another super admin) in any
--     clinic.
--   * A clinic admin may approve someone who asked to join their clinic, or
--     change the role of a member of their clinic.
-- Nobody can change their own access this way.
create or replace function public.set_member_access(
  p_user uuid, p_clinic uuid, p_role text)
  returns void language plpgsql security definer set search_path = public as $$
declare
  me_role text := public.auth_role();
  me_clinic uuid := public.auth_clinic_id();
  target public.profiles%rowtype;
begin
  if p_role not in ('admin', 'clinician', 'viewer') then
    raise exception 'The role must be admin, clinician or viewer.';
  end if;
  if p_user = auth.uid() then
    raise exception 'You cannot change your own access.';
  end if;
  select * into target from public.profiles where id = p_user;
  if not found then
    raise exception 'No such account.';
  end if;
  if target.role = 'super_admin' then
    raise exception 'A super admin''s access can only be changed in the database.';
  end if;
  if not exists (select 1 from public.clinics where id = p_clinic) then
    raise exception 'No such clinic.';
  end if;

  if me_role = 'super_admin' then
    null;
  elsif me_role = 'admin' and me_clinic is not null then
    if p_clinic is distinct from me_clinic then
      raise exception 'You can only give access to your own clinic.';
    end if;
    -- coalesce: a pending account has no clinic, and a comparison with null
    -- is null, which "if not" would treat as allowed.
    if not coalesce(target.clinic_id = me_clinic
                    or (target.role = 'pending'
                        and target.requested_clinic_id = me_clinic),
                    false) then
      raise exception 'That account has not asked to join your clinic.';
    end if;
  else
    raise exception 'Only an administrator can give access.';
  end if;

  update public.profiles
  set clinic_id = p_clinic,
      role = p_role,
      requested_clinic_id = null,
      requested_clinic = null,
      approved_by = auth.uid(),
      approved_at = now()
  where id = p_user;

  -- Any open request to join or move is settled by this.
  update public.change_requests
  set status = case when clinic_id = p_clinic then 'approved' else 'cancelled' end,
      reviewed_by = auth.uid(),
      reviewed_at = now()
  where user_id = p_user and kind in ('join', 'move') and status = 'pending';
  perform public._rehome_open_requests(p_user);
end;
$$;

-- Take an account's access away (or turn down a request to join). The
-- account goes back to pending with no clinic.
create or replace function public.revoke_member(p_user uuid)
  returns void language plpgsql security definer set search_path = public as $$
declare
  me_role text := public.auth_role();
  me_clinic uuid := public.auth_clinic_id();
  target public.profiles%rowtype;
begin
  if p_user = auth.uid() then
    raise exception 'You cannot remove your own access.';
  end if;
  select * into target from public.profiles where id = p_user;
  if not found then
    raise exception 'No such account.';
  end if;
  if target.role = 'super_admin' then
    raise exception 'A super admin''s access can only be changed in the database.';
  end if;

  if me_role = 'super_admin' then
    null;
  elsif me_role = 'admin' and me_clinic is not null then
    if not coalesce(target.clinic_id = me_clinic
                    or (target.role = 'pending'
                        and target.requested_clinic_id = me_clinic),
                    false) then
      raise exception 'That account is not in your clinic.';
    end if;
  else
    raise exception 'Only an administrator can remove access.';
  end if;

  update public.profiles
  set clinic_id = null,
      role = 'pending',
      requested_clinic_id = null,
      requested_clinic = null,
      approved_by = null,
      approved_at = null
  where id = p_user;

  update public.change_requests
  set status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now()
  where user_id = p_user and kind in ('join', 'move') and status = 'pending';
  perform public._rehome_open_requests(p_user);
end;
$$;

-- ---------------------------------------------------------------------------
-- Profiles and change requests
--
-- Every change to who someone is, or where they work, is a request that
-- someone else approves. Until then nothing changes: member lists, reports
-- and the app keep showing the approved values in `profiles` and `clinics`.
--
--   kind     what is asked                       approved by
--   profile  name, phone, qualification, reg. no  clinic admin, or a super admin
--                                                 (a clinic admin's own: super
--                                                 admin only)
--   email    a new login email                   same as profile; the user then
--                                                 confirms a code sent to it
--   join     to join a clinic, by join code      that clinic's admin, or a
--                                                 super admin
--   move     to move to another clinic           the new clinic's admin, or a
--                                                 super admin
--   clinic   a clinic's name, address, phone     a super admin
--   delete   to delete one's own account         a super admin (carried out
--                                                 by the delete-account Edge
--                                                 Function)
--   leave    left a clinic (record only)         nobody: giving up access is
--                                                 immediate
--
-- A super admin's own changes, and those of an account still waiting to join
-- a clinic, apply at once. Every request is kept, with who decided and when.
-- ---------------------------------------------------------------------------

create table if not exists public.change_requests (
  id             uuid primary key default gen_random_uuid(),
  -- Null once the account has been deleted; the name and email stay below.
  user_id        uuid references auth.users (id) on delete set null,
  user_email     text,
  user_name      text,
  kind           text not null
                 check (kind in ('profile', 'email', 'join', 'move', 'clinic',
                                 'delete', 'leave')),
  -- The clinic whose admin may decide (for join and move, the clinic asked
  -- for; for clinic, the clinic being edited).
  clinic_id      uuid references public.clinics (id) on delete cascade,
  from_clinic_id uuid references public.clinics (id) on delete set null,
  reviewer_level text not null check (reviewer_level in ('clinic_admin', 'super_admin')),
  payload        jsonb not null default '{}'::jsonb,   -- what is asked for
  previous       jsonb not null default '{}'::jsonb,   -- what it was when asked
  status         text not null default 'pending'
                 check (status in ('pending', 'approved', 'rejected', 'cancelled',
                                   'completed', 'flagged')),
  reason         text,   -- the requester's reason, if they gave one
  decision_note  text,   -- the reviewer's note, for example why it was rejected
  reviewed_by    uuid references auth.users (id) on delete set null,
  reviewed_at    timestamptz,
  created_at     timestamptz not null default now()
);

create index if not exists idx_change_requests_user   on public.change_requests (user_id, created_at desc);
create index if not exists idx_change_requests_clinic on public.change_requests (clinic_id, status);
-- One open request per person and kind; a new one replaces the old.
create unique index if not exists idx_change_requests_one_open
  on public.change_requests (user_id, kind) where status = 'pending';

alter table public.change_requests enable row level security;
drop policy if exists change_requests_read on public.change_requests;
-- Read only: requests are made and decided through the functions below.
-- Everyone sees their own; a clinic admin sees those of their clinic that a
-- clinic admin may decide; a super admin sees all.
create policy change_requests_read on public.change_requests
  for select using (
    user_id = auth.uid()
    or public.auth_is_super_admin()
    or (public.auth_is_admin()
        and reviewer_level = 'clinic_admin'
        and clinic_id = public.auth_clinic_id())
  );

-- Whether the caller may decide [r].
create or replace function public.can_review(r public.change_requests)
  returns boolean language sql stable security definer set search_path = public as $$
    select r.user_id is distinct from auth.uid()
       and (public.auth_is_super_admin()
            or (public.auth_is_admin()
                and r.reviewer_level = 'clinic_admin'
                and r.clinic_id = public.auth_clinic_id()))
  $$;

-- Opens a request for the caller, replacing an open one of the same kind.
create or replace function public._open_request(
  p_kind text, p_clinic uuid, p_level text, p_payload jsonb, p_previous jsonb,
  p_reason text default null, p_from_clinic uuid default null,
  p_status text default 'pending')
  returns uuid language plpgsql security definer set search_path = public as $$
declare
  me public.profiles%rowtype;
  new_id uuid;
begin
  select * into me from public.profiles where id = auth.uid();
  if not found then
    raise exception 'Sign in first.';
  end if;
  -- An approved email change not yet confirmed is replaced too.
  update public.change_requests set status = 'cancelled'
  where user_id = auth.uid() and kind = p_kind
    and (status = 'pending' or (p_kind = 'email' and status = 'approved'));
  insert into public.change_requests
    (user_id, user_email, user_name, kind, clinic_id, from_clinic_id,
     reviewer_level, payload, previous, status, reason,
     reviewed_by, reviewed_at)
  values
    (auth.uid(), me.email, me.display_name, p_kind, p_clinic, p_from_clinic,
     p_level, coalesce(p_payload, '{}'::jsonb), coalesce(p_previous, '{}'::jsonb),
     p_status, nullif(trim(p_reason), ''),
     case when p_status = 'pending' then null else auth.uid() end,
     case when p_status = 'pending' then null else now() end)
  returning id into new_id;
  return new_id;
end;
$$;
revoke execute on function public._open_request(text, uuid, text, jsonb, jsonb, text, uuid, text)
  from public, anon, authenticated;

-- After [p_user]'s clinic or role changes, their open profile and email
-- requests follow them: to the new clinic's admin (or a super admin, for an
-- admin), or are withdrawn when they no longer have a clinic. Otherwise the
-- old clinic's admin could still decide them.
create or replace function public._rehome_open_requests(p_user uuid)
  returns void language plpgsql security definer set search_path = public as $$
declare
  p public.profiles%rowtype;
begin
  select * into p from public.profiles where id = p_user;
  if not found or p.clinic_id is null or p.role in ('pending', 'super_admin') then
    update public.change_requests set status = 'cancelled'
    where user_id = p_user and kind in ('profile', 'email') and status = 'pending';
    return;
  end if;
  update public.change_requests
  set clinic_id = p.clinic_id,
      reviewer_level = case when p.role = 'admin' then 'super_admin' else 'clinic_admin' end
  where user_id = p_user and kind in ('profile', 'email') and status = 'pending';
end;
$$;
revoke execute on function public._rehome_open_requests(uuid) from public, anon, authenticated;

-- Who decides changes to the caller's own profile or email: a clinic admin's
-- go to a super admin, everyone else's to their clinic's admin. Null means
-- the change applies at once (a super admin, or an account not in a clinic).
create or replace function public._own_review_level()
  returns text language sql stable security definer set search_path = public as $$
    select case public.auth_role()
             when 'super_admin' then null
             when 'pending' then null
             when 'admin' then 'super_admin'
             else 'clinic_admin'
           end
  $$;

-- Ask to change one's name, phone, qualification and registration number.
-- Returns 'applied' or 'requested'.
create or replace function public.submit_profile_change(
  p_display_name text, p_phone text, p_qualification text, p_registration_no text)
  returns text language plpgsql security definer set search_path = public as $$
declare
  me public.profiles%rowtype;
  level text := public._own_review_level();
  wanted jsonb;
  was jsonb;
begin
  select * into me from public.profiles where id = auth.uid();
  if not found then
    raise exception 'Sign in first.';
  end if;
  if coalesce(trim(p_display_name), '') = '' then
    raise exception 'Your name cannot be empty.';
  end if;
  wanted := jsonb_build_object(
    'display_name', trim(p_display_name),
    'phone', nullif(trim(p_phone), ''),
    'qualification', nullif(trim(p_qualification), ''),
    'registration_no', nullif(trim(p_registration_no), ''));
  was := jsonb_build_object(
    'display_name', me.display_name, 'phone', me.phone,
    'qualification', me.qualification, 'registration_no', me.registration_no);
  if wanted = was then
    raise exception 'Nothing has changed.';
  end if;

  if level is null then
    update public.profiles
    set display_name = wanted->>'display_name',
        phone = wanted->>'phone',
        qualification = wanted->>'qualification',
        registration_no = wanted->>'registration_no'
    where id = auth.uid();
    perform public._open_request('profile', me.clinic_id, 'super_admin', wanted, was,
                                 null, null, 'completed');
    return 'applied';
  end if;

  perform public._open_request('profile', me.clinic_id, level, wanted, was);
  return 'requested';
end;
$$;

-- Ask to change one's login email. Once approved (at once for a super admin
-- or an account not in a clinic), the app asks Supabase to send a code to the
-- new address, and the change completes when the code is entered. Returns
-- 'approved' or 'requested'.
create or replace function public.submit_email_change(p_new_email text)
  returns text language plpgsql security definer set search_path = public as $$
declare
  me public.profiles%rowtype;
  level text := public._own_review_level();
  wanted text := lower(trim(p_new_email));
begin
  select * into me from public.profiles where id = auth.uid();
  if not found then
    raise exception 'Sign in first.';
  end if;
  if wanted !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'That is not a valid email address.';
  end if;
  if wanted = lower(coalesce(me.email, '')) then
    raise exception 'That is already your email address.';
  end if;
  if exists (select 1 from auth.users where lower(email) = wanted) then
    raise exception 'Another account already uses that email address.';
  end if;
  perform public._open_request('email', me.clinic_id, coalesce(level, 'super_admin'),
    jsonb_build_object('email', wanted), jsonb_build_object('email', me.email),
    null, null, case when level is null then 'approved' else 'pending' end);
  return case when level is null then 'approved' else 'requested' end;
end;
$$;

-- Ask to join a clinic (an account waiting to join) or move to it (a member
-- of another clinic), by its join code. Returns the clinic's name.
drop function if exists public.request_clinic(text);
create or replace function public.request_clinic(p_join_code text)
  returns text language plpgsql security definer set search_path = public as $$
declare
  code text := upper(trim(p_join_code));
  wanted public.clinics%rowtype;
  me public.profiles%rowtype;
begin
  select * into me from public.profiles where id = auth.uid();
  if not found then
    raise exception 'Sign in first.';
  end if;
  select * into wanted from public.clinics where join_code = code;
  if not found then
    raise exception 'No clinic has the code %.', code;
  end if;

  if me.role = 'pending' then
    update public.profiles
    set requested_clinic_id = wanted.id, requested_clinic = code
    where id = auth.uid();
    perform public._open_request('join', wanted.id, 'clinic_admin',
      jsonb_build_object('join_code', code, 'clinic_name', wanted.name,
                         'clinic_no', wanted.clinic_no),
      '{}'::jsonb);
  elsif me.role = 'super_admin' then
    raise exception 'A super admin''s home clinic is set in the database.';
  else
    if wanted.id = me.clinic_id then
      raise exception 'You are already in %.', wanted.name;
    end if;
    perform public._open_request('move', wanted.id, 'clinic_admin',
      jsonb_build_object('join_code', code, 'clinic_name', wanted.name,
                         'clinic_no', wanted.clinic_no, 'role', me.role),
      jsonb_build_object('clinic_name',
        (select name from public.clinics where id = me.clinic_id)),
      null, me.clinic_id);
  end if;
  return wanted.name;
end;
$$;

-- Leave one's clinic: access ends at once. A super admin only drops their
-- home clinic.
create or replace function public.leave_clinic()
  returns void language plpgsql security definer set search_path = public as $$
declare
  me public.profiles%rowtype;
begin
  select * into me from public.profiles where id = auth.uid();
  if not found or me.clinic_id is null then
    raise exception 'You are not in a clinic.';
  end if;
  perform public._open_request('leave', me.clinic_id, 'clinic_admin',
    '{}'::jsonb,
    jsonb_build_object('clinic_name',
      (select name from public.clinics where id = me.clinic_id), 'role', me.role),
    null, null, 'completed');
  update public.profiles
  set clinic_id = null,
      role = case when me.role = 'super_admin' then 'super_admin' else 'pending' end,
      requested_clinic_id = null,
      requested_clinic = null,
      approved_by = null,
      approved_at = null
  where id = auth.uid();
  update public.change_requests set status = 'cancelled'
  where user_id = auth.uid() and kind in ('move', 'profile', 'email')
    and status = 'pending';
end;
$$;

-- Edit a clinic's name, address and phone. A super admin's edit applies at
-- once; a clinic admin's goes to a super admin, since these print on every
-- report. Returns 'applied' or 'requested'.
drop function if exists public.update_clinic(uuid, text, text, text);
create or replace function public.update_clinic(
  p_clinic uuid, p_name text, p_address text, p_phone text)
  returns text language plpgsql security definer set search_path = public as $$
declare
  current_row public.clinics%rowtype;
  wanted jsonb;
begin
  -- coalesce: a comparison with a null clinic is null, and "if not null"
  -- would let the call through.
  if not coalesce(public.auth_is_super_admin()
                  or (public.auth_is_admin() and p_clinic = public.auth_clinic_id()),
                  false) then
    raise exception 'Only a super admin or this clinic''s admin can edit it.';
  end if;
  if coalesce(trim(p_name), '') = '' then
    raise exception 'The clinic needs a name.';
  end if;
  select * into current_row from public.clinics where id = p_clinic;
  if not found then
    raise exception 'No such clinic.';
  end if;
  wanted := jsonb_build_object('name', trim(p_name),
    'address', nullif(trim(p_address), ''), 'phone', nullif(trim(p_phone), ''));

  if public.auth_is_super_admin() then
    update public.clinics
    set name = wanted->>'name', address = wanted->>'address', phone = wanted->>'phone'
    where id = p_clinic;
    return 'applied';
  end if;

  perform public._open_request('clinic', p_clinic, 'super_admin', wanted,
    jsonb_build_object('name', current_row.name, 'address', current_row.address,
                       'phone', current_row.phone));
  return 'requested';
end;
$$;

-- Ask for one's own account to be deleted. A super admin decides; the
-- delete-account Edge Function carries it out.
create or replace function public.request_account_deletion(p_reason text)
  returns void language plpgsql security definer set search_path = public as $$
begin
  if public.auth_role() = 'super_admin' then
    raise exception 'A super admin account is removed in the Supabase dashboard.';
  end if;
  perform public._open_request('delete',
    (select clinic_id from public.profiles where id = auth.uid()),
    'super_admin', '{}'::jsonb, '{}'::jsonb, p_reason);
end;
$$;

-- Withdraw one's own open request, or an approved email change not yet
-- confirmed.
create or replace function public.cancel_request(p_request uuid)
  returns void language plpgsql security definer set search_path = public as $$
declare
  r public.change_requests%rowtype;
begin
  select * into r from public.change_requests where id = p_request;
  if not found or r.user_id is distinct from auth.uid()
     or not (r.status = 'pending' or (r.kind = 'email' and r.status = 'approved')) then
    raise exception 'That request cannot be withdrawn.';
  end if;
  update public.change_requests set status = 'cancelled' where id = p_request;
  if r.kind = 'join' then
    update public.profiles set requested_clinic_id = null, requested_clinic = null
    where id = auth.uid();
  end if;
end;
$$;

-- Approve or reject a request. [p_role] is the role to give when approving a
-- join or a move (a move keeps the current role when it is not given).
-- Deletions are approved through the delete-account Edge Function instead.
create or replace function public.review_request(
  p_request uuid, p_approve boolean, p_note text default null, p_role text default null)
  returns void language plpgsql security definer set search_path = public as $$
declare
  r public.change_requests%rowtype;
  target public.profiles%rowtype;
  new_role text;
begin
  select * into r from public.change_requests where id = p_request for update;
  if not found then
    raise exception 'No such request.';
  end if;
  if r.status <> 'pending' then
    raise exception 'This request has already been decided.';
  end if;
  if not coalesce(public.can_review(r), false) then
    raise exception 'You cannot decide this request.';
  end if;

  if not p_approve then
    update public.change_requests
    set status = 'rejected', decision_note = nullif(trim(p_note), ''),
        reviewed_by = auth.uid(), reviewed_at = now()
    where id = r.id;
    if r.kind = 'join' then
      update public.profiles set requested_clinic_id = null, requested_clinic = null
      where id = r.user_id and requested_clinic_id = r.clinic_id;
    end if;
    return;
  end if;

  if r.kind = 'delete' then
    raise exception 'Approve a deletion from the admin console, which removes the account.';
  end if;
  if r.kind = 'leave' then
    raise exception 'Nothing to approve.';
  end if;

  select * into target from public.profiles where id = r.user_id;
  if r.kind in ('profile', 'email', 'join', 'move') and not found then
    raise exception 'That account no longer exists.';
  end if;

  if r.kind = 'profile' then
    update public.profiles
    set display_name = r.payload->>'display_name',
        phone = r.payload->>'phone',
        qualification = r.payload->>'qualification',
        registration_no = r.payload->>'registration_no'
    where id = r.user_id;
  elsif r.kind = 'clinic' then
    update public.clinics
    set name = r.payload->>'name', address = r.payload->>'address',
        phone = r.payload->>'phone'
    where id = r.clinic_id;
  elsif r.kind in ('join', 'move') then
    if target.role = 'super_admin' then
      raise exception 'A super admin''s clinic is set in the database.';
    end if;
    new_role := coalesce(p_role,
      case when r.kind = 'move' and target.role in ('admin', 'clinician', 'viewer')
           then target.role end);
    if new_role is null or new_role not in ('admin', 'clinician', 'viewer') then
      raise exception 'Choose a role: admin, clinician or viewer.';
    end if;
    if r.kind = 'join' and target.role <> 'pending' then
      raise exception 'That account is already in a clinic.';
    end if;
    update public.profiles
    set clinic_id = r.clinic_id, role = new_role, requested_clinic_id = null,
        requested_clinic = null, approved_by = auth.uid(), approved_at = now()
    where id = r.user_id;
    perform public._rehome_open_requests(r.user_id);
  end if;
  -- 'email' needs nothing here: the user now confirms the new address.

  update public.change_requests
  set status = 'approved', decision_note = nullif(trim(p_note), ''),
      reviewed_by = auth.uid(), reviewed_at = now()
  where id = r.id;
end;
$$;

-- Turn one's own email alerts on or off. No approval needed.
create or replace function public.set_email_alerts(p_on boolean)
  returns void language sql security definer set search_path = public as $$
    update public.profiles set email_alerts = coalesce(p_on, true) where id = auth.uid()
  $$;

-- A pending account cannot read clinics, so it asks for the one it requested.
create or replace function public.my_requested_clinic()
  returns table (name text, clinic_no integer)
  language sql stable security definer set search_path = public as $$
    select c.name, c.clinic_no
    from public.profiles p join public.clinics c on c.id = p.requested_clinic_id
    where p.id = auth.uid()
  $$;

-- Who approved the caller's access. The approver may be a super admin outside
-- the caller's clinic, whose profile the caller cannot read directly.
create or replace function public.my_approver()
  returns text language sql stable security definer set search_path = public as $$
    select coalesce(a.display_name, a.email)
    from public.profiles p join public.profiles a on a.id = p.approved_by
    where p.id = auth.uid()
  $$;

-- Keeps profiles.email in step with the login email, and records the change.
-- An email changed without an approved request (Supabase lets a signed-in user
-- change their own email through its API) is recorded as 'flagged' for a
-- super admin to see.
create or replace function public.handle_email_changed()
  returns trigger language plpgsql security definer set search_path = public as $$
declare
  approved_id uuid;
  p public.profiles%rowtype;
begin
  update public.profiles set email = new.email where id = new.id;
  select id into approved_id from public.change_requests
  where user_id = new.id and kind = 'email' and status = 'approved'
    and lower(payload->>'email') = lower(new.email)
  order by created_at desc limit 1;
  if approved_id is not null then
    update public.change_requests set status = 'completed' where id = approved_id;
  else
    select * into p from public.profiles where id = new.id;
    insert into public.change_requests
      (user_id, user_email, user_name, kind, clinic_id, reviewer_level,
       payload, previous, status)
    values (new.id, new.email, p.display_name, 'email', p.clinic_id, 'super_admin',
            jsonb_build_object('email', new.email),
            jsonb_build_object('email', old.email), 'flagged');
  end if;
  return new;
end;
$$;

drop trigger if exists on_auth_user_email_changed on auth.users;
create trigger on_auth_user_email_changed
  after update of email on auth.users
  for each row when (old.email is distinct from new.email)
  execute function public.handle_email_changed();

-- Requests to join made before change requests existed.
insert into public.change_requests
  (user_id, user_email, user_name, kind, clinic_id, reviewer_level, payload)
select p.id, p.email, p.display_name, 'join', p.requested_clinic_id, 'clinic_admin',
       jsonb_build_object('join_code', p.requested_clinic, 'clinic_name', c.name,
                          'clinic_no', c.clinic_no)
from public.profiles p
join public.clinics c on c.id = p.requested_clinic_id
where p.role = 'pending'
  and not exists (select 1 from public.change_requests r
                  where r.user_id = p.id and r.kind = 'join' and r.status = 'pending');

-- An older version of this file had a helper that told anyone the clinic of
-- any email address. It is no longer needed.
drop function if exists public.auth_clinic_id_for(text);

-- ---------------------------------------------------------------------------
-- Making someone a super admin
--
-- Deliberately not possible from the app. As the project owner, run:
--
--   update public.profiles set role = 'super_admin'
--   where id = (select id from auth.users where email = 'you@example.com');
--
-- To also give them a home clinic, where they act as its admin:
--
--   update public.profiles set clinic_id = '<clinic id>'
--   where id = (select id from auth.users where email = 'you@example.com');
-- ---------------------------------------------------------------------------

-- Ask the API to pick up any new columns and functions straight away.
notify pgrst, 'reload schema';
