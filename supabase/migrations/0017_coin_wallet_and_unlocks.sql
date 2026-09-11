-- Security fix: Sparky's Closet (coins + expression/colour unlocks) lived entirely inside the
-- client-authoritative study_state.state JSON blob (coins, unlockedExpressions, unlockedColors).
-- RLS on study_state only ever checked "is this your own row" (0001/0002) -- nothing validated
-- what was INSIDE it, so any signed-in user could set state.coins to any number and
-- unlockedExpressions/unlockedColors to every item, unlocking everything for free via devtools or a
-- direct REST call, no purchase required.
--
-- Fix: move coin balance and unlock ownership out of the client-editable blob into their own tables
-- that `authenticated` gets no direct write grant on at all (same trust model as chat_rooms/
-- chat_room_members in 0010) -- the only way to gain coins or an unlock is through the two
-- SECURITY DEFINER functions below, both of which do their own server-side validation:
--   * earn_study_coins(): computes the coin amount itself from COIN_RATE_PER_HOUR (never trusts a
--     client-computed total) and enforces a generous daily cap, so repeatedly calling the RPC with
--     fake minutes can't mint unlimited coins.
--   * unlock_closet_item(): atomic check-balance-then-deduct-then-record against a server-side price
--     catalog (closet_catalog), so an item's cost can't be spoofed and a purchase can't be replayed
--     for the same item twice.
--
-- Existing users' current coins/unlocks (including anyone who used the "Add sample week" demo button,
-- which force-set 500 coins + everything unlocked) are grandfathered in once, below -- there's no way
-- to tell legitimately-earned progress apart from anything already in that JSON blob, and re-locking
-- everyone's Closet retroactively isn't worth the goodwill cost for a purely cosmetic feature. Only
-- the path going forward is hardened.

-- ---------------------------------------------------------------------------
-- Server-side price catalog -- mirrors UNLOCKABLE_EXPRESSIONS / SUBJECT_EXPRESSIONS / COLOR_THEMES in
-- index.html. The client still has its own copy (for rendering labels/art/filters, which have no
-- server-side equivalent), but cost is only ever trusted from here.
-- ---------------------------------------------------------------------------
create table if not exists public.closet_catalog (
  item_id text primary key,
  kind text not null check (kind in ('expression', 'color')),
  cost int not null check (cost > 0)
);

insert into public.closet_catalog (item_id, kind, cost) values
  ('portrait', 'expression', 40), ('reading', 'expression', 30), ('plant', 'expression', 30),
  ('sittingBox', 'expression', 30), ('music', 'expression', 40), ('writingHeadphones', 'expression', 50),
  ('globe', 'expression', 50), ('podium', 'expression', 60), ('blocks', 'expression', 60),
  ('juggling', 'expression', 80),
  ('sub_maths', 'expression', 50), ('sub_english', 'expression', 50), ('sub_irish', 'expression', 50),
  ('sub_french', 'expression', 50), ('sub_german', 'expression', 50), ('sub_spanish', 'expression', 50),
  ('sub_biology', 'expression', 50), ('sub_chemistry', 'expression', 50), ('sub_physics', 'expression', 50),
  ('sub_science', 'expression', 50), ('sub_history', 'expression', 50), ('sub_geography', 'expression', 50),
  ('sub_business', 'expression', 50), ('sub_accounting', 'expression', 50), ('sub_economics', 'expression', 50),
  ('sub_cspe', 'expression', 50), ('sub_classics', 'expression', 50), ('sub_art', 'expression', 50),
  ('sub_music', 'expression', 50), ('sub_drama', 'expression', 50), ('sub_homeec', 'expression', 50),
  ('sub_construction', 'expression', 50), ('sub_engineering', 'expression', 50), ('sub_dcg', 'expression', 50),
  ('sub_computerscience', 'expression', 50),
  ('sunset', 'color', 60), ('berry', 'color', 60), ('forest', 'color', 60), ('grape', 'color', 60),
  ('sunny', 'color', 60)
on conflict (item_id) do update set kind = excluded.kind, cost = excluded.cost;

-- ---------------------------------------------------------------------------
-- Coin balance. No insert/update grant for `authenticated` -- only earn_study_coins() and
-- unlock_closet_item() (both SECURITY DEFINER) ever change it.
-- ---------------------------------------------------------------------------
create table if not exists public.user_wallet (
  user_id uuid primary key references auth.users(id) on delete cascade,
  coins int not null default 0 check (coins >= 0),
  updated_at timestamptz not null default now()
);

-- One row per (user, day) of how many coins earn_study_coins() has already granted that day, so the
-- daily cap below can't be bypassed by calling the RPC many times.
create table if not exists public.coin_earn_log (
  user_id uuid not null references auth.users(id) on delete cascade,
  earn_date date not null default current_date,
  coins_earned int not null default 0,
  primary key (user_id, earn_date)
);

-- Which catalog items each user has actually paid for.
create table if not exists public.user_unlocks (
  user_id uuid not null references auth.users(id) on delete cascade,
  item_id text not null references public.closet_catalog(item_id),
  unlocked_at timestamptz not null default now(),
  primary key (user_id, item_id)
);
create index if not exists user_unlocks_user_id_idx on public.user_unlocks (user_id);

-- ---------------------------------------------------------------------------
-- Grandfather existing client-reported coins/unlocks in once, from whatever's already in
-- study_state.state -- see the header comment above for why.
-- ---------------------------------------------------------------------------
insert into public.user_wallet (user_id, coins)
  select user_id, least(1000000, greatest(0, coalesce((state->>'coins')::int, 0)))
  from public.study_state
  on conflict (user_id) do nothing;

