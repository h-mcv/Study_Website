-- Per-user metrics for the admin dashboard's Analytics tab, in support of
-- viewing study activity, feature usage, and how they correlate with
-- results. Mirrors the jsonb-extraction approach landing_stats() (see
-- 0003_landing_stats.sql) already uses for study_state.state, but this
-- function returns one row PER USER (with the user_id attached) rather
-- than a single anonymised aggregate -- that's fine here because, unlike
-- landing_stats(), this function is never reachable from the browser: it's
-- SECURITY DEFINER (so it can read across all users like landing_stats
-- does) but EXECUTE is revoked from anon/authenticated below and granted
-- only to service_role, so only the admin-api edge function (which
-- independently re-checks the caller's email + a signed admin token on
-- every request) can ever call it.
--
-- "Study time" here means minutes explicitly logged by Study Mode's
-- focus-timer flow (studySessionLog[].durationMinutes, added alongside
-- this migration -- see the studyModeSaveLog() push in index.html).
-- Sessions logged before that field existed simply have no duration and
-- are excluded from the minutes sum but still count toward session_count,
-- same asymmetry 0003_landing_stats.sql already accepts for the same
-- reason (the app never tracked minutes before now).
create or replace function public.admin_user_metrics()
returns table (user_id uuid, metrics jsonb)
language sql
stable
security definer
set search_path = public
as $$
with
sessions as (
  select ss.user_id,
         (log_item->>'date')::date as session_date,
         nullif(log_item->>'durationMinutes','')::numeric as duration_minutes
  from public.study_state ss,
       jsonb_array_elements(ss.state->'studySessionLog') as log_item
  where (log_item->>'date') ~ '^\d{4}-\d{2}-\d{2}$'
),
session_agg as (
  select user_id,
         count(*) as session_count,
         count(*) filter (where session_date >= current_date - 30) as session_count_last30,
         coalesce(sum(duration_minutes), 0) as total_minutes,
         coalesce(sum(duration_minutes) filter (where session_date >= current_date - 30), 0) as minutes_last30,
         min(session_date) as first_session_date,
         max(session_date) as last_session_date
  from sessions
  group by user_id
),
percent_results as (
  select ss.user_id, (exam->>'end')::date as result_date,
         (sitting->'result'->>'percent')::numeric as pct
  from public.study_state ss,
       jsonb_array_elements(ss.state->'exams') as exam,
       jsonb_array_elements(exam->'sittings') as sitting
  where exam->>'end' ~ '^\d{4}-\d{2}-\d{2}$'
    and sitting->'result'->>'percent' ~ '^-?\d+(\.\d+)?$'
  union all
  select ss.user_id,
         coalesce(nullif(paper->'result'->>'recordedDate',''), (paper->>'year') || '-06-30')::date as result_date,
         (paper->'result'->>'percent')::numeric as pct
  from public.study_state ss,
       jsonb_array_elements(ss.state->'pastPapers') as paper
  where paper->'result'->>'percent' ~ '^-?\d+(\.\d+)?$'
    and coalesce(nullif(paper->'result'->>'recordedDate',''), (paper->>'year') || '-06-30') ~ '^\d{4}-\d{2}-\d{2}$'
),
result_agg as (
  select user_id,
         count(*) as result_count,
         avg(pct) as avg_result_pct,
         max(result_date) as last_result_date
  from percent_results
  group by user_id
),
counts as (
  select ss.user_id,
         jsonb_array_length(coalesce(ss.state->'subjects', '[]'::jsonb)) as subject_count,
         jsonb_array_length(coalesce(ss.state->'tasks', '[]'::jsonb)) as task_count,
         jsonb_array_length(coalesce(ss.state->'exams', '[]'::jsonb)) as exam_count,
         ss.updated_at as state_updated_at
  from public.study_state ss
),
events as (
  select user_id,
         jsonb_object_agg(event, cnt) as event_counts,
         sum(cnt) as event_total,
         max(last_at) as last_event_at
  from (
    select user_id, event, count(*) as cnt, max(created_at) as last_at
    from public.feature_events
    group by user_id, event
  ) per_event
  group by user_id
),
all_users as (
  select user_id from counts
  union select user_id from session_agg
  union select user_id from result_agg
  union select user_id from events
)
select
  u.user_id,
  jsonb_build_object(
    'sessionCount', coalesce(sa.session_count, 0),
    'sessionCountLast30', coalesce(sa.session_count_last30, 0),
    'totalMinutes', coalesce(sa.total_minutes, 0),
    'minutesLast30', coalesce(sa.minutes_last30, 0),
    'firstSessionDate', sa.first_session_date,
    'lastSessionDate', sa.last_session_date,
    'resultCount', coalesce(ra.result_count, 0),
    'avgResultPct', ra.avg_result_pct,
    'lastResultDate', ra.last_result_date,
    'subjectCount', coalesce(c.subject_count, 0),
    'taskCount', coalesce(c.task_count, 0),
    'examCount', coalesce(c.exam_count, 0),
    'stateUpdatedAt', c.state_updated_at,
    'eventCounts', coalesce(ev.event_counts, '{}'::jsonb),
    'eventTotal', coalesce(ev.event_total, 0),
    'lastEventAt', ev.last_event_at
  ) as metrics
from all_users u
left join session_agg sa on sa.user_id = u.user_id
left join result_agg ra on ra.user_id = u.user_id
left join counts c on c.user_id = u.user_id
left join events ev on ev.user_id = u.user_id;
$$;

revoke execute on function public.admin_user_metrics() from public, anon, authenticated;
grant execute on function public.admin_user_metrics() to service_role;
