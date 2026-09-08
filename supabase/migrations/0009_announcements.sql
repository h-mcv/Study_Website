-- Lets the site owner post a banner or popup message that everyone sees the
-- next time they load the app -- announcements, maintenance notices, "try
-- this new feature" nudges, etc. Managed entirely from Admin Mode (see
-- supabase/functions/admin-api), never edited directly here.
--
-- Deliberately public-readable (RLS lets anon and authenticated alike read
-- active rows): an announcement is by definition something meant to be seen
-- by everyone using the site, signed in or not, same as the sync/tour
-- banners already shown in the sidebar. Only service_role (i.e. only
-- through admin-api, after its own admin checks) can create, flip active,
-- or delete one.
create table if not exists public.announcements (
  id bigint generated always as identity primary key,
  kind text not null check (kind in ('banner', 'popup')),
  message text not null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create index if not exists announcements_active_idx on public.announcements (active);

alter table public.announcements enable row level security;

drop policy if exists "read active announcements" on public.announcements;
create policy "read active announcements" on public.announcements
  for select using (active = true);

grant select on public.announcements to anon, authenticated;
grant select, insert, update, delete on public.announcements to service_role;
