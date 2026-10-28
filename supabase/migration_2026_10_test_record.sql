-- Auris: columns for the standard test protocol (October 2026).
--
-- Run this once in the Supabase SQL Editor on a project that was set up with
-- an older supabase/schema.sql. It only adds two nullable columns, so it is
-- safe to run more than once and does not touch existing rows or roles.
--
--   sessions.protocol_json  How the test was run (pre-test checklist, retests,
--                           skipped frequencies, presses between tones...).
--   thresholds.qualifier    Null for an ordinary threshold, 'atFloor' for a
--                           result at or below -10 dB HL, 'notEstablished'
--                           when no threshold could be established.
--
-- Until this has run, the app keeps saving tests on the device, but their
-- upload to Supabase is rejected (the columns do not exist yet) and retried
-- on the next sync.

alter table public.sessions   add column if not exists protocol_json text;
alter table public.thresholds add column if not exists qualifier     text;

-- Ask the API to pick up the new columns straight away.
notify pgrst, 'reload schema';