insert into public.user_unlocks (user_id, item_id)
  select ss.user_id, elem.value
  from public.study_state ss, jsonb_array_elements_text(coalesce(ss.state->'unlockedExpressions', '[]'::jsonb)) as elem(value)
  where exists (select 1 from public.closet_catalog c where c.item_id = elem.value)
  on conflict do nothing;

insert into public.user_unlocks (user_id, item_id)
  select ss.user_id, elem.value
  from public.study_state ss, jsonb_array_elements_text(coalesce(ss.state->'unlockedColors', '[]'::jsonb)) as elem(value)
  where exists (select 1 from public.closet_catalog c where c.item_id = elem.value)
  on conflict do nothing;

-- ---------------------------------------------------------------------------
-- earn_study_coins: called once per logged study item/session (see index.html's earnStudyCoins()).
-- p_minutes is still self-reported like every other study-time field in this app (there's no
-- independent verification of actual study time), but the coin AMOUNT is always computed here from
-- COIN_RATE_PER_HOUR, never taken as a client-supplied total, and a generous per-day cap bounds how
-- much a script calling this RPC directly and repeatedly could mint regardless of what minutes it claims.
-- ---------------------------------------------------------------------------
create or replace function public.earn_study_coins(p_minutes numeric)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  -- A single logged item/session is capped at 12 hours -- generous for one real block, but bounds
  -- how much one call can claim regardless of what p_minutes says.
  v_minutes numeric := greatest(0, least(coalesce(p_minutes, 0), 720));
  v_coins int := round(v_minutes / 60 * 10); -- 10 = COIN_RATE_PER_HOUR in index.html, kept in sync by hand
  v_today_earned int;
  -- 300/day is ~30 hours' worth -- far beyond a real day of study, so this is purely an abuse
  -- backstop against repeated fake-minute RPC calls, not a realistic daily ceiling.
  v_daily_cap constant int := 300;
  v_balance int;
begin
  if v_uid is null then raise exception 'Sign in required.'; end if;

  if v_coins > 0 then
    insert into public.coin_earn_log (user_id, earn_date, coins_earned)
      values (v_uid, current_date, 0)
      on conflict (user_id, earn_date) do nothing;

    select coins_earned into v_today_earned from public.coin_earn_log
      where user_id = v_uid and earn_date = current_date;
    v_coins := greatest(0, least(v_coins, v_daily_cap - v_today_earned));

    if v_coins > 0 then
      update public.coin_earn_log set coins_earned = coins_earned + v_coins
        where user_id = v_uid and earn_date = current_date;

      insert into public.user_wallet (user_id, coins, updated_at) values (v_uid, v_coins, now())
        on conflict (user_id) do update set coins = public.user_wallet.coins + v_coins, updated_at = now();
    end if;
  end if;

  select coins into v_balance from public.user_wallet where user_id = v_uid;
  return coalesce(v_balance, 0);
end;
$$;

revoke execute on function public.earn_study_coins(numeric) from public, anon;
grant execute on function public.earn_study_coins(numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- unlock_closet_item: atomic "do I own this already? can I afford it? deduct and record" against the
-- server-side catalog above -- a user can never pay less than closet_catalog.cost, unlock the same
-- item twice, or go into negative coins (user_wallet.coins has a check(coins >= 0) as a backstop too).
-- ---------------------------------------------------------------------------
create or replace function public.unlock_closet_item(p_item_id text)
returns public.user_wallet
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_cost int;
  v_wallet public.user_wallet;
begin
  if v_uid is null then raise exception 'Sign in required.'; end if;

  select cost into v_cost from public.closet_catalog where item_id = p_item_id;
  if v_cost is null then raise exception 'Unknown item.'; end if;

  if exists (select 1 from public.user_unlocks where user_id = v_uid and item_id = p_item_id) then
    raise exception 'Already unlocked.';
  end if;

  update public.user_wallet set coins = coins - v_cost, updated_at = now()
    where user_id = v_uid and coins >= v_cost
    returning * into v_wallet;

  if v_wallet is null then raise exception 'Not enough coins.'; end if;

  insert into public.user_unlocks (user_id, item_id) values (v_uid, p_item_id);

  return v_wallet;
end;
$$;

revoke execute on function public.unlock_closet_item(text) from public, anon;
grant execute on function public.unlock_closet_item(text) to authenticated;

-- ---------------------------------------------------------------------------
-- RLS: everyone can read their own wallet/unlocks (the client re-syncs state.coins/unlockedExpressions/
-- unlockedColors from these after every load and every earn/unlock call), and the catalog is public
-- read since it has no per-user data. No direct insert/update/delete grant to `authenticated` on any
-- of the three tables -- only the two SECURITY DEFINER functions above can change them.
-- ---------------------------------------------------------------------------
alter table public.closet_catalog enable row level security;
alter table public.user_wallet enable row level security;
alter table public.coin_earn_log enable row level security;
alter table public.user_unlocks enable row level security;

drop policy if exists "read catalog" on public.closet_catalog;
create policy "read catalog" on public.closet_catalog for select using (true);

drop policy if exists "read own wallet" on public.user_wallet;
create policy "read own wallet" on public.user_wallet for select using (user_id = auth.uid());

drop policy if exists "read own unlocks" on public.user_unlocks;
create policy "read own unlocks" on public.user_unlocks for select using (user_id = auth.uid());

grant select on public.closet_catalog to authenticated;
grant select on public.user_wallet to authenticated;
grant select on public.user_unlocks to authenticated;
-- coin_earn_log is bookkeeping only, never read by the client.
grant select, insert, update, delete on public.closet_catalog to service_role;
grant select, insert, update, delete on public.user_wallet to service_role;
grant select, insert, update, delete on public.coin_earn_log to service_role;
grant select, insert, update, delete on public.user_unlocks to service_role;
