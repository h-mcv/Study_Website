-- Lets an announcement (see 0009_announcements.sql) be aimed at specific
-- people instead of everyone -- e.g. a note to one student about something
-- only relevant to them, rather than broadcasting it site-wide.
--
-- Targeting is by email rather than user id so admin-api never has to
-- resolve emails to ids itself for the RLS check to work (it still
-- validates the emails belong to real accounts before saving, purely to
-- catch typos) -- auth.jwt()->>'email' is the standard way to read the
-- signed-in user's own email inside a policy. NULL means untargeted,
-- i.e. visible to everyone, same as before this migration.
alter table public.announcements add column if not exists target_emails text[];

drop policy if exists "read active announcements" on public.announcements;
create policy "read active announcements" on public.announcements
  for select using (
    active = true
    and (
      target_emails is null
      or lower(coalesce(auth.jwt() ->> 'email', '')) = any (target_emails)
    )
  );
