-- Auris: several clinics, each with its own admins and staff (October 2026).
--
-- Run in the Supabase SQL Editor, in this order:
--
--   1. All of supabase/schema.sql. It is safe to re-run and now contains the
--      multi-clinic tables, rules and functions.
--   2. This file.
--
-- This file makes the Auris owner a super admin. Their account keeps the
-- clinic it is in now as its home clinic, so the records already there stay
-- visible to it; no other clinic's records ever are.
--
-- Change the email address below to your own account's before running
-- this file.

update public.profiles
set role = 'super_admin'
where id = (select id from auth.users where email = 'you@example.com');

-- Clinics and their join codes, to check the result. Rename a clinic from the
-- app (Settings → Admin console → Clinics).
select c.clinic_no,
       c.name,
       c.join_code,
       (select count(*) from public.profiles p where p.clinic_id = c.id) as members
from public.clinics c
order by c.created_at;
