-- Per-user saved answers for the interactive past-exam-paper viewer (Past Papers feature).
-- Keyed by exam_file (the relative path from EXAM_PAPER_INDEX, e.g.
-- "lc/maths/2026/paper-paper-one-higher-level-ev.pdf") rather than a generated id, so a
-- client can upsert straight from that path without an extra round trip to look up a row id.
--
-- Kept as its own table rather than folded into study_state.state (see 0001_study_state.sql):
-- a paper's answers (text boxes, checkboxes, freehand ink strokes) can get sizeable, and
-- study_state is round-tripped in full on every save elsewhere in the app -- bundling exam
-- answers into that blob would make every unrelated save slower as papers accumulate.
create table if not exists public.exam_paper_answers (
  user_id uuid not null references auth.users(id) on delete cascade,
  exam_file text not null,
  answers jsonb not null,
  updated_at timestamptz not null default now(),
  primary key (user_id, exam_file)
);

alter table public.exam_paper_answers enable row level security;

create policy "select own exam answers" on public.exam_paper_answers
  for select using (auth.uid() = user_id);

create policy "insert own exam answers" on public.exam_paper_answers
  for insert with check (auth.uid() = user_id);

create policy "update own exam answers" on public.exam_paper_answers
  for update using (auth.uid() = user_id);

create policy "delete own exam answers" on public.exam_paper_answers
  for delete using (auth.uid() = user_id);

-- RLS policies don't imply the base table grant -- this bit study_state twice already
-- (see 0002_grant_study_state_privileges.sql / 0006_grant_study_state_service_role.sql).
grant select, insert, update, delete on public.exam_paper_answers to authenticated;
