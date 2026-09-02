-- One row per signed-in user, holding just enough to resume a Spotify
-- session on a new device without re-authorizing: the long-lived refresh
-- token, from which a fresh access token is derived locally in the browser.
-- No access token is stored here -- it's short-lived (~1hr) and never needs
-- to survive a device change. RLS mirrors study_state: a user can only ever
-- read/write/delete their own row.
create table if not exists public.spotify_tokens (
  user_id uuid primary key references auth.users(id) on delete cascade,
  refresh_token text not null,
  updated_at timestamptz not null default now()
);

alter table public.spotify_tokens enable row level security;

create policy "select own spotify token" on public.spotify_tokens
  for select using (auth.uid() = user_id);

create policy "insert own spotify token" on public.spotify_tokens
  for insert with check (auth.uid() = user_id);

create policy "update own spotify token" on public.spotify_tokens
  for update using (auth.uid() = user_id);

create policy "delete own spotify token" on public.spotify_tokens
  for delete using (auth.uid() = user_id);

-- RLS policies alone don't grant the underlying table privilege -- see
-- 0002_grant_study_state_privileges.sql, which had to fix exactly this gap
-- for study_state after the fact. Granted here up front instead.
grant select, insert, update, delete on public.spotify_tokens to authenticated;
