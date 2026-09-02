-- Backs the Garmin watch companion app's pairing flow. The watch has no
-- browser, so login happens by pasting a short-lived code (shown on the
-- website while already signed in) into the watch app's settings in Garmin
-- Connect Mobile; the watch then trades that code for a long-lived token.
-- See supabase/functions/watch-pair, watch-exchange, watch-schedule.
--
-- Neither table is meant for direct client-side reads/writes the way
-- study_state and spotify_tokens are -- watch_pairing_codes and the
-- WRITE side of watch_tokens are edge-function-only (service role), since
-- minting a code or a token requires server-side logic (expiry, hashing,
-- consuming a code exactly once). watch_tokens gets narrow authenticated
-- policies below so the website's "Disconnect watch" UI can list/remove a
-- user's own paired watches without needing yet another edge function.

create table if not exists public.watch_pairing_codes (
  code text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

alter table public.watch_pairing_codes enable row level security;

-- service_role (used only by the edge functions) bypasses RLS, but per
-- 0002_grant_study_state_privileges.sql the base table GRANT is still
-- required even for roles RLS would otherwise let through -- granted
-- explicitly here rather than assuming it.
grant select, insert, update, delete on public.watch_pairing_codes to service_role;

-- One row per paired watch. token_hash is SHA-256 of the opaque token the
-- watch holds -- the plaintext token itself is never stored, same principle
-- as a password hash, since this row is effectively a long-lived API key.
create table if not exists public.watch_tokens (
  token_hash text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  last_used_at timestamptz
);

alter table public.watch_tokens enable row level security;

create index if not exists watch_tokens_user_id_idx on public.watch_tokens (user_id);

create policy "select own watch tokens" on public.watch_tokens
  for select using (auth.uid() = user_id);

create policy "delete own watch tokens" on public.watch_tokens
  for delete using (auth.uid() = user_id);

grant select, delete on public.watch_tokens to authenticated;
grant select, insert, update, delete on public.watch_tokens to service_role;
