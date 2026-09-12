-- Async multiplayer games (starting with Ultimate Tic-Tac-Toe, played from the Games
-- section): a challenge/accept flow identical in shape to chat_invites/chat_room_members
-- (see 0010_chat_rooms.sql), then a single game_matches row per game that both players
-- read and move on. game_type is a free string (not an enum) so a future second
-- turn-based game can reuse this same pair of tables with no new migration.
--
-- Trust model for moves: game_matches' board/turn/status/winner columns are writable by
-- either player via a plain authenticated UPDATE (no SECURITY DEFINER function) gated by
-- RLS to "it's currently your turn" -- the actual move-legality and win-detection logic
-- lives in JS on the client (same engine both players' browsers use to render the board),
-- not re-validated server-side. That mirrors this app's existing trust boundary (e.g.
-- chat_messages content isn't validated either) and is a deliberate simplification for a
-- casual feature between two people who already know each other, not a competitive/ranked
-- system -- a player determined to cheat their own client could submit an illegal board.
-- Column-level GRANTs (not just RLS) stop either player from touching player_x/player_o/
-- game_type/id, so a move can never reassign the match to someone else.

create table if not exists public.game_invites (
  id uuid primary key default gen_random_uuid(),
  game_type text not null default 'ultimate_ttt' check (length(game_type) <= 40),
  inviter_id uuid references auth.users(id) on delete set null,
  inviter_name text not null,
  inviter_email text not null,
  invitee_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
  match_id uuid,
  created_at timestamptz not null default now(),
  responded_at timestamptz
);
create index if not exists game_invites_invitee_status_idx on public.game_invites (invitee_id, status);
create index if not exists game_invites_inviter_idx on public.game_invites (inviter_id);
-- One live pending challenge per (inviter, invitee, game) at a time -- re-challenging
-- after a decline is fine (that row's status is no longer 'pending').
create unique index if not exists game_invites_pending_unique
  on public.game_invites (inviter_id, invitee_id, game_type) where status = 'pending';

create table if not exists public.game_matches (
  id uuid primary key default gen_random_uuid(),
  game_type text not null default 'ultimate_ttt' check (length(game_type) <= 40),
  player_x uuid not null references auth.users(id) on delete cascade,
  player_o uuid not null references auth.users(id) on delete cascade,
  player_x_name text not null,
  player_o_name text not null,
  board jsonb not null default '{}'::jsonb,
  turn text not null default 'x' check (turn in ('x', 'o')),
  status text not null default 'active' check (status in ('active', 'x_won', 'o_won', 'draw')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists game_matches_player_x_idx on public.game_matches (player_x);
create index if not exists game_matches_player_o_idx on public.game_matches (player_o);

-- Same identity-capture approach as chat_capture_identity() in 0010_chat_rooms.sql --
-- inviter_name/email always come from the caller's own session, never the client body.
create or replace function public.game_capture_identity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_email text;
  v_first text;
  v_last text;
  v_name text;
begin
  if v_uid is not null then
    v_email := auth.email();
    select (state->'settings'->>'firstName'), (state->'settings'->>'lastName')
      into v_first, v_last
      from public.study_state where user_id = v_uid;
    v_name := nullif(trim(coalesce(v_first, '') || ' ' || coalesce(v_last, '')), '');
    if v_name is null then v_name := split_part(coalesce(v_email, 'Someone'), '@', 1); end if;

    if TG_TABLE_NAME = 'game_invites' then
      NEW.inviter_id := v_uid;
      NEW.inviter_name := v_name;
      NEW.inviter_email := v_email;
      NEW.status := 'pending';
      NEW.responded_at := null;
      NEW.match_id := null;
    end if;
  end if;
  return NEW;
end;
$$;

drop trigger if exists game_invites_capture_identity on public.game_invites;
create trigger game_invites_capture_identity before insert on public.game_invites
  for each row execute function public.game_capture_identity();

-- The only way to send a challenge -- game_invites gets no INSERT grant at all (same
-- reasoning as chat_rooms/chat_room_members in 0010), so a player can't forge who a
-- challenge is from.
create or replace function public.create_game_invite(p_invitee_id uuid, p_game_type text default 'ultimate_ttt')
returns public.game_invites
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_invite public.game_invites;
begin
  if v_uid is null then raise exception 'Sign in to challenge someone.'; end if;
  if p_invitee_id = v_uid then raise exception 'You cannot challenge yourself.'; end if;
  if not exists (select 1 from auth.users where id = p_invitee_id) then
    raise exception 'That user could not be found.';
  end if;

  insert into public.game_invites (game_type, invitee_id)
    values (coalesce(p_game_type, 'ultimate_ttt'), p_invitee_id)
    returning * into v_invite;

  return v_invite;
end;
$$;

revoke execute on function public.create_game_invite(uuid, text) from public, anon;
grant execute on function public.create_game_invite(uuid, text) to authenticated;

-- Accepting creates the match atomically (both rows or neither) and links it back onto
-- the invite so the inviter's own poll can find it.
create or replace function public.accept_game_invite(p_invite_id uuid)
returns public.game_matches
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_invite public.game_invites;
  v_invitee_name text;
  v_match public.game_matches;
begin
  if v_uid is null then raise exception 'Sign in to respond to challenges.'; end if;

  update public.game_invites
    set status = 'accepted', responded_at = now()
    where id = p_invite_id and invitee_id = v_uid and status = 'pending'
    returning * into v_invite;

  if v_invite is null then raise exception 'That challenge is no longer pending.'; end if;

  select nullif(trim(coalesce(state->'settings'->>'firstName', '') || ' ' || coalesce(state->'settings'->>'lastName', '')), '')
    into v_invitee_name
    from public.study_state where user_id = v_uid;
  if v_invitee_name is null then v_invitee_name := split_part(coalesce(auth.email(), 'Someone'), '@', 1); end if;

  insert into public.game_matches (game_type, player_x, player_o, player_x_name, player_o_name, board, turn, status)
    values (v_invite.game_type, v_invite.inviter_id, v_uid, v_invite.inviter_name, v_invitee_name, '{}'::jsonb, 'x', 'active')
    returning * into v_match;

  update public.game_invites set match_id = v_match.id where id = p_invite_id;

  return v_match;
end;
$$;

revoke execute on function public.accept_game_invite(uuid) from public, anon;
grant execute on function public.accept_game_invite(uuid) to authenticated;

create or replace function public.decline_game_invite(p_invite_id uuid)
returns void
language sql
security definer
set search_path = public
as $$
  update public.game_invites set status = 'declined', responded_at = now()
    where id = p_invite_id and invitee_id = auth.uid() and status = 'pending';
$$;

revoke execute on function public.decline_game_invite(uuid) from public, anon;
grant execute on function public.decline_game_invite(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.game_invites enable row level security;
alter table public.game_matches enable row level security;

drop policy if exists "select my game invites" on public.game_invites;
create policy "select my game invites" on public.game_invites
  for select using (invitee_id = auth.uid() or inviter_id = auth.uid());

drop policy if exists "select my matches" on public.game_matches;
create policy "select my matches" on public.game_matches
  for select using (player_x = auth.uid() or player_o = auth.uid());

-- Move-legality and win-detection are the client engine's job (see the note at the top of
-- this file); this policy only enforces that you may write a match row exclusively while
-- it's your turn. `with check (true)` is deliberate, not an oversight: Postgres re-checks
-- USING against the *new* row too when WITH CHECK is omitted on an UPDATE policy, which
-- would fail every legal move here (it flips `turn` to the opponent, so the new row no
-- longer satisfies "it's my turn"). The column GRANT below is what actually keeps a mover
-- from touching anything but board/turn/status/updated_at.
drop policy if exists "move on my turn" on public.game_matches;
create policy "move on my turn" on public.game_matches
  for update
  using (status = 'active' and ((turn = 'x' and player_x = auth.uid()) or (turn = 'o' and player_o = auth.uid())))
  with check (true);

grant select on public.game_invites to authenticated;
grant select, insert, update, delete on public.game_invites to service_role;
grant select on public.game_matches to authenticated;
grant update (board, turn, status, updated_at) on public.game_matches to authenticated;
grant select, insert, update, delete on public.game_matches to service_role;
