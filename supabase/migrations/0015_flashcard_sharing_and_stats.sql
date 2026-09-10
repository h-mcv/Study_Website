-- Flashcard set sharing (code-gated, like a Quizlet share link but scoped to this app's own userbase
-- rather than a public marketplace) and a narrow cross-user "public stats" table used to power a
-- streak/leaderboard tab inside chat rooms (see index.html's renderChatRoomLeaderboardTab). Both follow
-- the same trust model as 0010_chat_rooms.sql: every "who did this" column is stamped server-side by a
-- BEFORE INSERT trigger from the caller's own auth.uid()/study_state, never trusted from the client.

create table if not exists public.shared_flashcard_sets (
  id uuid primary key default gen_random_uuid(),
  share_code text not null unique,
  owner_id uuid not null references auth.users(id) on delete cascade,
  owner_name text,
  topic text not null check (length(trim(topic)) > 0 and length(topic) <= 120),
  subject_name text,
  deck_snapshot jsonb not null,
  created_at timestamptz not null default now()
);
create index if not exists shared_flashcard_sets_owner_idx on public.shared_flashcard_sets (owner_id);

create or replace function public.shared_set_capture_identity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_first text;
  v_last text;
  v_name text;
begin
  if v_uid is null then raise exception 'Sign in to share a flashcard set.'; end if;
  select (state->'settings'->>'firstName'), (state->'settings'->>'lastName')
    into v_first, v_last from public.study_state where user_id = v_uid;
  v_name := nullif(trim(coalesce(v_first, '') || ' ' || coalesce(v_last, '')), '');
  if v_name is null then v_name := split_part(coalesce(auth.email(), 'Someone'), '@', 1); end if;
  NEW.owner_id := v_uid;
  NEW.owner_name := v_name;
  NEW.share_code := upper(trim(NEW.share_code));
  return NEW;
end;
$$;

drop trigger if exists shared_flashcard_sets_capture_identity on public.shared_flashcard_sets;
create trigger shared_flashcard_sets_capture_identity before insert on public.shared_flashcard_sets
  for each row execute function public.shared_set_capture_identity();

-- The only read path for anyone other than the owner -- deliberately NOT a table SELECT grant, so
-- knowing the code is the only way in (a blanket "select using (true)" policy would let anyone list
-- every shared set ever created, defeating the point of a share code).
create or replace function public.get_shared_flashcard_set(p_code text)
returns public.shared_flashcard_sets
language sql
stable
security definer
set search_path = public
as $$
  select * from public.shared_flashcard_sets where share_code = upper(trim(p_code));
$$;

revoke execute on function public.get_shared_flashcard_set(text) from public, anon;
grant execute on function public.get_shared_flashcard_set(text) to authenticated;

alter table public.shared_flashcard_sets enable row level security;

drop policy if exists "owner can view own shared sets" on public.shared_flashcard_sets;
create policy "owner can view own shared sets" on public.shared_flashcard_sets
  for select using (owner_id = auth.uid());

drop policy if exists "share a set" on public.shared_flashcard_sets;
create policy "share a set" on public.shared_flashcard_sets
  for insert with check (owner_id = auth.uid());

drop policy if exists "revoke own shared set" on public.shared_flashcard_sets;
create policy "revoke own shared set" on public.shared_flashcard_sets
  for delete using (owner_id = auth.uid());

grant select, insert, delete on public.shared_flashcard_sets to authenticated;
grant select, insert, update, delete on public.shared_flashcard_sets to service_role;

-- ---------------------------------------------------------------------------
-- user_public_stats: one row per user, self-reported study stats (streak,
-- cards reviewed, a simple "memory points" gamification number) used to
-- render a leaderboard among people who actually share a chat room with you
-- -- never a global/public leaderboard. Self-reported numbers are an
-- accepted trust tradeoff here (same as e.g. a fitness app's step count);
-- what IS protected is the display_name, so nobody can post stats under a
-- name that isn't their own.
-- ---------------------------------------------------------------------------
create table if not exists public.user_public_stats (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  streak_days int not null default 0 check (streak_days >= 0),
  longest_streak int not null default 0 check (longest_streak >= 0),
  cards_reviewed_total int not null default 0 check (cards_reviewed_total >= 0),
  memory_points int not null default 0 check (memory_points >= 0),
  updated_at timestamptz not null default now()
);

create or replace function public.user_stats_capture_identity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_first text;
  v_last text;
  v_name text;
begin
  if v_uid is null then raise exception 'Sign in required.'; end if;
  select (state->'settings'->>'firstName'), (state->'settings'->>'lastName')
    into v_first, v_last from public.study_state where user_id = v_uid;
  v_name := nullif(trim(coalesce(v_first, '') || ' ' || coalesce(v_last, '')), '');
  if v_name is null then v_name := split_part(coalesce(auth.email(), 'Someone'), '@', 1); end if;
  NEW.user_id := v_uid;
  NEW.display_name := v_name;
  NEW.updated_at := now();
  return NEW;
end;
$$;

drop trigger if exists user_public_stats_capture_identity on public.user_public_stats;
create trigger user_public_stats_capture_identity before insert or update on public.user_public_stats
  for each row execute function public.user_stats_capture_identity();

-- Visible to yourself, or anyone who shares at least one chat_room_members row with you (a real room
-- you both joined -- covers user-created rooms and the eagerly-membership-inserted grad-year rooms from
-- 0013, but NOT the global is_global "Everyone" room, which has no per-user membership rows -- so this
-- never turns into a school-wide public leaderboard by accident).
create or replace function public.can_view_public_stats(p_target uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_target = auth.uid() or exists (
    select 1 from public.chat_room_members m1
    join public.chat_room_members m2 on m1.room_id = m2.room_id
    where m1.user_id = auth.uid() and m2.user_id = p_target
  );
$$;

revoke execute on function public.can_view_public_stats(uuid) from public, anon;
grant execute on function public.can_view_public_stats(uuid) to authenticated;

alter table public.user_public_stats enable row level security;

drop policy if exists "select visible stats" on public.user_public_stats;
create policy "select visible stats" on public.user_public_stats
  for select using (public.can_view_public_stats(user_id));

drop policy if exists "upsert own stats" on public.user_public_stats;
create policy "upsert own stats" on public.user_public_stats
  for insert with check (user_id = auth.uid());

drop policy if exists "update own stats" on public.user_public_stats;
create policy "update own stats" on public.user_public_stats
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());

grant select, insert, update on public.user_public_stats to authenticated;
grant select, insert, update, delete on public.user_public_stats to service_role;
