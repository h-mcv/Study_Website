-- Graduation-year chat rooms: every student at the same hardcoded school (see SCHOOLS in index.html) who is
-- set to graduate the same year is automatically in the same room, no invite needed -- same "no membership
-- rows required" trick 0010 uses for the "Everyone" room, generalised from a single is_global flag to an
-- auto_key a room can be matched against. graduationYear is fixed client-side the moment a student's year
-- group is first confirmed (see computeGraduationYear's comment in index.html), so the key is stable across
-- the yearly rollover even though yearGroup itself advances every year.

alter table public.chat_rooms add column if not exists auto_key text unique;

-- ---------------------------------------------------------------------------
-- Membership check, extended with a third case: a room whose auto_key matches
-- "<schoolId>:<graduationYear>" computed from the CALLER's own study_state settings (never the room's
-- created_by, which chat_capture_identity sets to whichever user happened to trigger the room's creation --
-- see ensure_school_year_room below). Everyone with matching settings sees the room even before their own
-- membership row exists, same as is_global; ensure_school_year_room adds that row eagerly anyway so the
-- Members list (driven by chat_room_members, unlike the "Everyone" room's client-side generic text) is
-- populated without needing a separate lookup path.
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
  );
$$;

-- ---------------------------------------------------------------------------
-- Finds or creates the room for a given school+graduation-year and adds the caller as a member. Safe to call
-- repeatedly (e.g. opportunistically from the Chat Rooms page) -- on_conflict makes both the room lookup and
-- the membership insert idempotent. SECURITY DEFINER for the same reason create_chat_room is: chat_rooms and
-- chat_room_members get no INSERT grant for `authenticated` at all (see 0010's header comment).
-- ---------------------------------------------------------------------------
create or replace function public.ensure_school_year_room(p_school_id text, p_school_name text, p_graduation_year int)
returns public.chat_rooms
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_school_id text := trim(coalesce(p_school_id, ''));
  v_school_name text := trim(coalesce(p_school_name, ''));
  v_key text;
  v_room public.chat_rooms;
begin
  if v_uid is null then raise exception 'Sign in to join your school''s chat room.'; end if;
  if v_school_id = '' or v_school_id = 'other' then raise exception 'No school set.'; end if;
  if v_school_name = '' then raise exception 'School name is required.'; end if;
  if p_graduation_year is null or p_graduation_year < 2000 or p_graduation_year > 2100 then
    raise exception 'Invalid graduation year.';
  end if;
  v_key := v_school_id || ':' || p_graduation_year::text;

  insert into public.chat_rooms (name, is_global, auto_key)
    values (v_school_name || ' · Class of ' || p_graduation_year::text, false, v_key)
    on conflict (auto_key) do nothing;

  select * into v_room from public.chat_rooms where auto_key = v_key;

  insert into public.chat_room_members (room_id, user_id)
    values (v_room.id, v_uid)
    on conflict (room_id, user_id) do nothing;

  return v_room;
end;
$$;

revoke execute on function public.ensure_school_year_room(text, text, int) from public, anon;
grant execute on function public.ensure_school_year_room(text, text, int) to authenticated;
