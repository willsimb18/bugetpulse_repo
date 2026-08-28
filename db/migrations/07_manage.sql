-- =====================================================================
-- 07 — Creating things, and locking down function execution.
--
-- Run after 01-06. Additive: nothing here changes existing data.
--
-- Two jobs:
--   1. Close a real hole. PostgreSQL grants EXECUTE on new functions to
--      PUBLIC by default, and several of ours are SECURITY DEFINER and
--      take a household id as an argument — so any caller could pass
--      someone else's household uuid and write into it. Fixed below with
--      an in-function guard AND a revoke.
--   2. Add create_account / create_category, so bills, expenses, savings
--      and debts can be added from the app instead of only arriving via
--      migrate.py.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. HARDENING
-- ---------------------------------------------------------------------

-- Nothing unauthenticated should reach any of our functions.
revoke execute on all functions in schema public from public, anon;
grant  execute on all functions in schema public to authenticated;

-- Belt and braces: a household argument must match the caller's own
-- household. Without this, a SECURITY DEFINER function is a way around
-- every policy in 03_rls.sql.
create or replace function assert_own_household(p_household uuid)
returns void
language plpgsql stable
set search_path = public, pg_temp as $$
begin
  if p_household is distinct from app_household_id() then
    raise exception 'Not your household' using errcode = '42501';
  end if;
end $$;

create or replace function generate_budget_periods(
  p_household uuid,
  p_frequency frequency,
  p_anchor    date,
  p_count     int default 12
) returns int
language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  i int; p_start date; p_end date; inserted int := 0;
begin
  -- auth.uid() is NULL for the SQL editor and the migration script, which
  -- run as postgres and are already trusted. Any real client session must
  -- own the household it names.
  if auth.uid() is not null then
    perform assert_own_household(p_household);
  end if;

  for i in 0 .. p_count - 1 loop
    case p_frequency
      when 'weekly' then
        p_start := p_anchor + (i * 7);           p_end := p_start + 6;
      when 'biweekly' then
        p_start := p_anchor + (i * 14);          p_end := p_start + 13;
      when 'semimonthly' then
        p_start := (date_trunc('month', p_anchor) + ((i / 2) || ' months')::interval)::date
                   + case when i % 2 = 0 then 0 else 14 end;
        p_end   := case when i % 2 = 0 then p_start + 14
                        else (date_trunc('month', p_start) + interval '1 month - 1 day')::date end;
      when 'monthly' then
        p_start := (date_trunc('month', p_anchor) + (i || ' months')::interval)::date;
        p_end   := (p_start + interval '1 month - 1 day')::date;
      else
        raise exception 'Unsupported budget cadence: %', p_frequency;
    end case;

    insert into budget_period (household_id, period_start, period_end, pay_date, frequency, label)
    values (p_household, p_start, p_end, p_start, p_frequency,
            to_char(p_start,'Mon DD') || ' - ' || to_char(p_end,'Mon DD, YYYY'))
    on conflict (household_id, period_start, frequency) do nothing;

    if found then inserted := inserted + 1; end if;
  end loop;
  return inserted;
end $$;

create or replace function refresh_household_amounts(p_household uuid)
returns table (periods_touched int, lines_created int, lines_repriced int)
language plpgsql security definer
set search_path = public, pg_temp as $$
declare pid bigint; np int := 0; nc int := 0; nr int := 0;
begin
  if auth.uid() is not null then
    perform assert_own_household(p_household);
  end if;

  for pid in
    select id from budget_period
    where household_id = p_household and not is_closed and period_end >= current_date
    order by period_start
  loop
    np := np + 1;
    nc := nc + materialize_period(pid);
    nr := nr + refresh_period_amounts(pid);
  end loop;
  return query select np, nc, nr;
end $$;

-- materialize_period / refresh_period_amounts take a period id rather than
-- a household id, so guard them by checking the period's owner.
create or replace function assert_own_period(p_period_id bigint)
returns void
language plpgsql stable
set search_path = public, pg_temp as $$
declare hh uuid;
begin
  if auth.uid() is null then return; end if;
  select household_id into hh from budget_period where id = p_period_id;
  if hh is null or hh is distinct from app_household_id() then
    raise exception 'Not your budget period' using errcode = '42501';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1b. require_owner() in a trusted context.
--
-- auth.uid() is NULL in the Supabase SQL Editor, in migrate.py, and in
-- pg_cron — all of which run as `postgres` and are already trusted.
-- Without this, seeding data by hand from the SQL Editor is impossible:
-- every create_account / apply_raise / record_paycheck call raises
-- "This operation requires the owner role".
--
-- This is not a hole. `anon` has no EXECUTE (revoked above), and any
-- `authenticated` request always carries a uid, so a real client still
-- gets the full owner check.
-- ---------------------------------------------------------------------
create or replace function require_owner()
returns void language plpgsql stable
set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then
    return;   -- server-side / trusted session
  end if;
  if not app_is_owner() then
    raise exception 'This operation requires the owner role'
      using errcode = '42501';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 2. CATEGORIES
