-- The ai-chat edge function (see its own header comment) had a per-request size cap but no per-user
-- rate limit at all -- any signed-in account could fire unlimited requests and burn through the
-- shared Gemini/Groq/OpenRouter quota (or run up API cost) for everyone. This adds a per-user daily
-- counter the edge function checks (via its service-role client, which bypasses RLS -- see the empty
-- grants below) before calling any provider.
--
-- No table here is ever touched by `authenticated` directly -- only the edge function's service-role
-- client reads/writes it -- so a client can't reset or inflate its own counter by calling anything itself.

create table if not exists public.ai_usage_daily (
  user_id uuid not null references auth.users(id) on delete cascade,
  usage_date date not null default current_date,
  request_count int not null default 0,
  primary key (user_id, usage_date)
);

alter table public.ai_usage_daily enable row level security;
-- No policies and no grants for authenticated/anon at all: only service_role (which bypasses RLS)
-- ever touches this table, exactly like admin_user_metrics in 0008.
grant select, insert, update, delete on public.ai_usage_daily to service_role;

-- Atomic increment-and-return-new-count, so two concurrent requests from the same user can't both
-- read the same pre-increment count and both slip under the cap.
create or replace function public.increment_ai_usage(p_user_id uuid)
returns int
language sql
as $$
  insert into public.ai_usage_daily (user_id, usage_date, request_count)
    values (p_user_id, current_date, 1)
    on conflict (user_id, usage_date) do update set request_count = ai_usage_daily.request_count + 1
    returning request_count;
$$;

revoke execute on function public.increment_ai_usage(uuid) from public, anon, authenticated;
grant execute on function public.increment_ai_usage(uuid) to service_role;
