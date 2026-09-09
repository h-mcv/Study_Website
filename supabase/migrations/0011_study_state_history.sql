-- Nightly point-in-time snapshots of every user's study_state, entirely
-- inside the free-tier database -- no Supabase Pro backups/PITR needed.
-- pg_cron (a standard Postgres extension, available on all Supabase plans
-- including Free) runs a scheduled job that copies the current state of
-- every row in study_state into this history table once a day. A second
-- job prunes anything older than 30 days so this stays small and bounded.
--
-- This table is read-only from the client (RLS grants each user SELECT on
-- their own snapshots only) -- writes only ever come from the cron job,
-- which runs as the table owner and bypasses RLS.
create table if not exists public.study_state_history (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  state jsonb not null,
  snapshotted_at timestamptz not null default now()
);

create index if not exists study_state_history_user_id_snapshotted_at_idx
  on public.study_state_history (user_id, snapshotted_at desc);

alter table public.study_state_history enable row level security;

create policy "select own state history" on public.study_state_history
  for select using (auth.uid() = user_id);

grant select on public.study_state_history to authenticated;

-- Enables scheduled SQL jobs (cron.schedule / cron.job / cron.job_run_details).
create extension if not exists pg_cron with schema extensions;

select cron.schedule(
  'study-state-nightly-snapshot',
  '0 3 * * *', -- 03:00 UTC daily
  $$ insert into public.study_state_history (user_id, state, snapshotted_at)
     select user_id, state, now() from public.study_state; $$
);

select cron.schedule(
  'study-state-history-prune',
  '30 3 * * *', -- shortly after the snapshot job, so pruning never races an in-flight insert
  $$ delete from public.study_state_history where snapshotted_at < now() - interval '30 days'; $$
);
