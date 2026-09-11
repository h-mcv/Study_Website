-- Security fix: ensure_school_year_room (0013) took school_id/school_name/graduation_year as plain
-- client-supplied parameters and trusted them outright, unlike every other identity field in the chat
-- feature (see 0010's header comment on chat_capture_identity). Any signed-in user could call the RPC
-- directly with someone ELSE's school_id/graduation_year -- regardless of their own study_state settings
-- -- and it would happily add them as a chat_room_members row for that room, letting them read and post
-- in a school+year chat they have no real affiliation with. Joining that room also incidentally granted
-- them public_stats visibility into everyone else in it via can_view_public_stats (0015), since that
-- check is keyed off shared chat_room_members rows.
--
-- Fix: derive school_id/school_name/graduation_year from the CALLER's own study_state.settings, the same
-- trust model chat_capture_identity already uses, and ignore whatever the client passes in. The function
-- keeps its old signature (client callers are unaffected) but no longer trusts the arguments at all.

create or replace function public.ensure_school_year_room(p_school_id text, p_school_name text, p_graduation_year int)
returns public.chat_rooms
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_school_id text;
  v_school_name text;
  v_graduation_year int;
  v_key text;
  v_room public.chat_rooms;
begin
  if v_uid is null then raise exception 'Sign in to join your school''s chat room.'; end if;

  select trim(coalesce(ss.state->'settings'->>'schoolId', '')),
         trim(coalesce(ss.state->'settings'->>'schoolName', '')),
         nullif(ss.state->'settings'->>'graduationYear', '')::int
    into v_school_id, v_school_name, v_graduation_year
    from public.study_state ss where ss.user_id = v_uid;

  if v_school_id is null or v_school_id = '' or v_school_id = 'other' then raise exception 'No school set.'; end if;
  if v_school_name is null or v_school_name = '' then raise exception 'School name is required.'; end if;
  if v_graduation_year is null or v_graduation_year < 2000 or v_graduation_year > 2100 then
    raise exception 'Invalid graduation year.';
  end if;
  v_key := v_school_id || ':' || v_graduation_year::text;

  insert into public.chat_rooms (name, is_global, auto_key)
    values (v_school_name || ' · Class of ' || v_graduation_year::text, false, v_key)
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
