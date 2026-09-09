-- Lets chat messages carry an image instead of (or alongside) text. Images
-- live in a private Storage bucket, not a public one -- chat rooms are
-- invite-gated, so the pictures people share in them should be exactly as
-- private as the messages are, not visible to anyone who guesses or leaks a
-- URL. Object paths are named "<room_id>/<random>.<ext>", which is what lets
-- the RLS policies below reuse is_chat_room_member() (from 0010) unchanged --
-- storage.foldername(name) splits that path and (storage.foldername(name))[1]
-- is the room_id.

alter table public.chat_messages add column if not exists image_path text;

-- body was NOT NULL with a non-empty check (added in 0010) since every
-- message used to be text; now a message can be image-only, so body itself
-- becomes optional, but a row must still have SOMETHING in it.
alter table public.chat_messages alter column body drop not null;
alter table public.chat_messages drop constraint if exists chat_messages_body_check;
alter table public.chat_messages drop constraint if exists chat_messages_has_content_check;
alter table public.chat_messages add constraint chat_messages_has_content_check
  check (coalesce(trim(body), '') <> '' or image_path is not null);
alter table public.chat_messages drop constraint if exists chat_messages_body_length_check;
alter table public.chat_messages add constraint chat_messages_body_length_check
  check (body is null or length(body) <= 4000);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('chat-images', 'chat-images', false, 8388608, array['image/png', 'image/jpeg', 'image/gif', 'image/webp'])
on conflict (id) do nothing;

drop policy if exists "select chat images in my rooms" on storage.objects;
create policy "select chat images in my rooms" on storage.objects
  for select using (
    bucket_id = 'chat-images'
    and public.is_chat_room_member(((storage.foldername(name))[1])::uuid)
  );

-- Upload-time check is deliberately the same is_chat_room_member() test as
-- select/insert on chat_messages itself -- you can only drop an image into a
-- room you're actually in, same as sending a text message there.
drop policy if exists "upload chat images to my rooms" on storage.objects;
create policy "upload chat images to my rooms" on storage.objects
  for insert with check (
    bucket_id = 'chat-images'
    and public.is_chat_room_member(((storage.foldername(name))[1])::uuid)
  );
