-- Chat Rooms: one built-in "Everyone" room every signed-in user is already a
-- member of (implicitly -- see is_chat_room_member below, no membership row
-- needed), plus user-created rooms joined only by invite. Invites are never
-- emailed: they're a normal row in chat_invites that shows up as an
-- accept/decline notification on the Chat Rooms page, same "poll for it"
-- style as the rest of this app (no Realtime is used anywhere here).
--
-- Trust model: every "who did this" field (created_by_name/email,
-- member_name/email, inviter_name/email, author_name) is filled in by the
-- chat_capture_identity() trigger below from the ACTING USER's own session
-- (auth.uid()/auth.email()) and their own study_state.settings name, never
-- from whatever the client sent -- so a user can't invite someone while
-- claiming to be a different person, and an invitee can trust the inviter
-- name+email shown to them. Because of this, chat_rooms and chat_room_members
-- get NO insert grant at all for `authenticated`: the only way to create a
-- room or join one is through create_chat_room()/accept_chat_invite() below,
-- both SECURITY DEFINER, both deriving identity the same trigger-safe way.

create table if not exists public.chat_rooms (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) > 0 and length(name) <= 60),
  is_global boolean not null default false,
  created_by uuid references auth.users(id) on delete set null,
  created_by_name text,
  created_by_email text,
  created_at timestamptz not null default now()
);

create table if not exists public.chat_room_members (
  room_id uuid not null references public.chat_rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  member_name text not null,
  member_email text not null,
  joined_at timestamptz not null default now(),
  primary key (room_id, user_id)
);
create index if not exists chat_room_members_user_id_idx on public.chat_room_members (user_id);

create table if not exists public.chat_messages (
  id bigint generated always as identity primary key,
  room_id uuid not null references public.chat_rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  author_name text not null,
  body text not null check (length(trim(body)) > 0 and length(body) <= 4000),
  created_at timestamptz not null default now()
);
create index if not exists chat_messages_room_id_created_at_idx on public.chat_messages (room_id, created_at);

