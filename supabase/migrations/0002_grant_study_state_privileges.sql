-- RLS policies only filter rows a role is already allowed to touch — they
-- don't grant the underlying table privilege. The first migration enabled
-- RLS and added policies but never granted anon/authenticated the base
-- SELECT/INSERT/UPDATE on the table, so every request was rejected before
-- the policies even ran (PostgREST error 42501: "permission denied for
-- table study_state"), and the app silently fell back to guest mode.
grant select, insert, update on public.study_state to authenticated;
