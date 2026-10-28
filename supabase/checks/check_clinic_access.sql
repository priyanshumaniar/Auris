-- Auris: see exactly what one account can reach.
--
-- Run in the Supabase SQL Editor. Put an account's email on the line marked
-- below and click Run (run the whole file at once, not a selected line). The
-- editor then acts as that account, with the same
-- row-level security the app gets, and shows how many rows it can see.
-- Nothing is changed.
--
-- What to expect:
--   pending account          everything 0, except 1 profile (its own)
--   viewer or clinician      only its own clinic's patients and tests
--   clinic admin             the same, plus its clinic's pending requests
--   super admin, no clinic   0 patients and tests; every clinic and profile

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select id from auth.users
            where email = 'someone@example.com'),   -- <- the account to check
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select
  public.auth_role()                              as role,
  (select name from public.clinics
   where id = public.auth_clinic_id())            as clinic,
  (select count(*) from public.clinics)           as clinics_visible,
  (select count(*) from public.profiles)          as profiles_visible,
  (select count(*) from public.patients)          as patients_visible,
  (select count(*) from public.sessions)          as tests_visible,
  (select count(*) from public.patients
   where clinic_id is distinct from public.auth_clinic_id())
                                                  as other_clinic_patients_visible;