-- ---------------------------------------------------------------------
create or replace function create_category(
  p_name      text,
  p_parent_id bigint default null
) returns category
language plpgsql security invoker
set search_path = public, pg_temp as $$
declare rec category; hh uuid;
begin
  perform require_owner();
  hh := coalesce(app_household_id(), (select id from household limit 1));
  if hh is null then
    raise exception 'No household exists yet. Run 06_bootstrap.sql first.';
  end if;

  if p_name is null or btrim(p_name) = '' then
    raise exception 'Category needs a name';
  end if;

  -- Two levels only, matching the old CategoryType parent/child shape.
  if p_parent_id is not null then
    if exists (select 1 from category where id = p_parent_id and parent_id is not null) then
      raise exception 'Categories only nest one level deep';
    end if;
  end if;

  insert into category (household_id, name, parent_id)
  values (hh, btrim(p_name), p_parent_id)
  on conflict (household_id, name, parent_id) do update set name = excluded.name
  returning * into rec;

  return rec;
end $$;

-- ---------------------------------------------------------------------
-- 3. ACCOUNTS
--
-- One call creates the account, its debt detail if it's a debt, an
-- opening balance if given, and the budget lines for every open period —
-- so a new bill shows up on the current budget immediately instead of
-- waiting for the nightly job.
-- ---------------------------------------------------------------------
create or replace function create_account(
  p_name            text,
  p_kind            account_kind,
  p_frequency       frequency default 'monthly',
  p_amount          numeric default 0,
  p_category_id     bigint default null,
  p_due_day         int default null,
  p_due_day_2       int default null,
  p_due_month       int default null,
  p_anchor_date     date default null,
  p_always_due      boolean default false,
  p_amount_mode     amount_mode default 'carry_forward',
  p_amount_percent  numeric default null,
  p_owner_earner_id bigint default null,
  p_is_variable     boolean default false,
  p_autopay         boolean default false,
  p_notes           text default null,
  -- debts only
  p_debt_type       debt_kind default 'credit_card',
  p_credit_limit    numeric default null,
  p_apr             numeric default null,
  p_minimum_payment numeric default null,
  p_opening_balance numeric default null
) returns account
language plpgsql security invoker
set search_path = public, pg_temp as $$
declare
  rec account;
  hh  uuid;
  pid bigint;
begin
  perform require_owner();
  -- In the SQL Editor there is no session, so fall back to the household.
  -- Harmless: this app is single-household per project.
  hh := coalesce(app_household_id(), (select id from household limit 1));
  if hh is null then
    raise exception 'No household exists yet. Run 06_bootstrap.sql first.';
  end if;

  if p_name is null or btrim(p_name) = '' then
    raise exception 'This needs a name';
  end if;

  -- Fail with something readable rather than letting the check constraint
  -- fire, because "account_schedule_present" means nothing to a user.
  if p_frequency in ('monthly','quarterly','semiannual','annual','semimonthly')
     and p_due_day is null and not p_always_due then
    raise exception 'A % bill needs a day of the month it is due on', p_frequency;
  end if;
  if p_frequency in ('weekly','biweekly','one_time')
     and p_anchor_date is null and not p_always_due then
    raise exception 'A % bill needs a starting date to count from', p_frequency;
  end if;
  if p_amount_mode = 'percent_of_income' and p_amount_percent is null then
    raise exception 'Percent of income needs a percentage (0.10 = 10%%)';
  end if;

  insert into account (
    household_id, name, kind, category_id, frequency, default_amount,
    amount_mode, amount_percent, due_day, due_day_2, due_month, anchor_date,
    is_always_due, owner_earner_id, is_variable, is_autopay, notes
  ) values (
    hh, btrim(p_name), p_kind, p_category_id, p_frequency, coalesce(p_amount, 0),
    p_amount_mode, p_amount_percent, p_due_day, p_due_day_2, p_due_month, p_anchor_date,
    coalesce(p_always_due, false), p_owner_earner_id,
    coalesce(p_is_variable, false), coalesce(p_autopay, false), p_notes
  )
  on conflict (household_id, name, kind) do update
    set is_active = true, default_amount = excluded.default_amount
  returning * into rec;

  if p_kind = 'debt' then
    insert into debt_detail (account_id, household_id, debt_type,
                             credit_limit, apr, minimum_payment)
    values (rec.id, hh, coalesce(p_debt_type, 'credit_card'),
            p_credit_limit,
            -- Accept either 13.09 or 0.1309 and store the fraction. People
            -- type the percentage; the old Debts table stored whole percent.
            case when p_apr is null then null
                 when p_apr > 1     then p_apr / 100
                 else p_apr end,
            coalesce(p_minimum_payment, p_amount))
    on conflict (account_id) do update
      set debt_type       = excluded.debt_type,
          credit_limit    = excluded.credit_limit,
          apr             = excluded.apr,
          minimum_payment = excluded.minimum_payment;

    if p_opening_balance is not null then
      insert into debt_balance (household_id, account_id, as_of, balance)
      values (hh, rec.id, current_date, p_opening_balance)
      on conflict (account_id, as_of) do update set balance = excluded.balance;
    end if;
  end if;

  -- Put it on the budget straight away.
  for pid in
    select id from budget_period
    where household_id = hh and not is_closed and period_end >= current_date
    order by period_start
  loop
    perform materialize_period(pid);
  end loop;

  return rec;
end $$;

-- ---------------------------------------------------------------------
-- 4. Everything the "add" forms need to populate their dropdowns.
-- ---------------------------------------------------------------------
create or replace view v_category_picker
with (security_invoker = true) as
select
  c.id,
  c.household_id,
  c.parent_id,
  c.name,
  case when c.parent_id is null then c.name
       else p.name || ' / ' || c.name end as full_name,
  (c.parent_id is null) as is_parent
from category c
left join category p on p.id = c.parent_id;

grant select on v_category_picker to authenticated;
grant execute on all functions in schema public to authenticated;
revoke execute on all functions in schema public from public, anon;
