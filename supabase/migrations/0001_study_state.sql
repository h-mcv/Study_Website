-- One row per signed-in user, holding the entire app state blob (same shape
-- that was previously kept only in localStorage). RLS makes sure the
-- publishable/anon key can never be used to read or write anyone else's row.
create table if not exists public.study_state (
  user_id uuid primary key references auth.users(id) on delete cascade,
  state jsonb not null,
  updated_at timestamptz not null default now()
);

alter table public.study_state enable row level security;

create policy "select own state" on public.study_state
  for select using (auth.uid() = user_id);

create policy "insert own state" on public.study_state
  for insert with check (auth.uid() = user_id);

create policy "update own state" on public.study_state
  for update using (auth.uid() = user_id);
