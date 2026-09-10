-- Direct (one-on-one) chats: a chat_rooms row with is_dm = true and no invite/accept step --
-- unlike a normal room, a DM is created the moment either side starts it (start_dm below), same
-- "no membership rows required" trick 0010's is_global and 0013's auto_key already use, just keyed
-- to a *pair* of users instead of "everyone" or "everyone at this school+year". dm_user_a is always
-- the lexicographically-smaller of the two ids (dm_user_b the other) so the pair has one canonical
-- ordering to key a unique index on, regardless of who started the conversation.
--
-- dm_a_name/dm_b_name are snapshotted once at creation time, same staleness tradeoff
-- created_by_name/member_name/etc already accept elsewhere in this file (see 0010's header comment)
-- -- good enough since a display name changing later is rare and low-stakes here.

alter table public.chat_rooms add column if not exists is_dm boolean not null default false;
alter table public.chat_rooms add column if not exists dm_user_a uuid references auth.users(id) on delete cascade;
alter table public.chat_rooms add column if not exists dm_user_b uuid references auth.users(id) on delete cascade;
alter table public.chat_rooms add column if not exists dm_a_name text;
alter table public.chat_rooms add column if not exists dm_b_name text;

alter table public.chat_rooms drop constraint if exists chat_rooms_dm_pair_order_check;
alter table public.chat_rooms add constraint chat_rooms_dm_pair_order_check
  check (dm_user_a is null or dm_user_b is null or dm_user_a < dm_user_b);

-- A DM room carries no `name` (the client derives a display name from dm_a_name/dm_b_name instead),
-- so the not-null/non-empty name check from 0010 has to relax to allow that one case.
alter table public.chat_rooms alter column name drop not null;
alter table public.chat_rooms drop constraint if exists chat_rooms_name_check;
alter table public.chat_rooms add constraint chat_rooms_name_check
  check (name is null or (length(trim(name)) > 0 and length(name) <= 60));

create unique index if not exists chat_rooms_dm_pair_unique
  on public.chat_rooms (dm_user_a, dm_user_b) where is_dm;

-- ---------------------------------------------------------------------------
-- Membership check, extended with a fourth case: either side of a DM pair is always a member of
-- that room, no chat_room_members row needed at all (same shortcut is_global/auto_key already get).
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
  ) or exists (
    select 1 from public.chat_rooms r, public.study_state ss
    where r.id = p_room_id and r.auto_key is not null and ss.user_id = auth.uid()
      and r.auto_key = (ss.state->'settings'->>'schoolId') || ':' || (ss.state->'settings'->>'graduationYear')
  ) or exists (
    select 1 from public.chat_rooms r
    where r.id = p_room_id and r.is_dm and (r.dm_user_a = auth.uid() or r.dm_user_b = auth.uid())
  );
$$;

-- ---------------------------------------------------------------------------
-- Finds or creates the DM room between the caller and p_other_user_id, and returns it. Safe to call
-- repeatedly -- on_conflict makes the lookup idempotent, so "Message" on someone you already have a
-- DM with just reopens the same room. SECURITY DEFINER for the same reason create_chat_room and
-- ensure_school_year_room are: chat_rooms gets no INSERT grant for `authenticated` at all (0010).
-- ---------------------------------------------------------------------------
create or replace function public.start_dm(p_other_user_id uuid)
returns public.chat_rooms
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_a uuid;
  v_b uuid;
  v_my_name text;
  v_other_name text;
  v_room public.chat_rooms;
begin
  if v_uid is null then raise exception 'Sign in to message someone.'; end if;
  if p_other_user_id is null or p_other_user_id = v_uid then raise exception 'Choose someone else to message.'; end if;
  if not exists (select 1 from auth.users where id = p_other_user_id) then
    raise exception 'That user could not be found.';
  end if;

  select coalesce(
      nullif(trim(coalesce(ss.state->'settings'->>'firstName', '') || ' ' || coalesce(ss.state->'settings'->>'lastName', '')), ''),
      split_part(u.email, '@', 1))
    into v_my_name
    from auth.users u left join public.study_state ss on ss.user_id = u.id where u.id = v_uid;

  select coalesce(
      nullif(trim(coalesce(ss.state->'settings'->>'firstName', '') || ' ' || coalesce(ss.state->'settings'->>'lastName', '')), ''),
      split_part(u.email, '@', 1))
    into v_other_name
    from auth.users u left join public.study_state ss on ss.user_id = u.id where u.id = p_other_user_id;

  v_a := least(v_uid, p_other_user_id);
  v_b := greatest(v_uid, p_other_user_id);

  insert into public.chat_rooms (is_dm, dm_user_a, dm_user_b, dm_a_name, dm_b_name)
    values (true, v_a, v_b,
      case when v_a = v_uid then v_my_name else v_other_name end,
      case when v_b = v_uid then v_my_name else v_other_name end)
    on conflict (dm_user_a, dm_user_b) where is_dm do nothing;

  select * into v_room from public.chat_rooms where dm_user_a = v_a and dm_user_b = v_b and is_dm;

  return v_room;
end;
$$;

revoke execute on function public.start_dm(uuid) from public, anon;
grant execute on function public.start_dm(uuid) to authenticated;