create table if not exists public.chat_invites (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.chat_rooms(id) on delete cascade,
  room_name text not null,
  inviter_id uuid references auth.users(id) on delete set null,
  inviter_name text not null,
  inviter_email text not null,
  invitee_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
  created_at timestamptz not null default now(),
  responded_at timestamptz
);
create index if not exists chat_invites_invitee_status_idx on public.chat_invites (invitee_id, status);
create index if not exists chat_invites_room_id_idx on public.chat_invites (room_id);
-- Only one live pending invite per (room, invitee) -- re-inviting after a
-- decline is fine (that row's status is no longer 'pending'), but two
-- simultaneous pending invites to the same room for the same person aren't.
create unique index if not exists chat_invites_pending_unique
  on public.chat_invites (room_id, invitee_id) where status = 'pending';

-- ---------------------------------------------------------------------------
-- Identity-capture trigger. Runs BEFORE INSERT on all four tables (installed
-- per-table below) and overwrites the "who" columns from the session's own
-- auth.uid()/auth.email() plus their own study_state settings -- never from
-- client-supplied values -- whenever this is a real request from a signed-in
-- user (auth.uid() is null during the service-role/migration-time seed
-- insert further down, so that row's literal values pass through untouched).
-- ---------------------------------------------------------------------------
create or replace function public.chat_capture_identity()
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

    if TG_TABLE_NAME = 'chat_rooms' then
      NEW.created_by := v_uid;
      NEW.created_by_name := v_name;
      NEW.created_by_email := v_email;
      NEW.is_global := false; -- only the seed row (inserted with no auth context) may be global
    elsif TG_TABLE_NAME = 'chat_room_members' then
      NEW.user_id := v_uid;
      NEW.member_name := v_name;
      NEW.member_email := v_email;
    elsif TG_TABLE_NAME = 'chat_invites' then
      NEW.inviter_id := v_uid;
      NEW.inviter_name := v_name;
      NEW.inviter_email := v_email;
      NEW.status := 'pending';
      NEW.responded_at := null;
      select r.name into NEW.room_name from public.chat_rooms r where r.id = NEW.room_id;
    elsif TG_TABLE_NAME = 'chat_messages' then
      NEW.user_id := v_uid;
      NEW.author_name := v_name;
    end if;
  end if;
  return NEW;
end;
$$;

drop trigger if exists chat_rooms_capture_identity on public.chat_rooms;
create trigger chat_rooms_capture_identity before insert on public.chat_rooms
  for each row execute function public.chat_capture_identity();

drop trigger if exists chat_room_members_capture_identity on public.chat_room_members;
create trigger chat_room_members_capture_identity before insert on public.chat_room_members
  for each row execute function public.chat_capture_identity();

drop trigger if exists chat_invites_capture_identity on public.chat_invites;
create trigger chat_invites_capture_identity before insert on public.chat_invites
  for each row execute function public.chat_capture_identity();

drop trigger if exists chat_messages_capture_identity on public.chat_messages;
create trigger chat_messages_capture_identity before insert on public.chat_messages
  for each row execute function public.chat_capture_identity();

-- ---------------------------------------------------------------------------
-- Membership check used by every RLS policy below, so the actual "am I
-- allowed to see this room" logic lives in exactly one place. SECURITY
-- DEFINER (owned by a role that bypasses RLS, same as admin_user_metrics in
-- 0008) so it can read chat_rooms/chat_room_members itself without
-- recursively re-triggering the very policies that call it.
-- ---------------------------------------------------------------------------
create or replace function public.is_chat_room_member(p_room_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.chat_rooms r
    where r.id = p_room_id and (r.is_global or r.created_by = auth.uid())
  ) or exists (
    select 1 from public.chat_room_members m
    where m.room_id = p_room_id and m.user_id = auth.uid()
  );
$$;

revoke execute on function public.is_chat_room_member(uuid) from public, anon;
grant execute on function public.is_chat_room_member(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- The only way to create a room or accept an invite -- both SECURITY
-- DEFINER, so neither chat_rooms nor chat_room_members needs (or gets) an
-- INSERT grant for `authenticated` at all; see the note at the top of this
-- file. Each does its own multi-step write atomically, so a failure partway
-- through can't leave a room with no creator-member or an invite marked
-- accepted with no membership row to match.
-- ---------------------------------------------------------------------------
create or replace function public.create_chat_room(p_name text)
returns public.chat_rooms
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_name text := trim(coalesce(p_name, ''));
  v_room public.chat_rooms;
begin
  if v_uid is null then raise exception 'Sign in to create a chat room.'; end if;
  if v_name = '' then raise exception 'Room name is required.'; end if;
  if length(v_name) > 60 then raise exception 'Room name must be 60 characters or fewer.'; end if;

  insert into public.chat_rooms (name, is_global, created_by)
    values (v_name, false, v_uid)
    returning * into v_room;

  insert into public.chat_room_members (room_id, user_id)
    values (v_room.id, v_uid);

  return v_room;
end;
$$;

revoke execute on function public.create_chat_room(text) from public, anon;
grant execute on function public.create_chat_room(text) to authenticated;

create or replace function public.accept_chat_invite(p_invite_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_room_id uuid;
begin
  if v_uid is null then raise exception 'Sign in to respond to invites.'; end if;

  update public.chat_invites
    set status = 'accepted', responded_at = now()
    where id = p_invite_id and invitee_id = v_uid and status = 'pending'
    returning room_id into v_room_id;

  if v_room_id is null then
    raise exception 'That invite is no longer pending.';
  end if;

  insert into public.chat_room_members (room_id, user_id)
    values (v_room_id, v_uid)
    on conflict (room_id, user_id) do nothing;
end;
$$;

revoke execute on function public.accept_chat_invite(uuid) from public, anon;
grant execute on function public.accept_chat_invite(uuid) to authenticated;

-- Lets any signed-in user look someone up by full name or email to invite
-- them -- the only cross-user read in this feature, deliberately narrow
-- (id/name/email only, 2+ characters, capped results, never yourself).
create or replace function public.chat_search_users(p_query text)
returns table (user_id uuid, name text, email text)
language sql
stable
security definer
set search_path = public
as $$
  select u.id as user_id,
         coalesce(
           nullif(trim(coalesce(ss.state->'settings'->>'firstName', '') || ' ' || coalesce(ss.state->'settings'->>'lastName', '')), ''),
           split_part(u.email, '@', 1)
         ) as name,
         u.email
  from auth.users u
  left join public.study_state ss on ss.user_id = u.id
  where p_query is not null
    and length(trim(p_query)) >= 2
    and u.id <> auth.uid()
    and u.email is not null
    and (
      u.email ilike '%' || trim(p_query) || '%'
      or (coalesce(ss.state->'settings'->>'firstName', '') || ' ' || coalesce(ss.state->'settings'->>'lastName', '')) ilike '%' || trim(p_query) || '%'
    )
  order by name
  limit 8;
$$;

revoke execute on function public.chat_search_users(text) from public, anon;
grant execute on function public.chat_search_users(text) to authenticated;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.chat_rooms enable row level security;
alter table public.chat_room_members enable row level security;
alter table public.chat_messages enable row level security;
alter table public.chat_invites enable row level security;

drop policy if exists "select visible rooms" on public.chat_rooms;
create policy "select visible rooms" on public.chat_rooms
  for select using (public.is_chat_room_member(id));

drop policy if exists "select fellow members" on public.chat_room_members;
create policy "select fellow members" on public.chat_room_members
  for select using (public.is_chat_room_member(room_id));

drop policy if exists "leave a room" on public.chat_room_members;
create policy "leave a room" on public.chat_room_members
  for delete using (user_id = auth.uid());

drop policy if exists "select room messages" on public.chat_messages;
create policy "select room messages" on public.chat_messages
  for select using (public.is_chat_room_member(room_id));

drop policy if exists "send room messages" on public.chat_messages;
create policy "send room messages" on public.chat_messages
  for insert with check (public.is_chat_room_member(room_id) and user_id = auth.uid());

drop policy if exists "select my invites" on public.chat_invites;
create policy "select my invites" on public.chat_invites
  for select using (invitee_id = auth.uid() or inviter_id = auth.uid());

drop policy if exists "send invites to my rooms" on public.chat_invites;
create policy "send invites to my rooms" on public.chat_invites
  for insert with check (public.is_chat_room_member(room_id) and invitee_id <> auth.uid() and inviter_id = auth.uid());

drop policy if exists "respond to my invites" on public.chat_invites;
create policy "respond to my invites" on public.chat_invites
  for update using (invitee_id = auth.uid()) with check (invitee_id = auth.uid());

-- Base table GRANTs are separate from RLS (see 0002's comment) -- deliberately
-- no insert grant on chat_rooms/chat_room_members, see the note at the top.
grant select on public.chat_rooms to authenticated;
grant select, delete on public.chat_room_members to authenticated;
grant select, insert on public.chat_messages to authenticated;
grant select, insert on public.chat_invites to authenticated;
-- An invitee may only ever flip their own invite to accepted/declined --
-- never touch who invited them, which room, etc.
grant update (status, responded_at) on public.chat_invites to authenticated;
grant select, insert, update, delete on public.chat_rooms to service_role;
grant select, insert, update, delete on public.chat_room_members to service_role;
grant select, insert, update, delete on public.chat_messages to service_role;
grant select, insert, update, delete on public.chat_invites to service_role;

-- The one built-in room everyone already belongs to (see is_chat_room_member
-- above -- is_global rooms need no membership rows at all). Fixed id so this
-- stays idempotent across re-runs and future migrations can reference it.
insert into public.chat_rooms (id, name, is_global, created_by, created_by_name, created_by_email)
  values ('00000000-0000-0000-0000-000000000001', 'Everyone', true, null, null, null)
  on conflict (id) do nothing;
