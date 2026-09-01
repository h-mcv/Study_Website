-- Aggregate, privacy-safe statistics for the public landing page, computed
-- entirely server-side and gated on a minimum sample size so early results
-- (which could otherwise be noisy or identify individuals) are never shown.
-- SECURITY DEFINER so it can read across all users' rows to aggregate them,
-- bypassing per-row RLS -- but it must NEVER return a raw row, id, email, or
-- per-user value. Only fully pre-aggregated numbers, gated on the threshold
-- below, ever leave this function. Adjust min_qualifying_users to taste.
create or replace function public.landing_stats()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
with
constants as (
  select 25 as min_qualifying_users
),

-- ---- Metric A: self-study regularity -------------------------------------
-- One row per logged self-study session (excludes supervised sessions),
-- tagged with the number of whole weeks since that user's own first logged
-- self-study session, so every user is compared against their own starting
-- point rather than a shared calendar date (study_state has no created_at
-- column, and "since first real use" is arguably the more honest anchor).
self_sessions as (
  select ss.user_id, (log_item->>'date')::date as session_date
  from public.study_state ss,
       jsonb_array_elements(ss.state->'studySessionLog') as log_item
  where (log_item->>'isSupervised') is distinct from 'true'
    and (log_item->>'date') ~ '^\d{4}-\d{2}-\d{2}$'
),
self_sessions_indexed as (
  select user_id, session_date,
         (session_date - min(session_date) over (partition by user_id)) / 7 as week_index
  from self_sessions
),
regularity_by_user as (
  select user_id,
         count(*) filter (where week_index between 0 and 1) / 2.0 as early_per_week,
         count(*) filter (where week_index between 4 and 7) / 4.0 as later_per_week
  from self_sessions_indexed
  group by user_id
  having max(week_index) >= 7 -- needs 8 weeks of history to compare early vs later
),
regularity_agg as (
  select
    count(*) as n_users,
    avg((later_per_week > early_per_week)::int)::numeric * 100 as pct_improved,
    avg(case when early_per_week > 0
        then (later_per_week - early_per_week) / early_per_week * 100 end) as avg_increase_pct
  from regularity_by_user
),

-- ---- Metric B: numeric-percent result trend ------------------------------
-- Only results recorded as a direct numeric percent are used -- skips the
-- LC-band/JC-grade/letter estimate conversions (those tables live client-
-- side only; not worth duplicating and risking drift for a marketing stat).
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
percent_ranked as (
  select user_id, result_date, pct,
         row_number() over (partition by user_id order by result_date) as rn,
         count(*) over (partition by user_id) as n
  from percent_results
),
percent_by_user as (
  select
    user_id,
    avg(pct) filter (where rn <= ceil(n / 2.0)) as first_half_avg,
    avg(pct) filter (where rn > ceil(n / 2.0)) as second_half_avg,
    max(result_date) - min(result_date) as span_days
  from percent_ranked
  group by user_id, n
  having n >= 4 and max(result_date) - min(result_date) >= 60
),
marks_agg as (
  select
    count(*) as n_users,
    avg((second_half_avg > first_half_avg)::int)::numeric * 100 as pct_improved,
    avg(second_half_avg - first_half_avg) as avg_points_gained
  from percent_by_user
)

select case
  when (select n_users from regularity_agg) < (select min_qualifying_users from constants)
   and (select n_users from marks_agg) < (select min_qualifying_users from constants)
  then jsonb_build_object('sufficientData', false)
  else jsonb_build_object(
    'sufficientData', true,
    'generatedAt', now(),
    'regularity', case when (select n_users from regularity_agg) >= (select min_qualifying_users from constants)
      then jsonb_build_object(
        'usersAnalyzed', (select n_users from regularity_agg),
        'pctUsersImproved', round((select pct_improved from regularity_agg), 1),
        'avgIncreasePct', round((select avg_increase_pct from regularity_agg), 1))
      else null end,
    'marks', case when (select n_users from marks_agg) >= (select min_qualifying_users from constants)
      then jsonb_build_object(
        'usersAnalyzed', (select n_users from marks_agg),
        'pctUsersImproved', round((select pct_improved from marks_agg), 1),
        'avgPointsGained', round((select avg_points_gained from marks_agg), 1))
      else null end
  )
end;
$$;

revoke all on function public.landing_stats() from public;
grant execute on function public.landing_stats() to anon, authenticated;
