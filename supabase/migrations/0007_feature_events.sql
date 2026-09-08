-- Lightweight per-user feature-usage telemetry, added to support the admin
-- dashboard's analytics tab (and the "how does feature use correlate with
-- results" science-project question). One row per UI action a signed-in
-- user takes -- the client fires these itself (fire-and-forget, never
-- blocking the UI, see logFeatureEvent() in index.html) for every
-- data-action click, so this covers "every feature" without hand-instrumenting
-- each one individually.
--
-- Same RLS shape as study_state/spotify_tokens for the insert side (a user
-- can only ever write rows tagged with their own id), but deliberately has
-- NO select policy for `authenticated` -- a user's own usage log is not
-- exposed back to them via the anon/publishable key, only readable by
-- service_role (i.e. only from inside the admin-api edge function, after
-- that function has independently verified the caller is the admin).
create table if not exists public.feature_events (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  event text not null,
  meta jsonb,
  created_at timestamptz not null default now()
);

create index if not exists feature_events_user_id_idx on public.feature_events (user_id);
create index if not exists feature_events_created_at_idx on public.feature_events (created_at);
create index if not exists feature_events_event_idx on public.feature_events (event);

alter table public.feature_events enable row level security;

drop policy if exists "insert own feature events" on public.feature_events;
create policy "insert own feature events" on public.feature_events
  for insert with check (auth.uid() = user_id);

-- Base table GRANT is a separate check from RLS (see the comment in
-- 0002_grant_study_state_privileges.sql) -- both are required.
grant insert on public.feature_events to authenticated;
grant select, insert, delete on public.feature_events to service_role;

-- Telemetry, not a system of record: old rows are pruned automatically so
-- this table can't grow forever or become its own privacy liability.
-- Called on a schedule by pg_cron below; safe to call manually too.
create or replace function public.prune_old_feature_events()
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.feature_events where created_at < now() - interval '180 days';
$$;

revoke execute on function public.prune_old_feature_events() from public, anon, authenticated;
grant execute on function public.prune_old_feature_events() to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('prune-feature-events', '0 3 * * *', 'select public.prune_old_feature_events();');
  end if;
end $$;
