-- =====================================================================
-- Functions & triggers — v2
-- =====================================================================

create or replace function app_household_id()
returns uuid language sql stable security definer
set search_path = public, pg_temp as $$
  select household_id from profile where id = auth.uid();
$$;

create or replace function app_role()
returns household_role language sql stable security definer
set search_path = public, pg_temp as $$
  select role from profile where id = auth.uid();
$$;

create or replace function app_is_owner()
returns boolean language sql stable as $$
  select coalesce(app_role() = 'owner', false);
$$;

-- Wages vs. money moved in from elsewhere. Keeps v_period_summary honest
-- about how much of a period your pay actually covered.
create or replace function is_wage(k income_kind) returns boolean
language sql immutable as $$
  select k in ('regular','overtime','pto','holiday','commission')
$$;

create or replace function touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

create trigger t_income_touch      before update on income
  for each row execute function touch_updated_at();
create trigger t_account_touch     before update on account
  for each row execute function touch_updated_at();
create trigger t_budget_line_touch before update on budget_line
  for each row execute function touch_updated_at();

-- ---------------------------------------------------------------------
-- safe_day() — day-of-month clamped to the month's real length.
--
-- vw_BI_WeeklyBudget builds dates by string concatenation
--   CAST(month AS CHAR(2)) + '/' + CAST(DayDueOn AS CHAR(2)) + '/' + year
-- and when ISDATE() rejects the result it retries with DayDueOn - 1.
-- For a bill due on the 31st in February that yields '2/30/2026', which
-- is still invalid — the CAST throws. Clamping is the correct fix.
-- ---------------------------------------------------------------------
create or replace function safe_day(p_month_start date, p_day int)
returns date language sql immutable as $$
  select p_month_start + (least(
           p_day,
           extract(day from (date_trunc('month', p_month_start)
                             + interval '1 month - 1 day'))::int
         ) - 1);
$$;

-- ---------------------------------------------------------------------
-- occurrences_in_window()
-- Every date an account falls due inside a window. Zero, one, or many.
-- ---------------------------------------------------------------------
create or replace function occurrences_in_window(
  p_freq      frequency,
  p_due_day   int,
  p_due_day_2 int,
  p_due_month int,
  p_anchor    date,
  p_win_start date,
  p_win_end   date,
  p_pay_date  date default null
) returns setof date
language plpgsql immutable as $$
declare
  d           date;
  step_days   int;
  step_months int;
  m           date;
begin
  if p_win_end < p_win_start then return; end if;

  case p_freq

    -- Expenses: one occurrence per pay period, on the pay date.
    -- This is the Expenses/'N/A' frequency cadence from Finance.
    when 'per_paycheck' then
      return next coalesce(p_pay_date, p_win_start);

    when 'weekly', 'biweekly' then
      step_days := case p_freq when 'weekly' then 7 else 14 end;
      if p_anchor is null then return; end if;
      if p_anchor >= p_win_start then
        d := p_anchor;
      else
        d := p_anchor + (ceil((p_win_start - p_anchor)::numeric / step_days)::int * step_days);
      end if;
      while d <= p_win_end loop
        return next d;
        d := d + step_days;
      end loop;

    when 'semimonthly' then
      m := date_trunc('month', p_win_start)::date;
      while m <= p_win_end loop
        foreach d in array array[
          safe_day(m, coalesce(p_due_day, 1)),
          safe_day(m, coalesce(p_due_day_2, 15))
        ] loop
          if d between p_win_start and p_win_end then return next d; end if;
        end loop;
        m := (m + interval '1 month')::date;
      end loop;

    when 'monthly' then
      m := date_trunc('month', p_win_start)::date;
      while m <= p_win_end loop
        d := safe_day(m, coalesce(p_due_day, 1));
        if d between p_win_start and p_win_end then return next d; end if;
        m := (m + interval '1 month')::date;
      end loop;

    when 'annual' then
      -- Uses due_month + due_day (Finance: MonthDue + DayDueOn).
      for m in
        select generate_series(
                 date_trunc('year', p_win_start),
                 date_trunc('year', p_win_end),
                 interval '1 year')::date
      loop
        d := safe_day(
               (m + ((coalesce(p_due_month,1) - 1) || ' months')::interval)::date,
               coalesce(p_due_day, 1));
        if d between p_win_start and p_win_end then return next d; end if;
      end loop;

    when 'quarterly', 'semiannual' then
      step_months := case p_freq when 'quarterly' then 3 else 6 end;
      if p_anchor is null then return; end if;
      d := p_anchor;
      while d < p_win_start loop
        d := (d + (step_months || ' months')::interval)::date;
      end loop;
      while d <= p_win_end loop
        return next d;
        d := (d + (step_months || ' months')::interval)::date;
      end loop;

    when 'one_time' then
      if p_anchor between p_win_start and p_win_end then
        return next p_anchor;
      end if;

  end case;
  return;
end $$;

-- ---------------------------------------------------------------------
-- next_amount_for() — what should this line be budgeted at?
--
-- Mirrors the Excel rule
--   IF(isDue=1, IF(LastPaidAmount > 0, LastPaidAmount, BudgetAmount), 0)
--
-- Resolution order for carry_forward:
--   1. the last line's paid amount, if it was paid
--   2. else the last line's budgeted amount (so a deliberate edit to an
--      open line propagates forward even before it's paid)
--   3. else default_amount, when there is no history at all
--
-- A rate change therefore lands via update_account_amount(), which
-- writes the new figure onto open unpaid lines; the next period then
-- carries that. Do NOT try to make the catalog outrank history by date —
-- an earlier attempt compared the line's due_date to a catalog-change
-- date, which silently breaks for any history imported from the old
-- system, since all of it predates the account row.
-- ---------------------------------------------------------------------
create or replace function next_amount_for(
  p_account_id bigint,
  p_due_date   date,
  p_period_id  bigint default null
) returns numeric
language plpgsql stable
set search_path = public, pg_temp as $$
declare
  a        account;
  last_amt numeric(12,2);
  inc      numeric(12,2);
begin
  select * into a from account where id = p_account_id;
  if not found then return 0; end if;

  if a.amount_mode = 'fixed' then
    return a.default_amount;
  end if;

  if a.amount_mode = 'percent_of_income' then
    select coalesce(sum(net), 0) into inc
    from income where budget_period_id = p_period_id;
    return round(inc * coalesce(a.amount_percent, 0), 2);
  end if;

  -- carry_forward: the amount that actually settled last time. A line
  -- that was paid carries its paid amount; one that was only budgeted
  -- carries what it was budgeted at.
  select coalesce(nullif(l.amount_paid, 0), l.amount_due)
    into last_amt
  from budget_line l
  where l.account_id = p_account_id
    and l.due_date < p_due_date
  order by l.due_date desc, l.id desc
  limit 1;

  if last_amt is null then
    return a.default_amount;
  end if;

  return last_amt;
end $$;

-- ---------------------------------------------------------------------
-- generate_budget_periods() — idempotent pay calendar
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- materialize_period()
-- Expands active accounts into budget_line rows. Idempotent: a line your
-- wife already paid is never touched by a re-run.
--
-- Expense lines are seeded at account.default_amount, then overridden
-- per period via set_line_amount().
-- ---------------------------------------------------------------------
create or replace function materialize_period(p_period_id bigint)
returns int
language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  per     budget_period;
  created int := 0;
begin
  select * into per from budget_period where id = p_period_id;
  if not found then raise exception 'budget_period % not found', p_period_id; end if;
  if per.is_closed then raise exception 'budget_period % is closed', p_period_id; end if;

  with occ as (
    select a.id as account_id, a.household_id, a.name, a.category_id,
           a.kind, d.due_date
    from account a
    cross join lateral occurrences_in_window(
      a.frequency, a.due_day, a.due_day_2, a.due_month, a.anchor_date,
      per.period_start, per.period_end, per.pay_date
    ) as d(due_date)
    where a.household_id = per.household_id
      and a.is_active
      -- is_always_due accounts are handled by the branch below. Without
      -- this exclusion a monthly always-due account (e.g. Mortgage)
      -- materializes twice in a period: once on its due day, once on the
      -- pay date.
      and not a.is_always_due

    union all

    -- is_always_due: exactly one line per period, on the pay date,
    -- regardless of the account's own schedule. Replaces the hardcoded
    -- name list in CTE_AlwaysDueList.
    select a.id, a.household_id, a.name, a.category_id,
           a.kind, per.pay_date
    from account a
    where a.household_id = per.household_id
      and a.is_active
      and a.is_always_due
  )
  insert into budget_line (
    household_id, budget_period_id, account_id, name,
    category_id, kind, due_date, amount_due, status
  )
  select distinct on (occ.account_id, occ.due_date)
         occ.household_id, per.id, occ.account_id, occ.name,
         occ.category_id, occ.kind, occ.due_date,
         next_amount_for(occ.account_id, occ.due_date, per.id), 'scheduled'
  from occ
  on conflict (budget_period_id, account_id, due_date)
    where account_id is not null
    do nothing;

  get diagnostics created = row_count;
  return created;
end $$;

-- ---------------------------------------------------------------------
-- refresh_period_amounts() — recompute amount_due for UNPAID lines.
--
-- Needed because a percent_of_income line (tithes) can't be computed
-- until the period's paychecks are entered, and a carry_forward line
-- should pick up a correction made to the previous period. Never touches
-- a paid or partial line, and never touches a manual override on a
-- closed period.
-- ---------------------------------------------------------------------
create or replace function refresh_period_amounts(p_period_id bigint)
returns int
language plpgsql security definer
set search_path = public, pg_temp as $$
declare per budget_period; n int := 0;
begin
  select * into per from budget_period where id = p_period_id;
  if not found then raise exception 'budget_period % not found', p_period_id; end if;
  if per.is_closed then return 0; end if;

  update budget_line l
     set amount_due = next_amount_for(l.account_id, l.due_date, per.id)
   where l.budget_period_id = per.id
     and l.account_id is not null
     and l.status = 'scheduled'
     and l.amount_paid = 0
     and not l.amount_overridden          -- never clobber a hand-typed figure
     and l.amount_due is distinct from next_amount_for(l.account_id, l.due_date, per.id);

  get diagnostics n = row_count;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- refresh_household_amounts() — nightly cron entry point.
-- Materializes any open future period, then recomputes amounts on unpaid
-- lines so percent_of_income and carry_forward values stay current
-- without anyone having to touch a SQL console.
-- ---------------------------------------------------------------------
create or replace function refresh_household_amounts(p_household uuid)
returns table (periods_touched int, lines_created int, lines_repriced int)
language plpgsql security definer
set search_path = public, pg_temp as $$
declare pid bigint; np int := 0; nc int := 0; nr int := 0;
begin
  for pid in
    select id from budget_period
    where household_id = p_household
      and not is_closed
      and period_end >= current_date
    order by period_start
  loop
    np := np + 1;
    nc := nc + materialize_period(pid);
    nr := nr + refresh_period_amounts(pid);
  end loop;
  return query select np, nc, nr;
end $$;

-- ---------------------------------------------------------------------
-- set_line_amount() — THE primary edit path.
--
-- This is the equivalent of typing a new number into the Budget tab.
-- The BUDGET LINE is the source of truth for what a bill costs in a
-- given period; account.default_amount is only the seed used the very
-- first time an account is materialized, before any history exists.
--
-- Replaces sp_AddNewExpenses, which took a NVARCHAR(MAX) of SQL pasted
-- out of Excel and ran it through EXEC(). Parameterized, no dynamic SQL.
--
-- p_cascade (default true) pushes the new figure onto later UNPAID lines
-- for the same account. In Excel this problem doesn't exist, because
-- only the current period is ever on screen. Here periods are
-- materialized ahead so you can see due dates coming, which means an
-- edit made today has to reach the rows that were already created.
--
-- p_remember additionally writes back to the catalog seed. Off by
-- default — normal practice is to edit the line and leave the catalog
-- alone.
-- ---------------------------------------------------------------------
create or replace function set_line_amount(
  p_line_id  bigint,
  p_amount   numeric,
  p_remember boolean default false,
  p_cascade  boolean default true
) returns budget_line
language plpgsql security invoker
set search_path = public, pg_temp as $$
declare ln budget_line; cascaded int := 0;
begin
  if not app_is_owner() then
    raise exception 'Only an owner may change a budgeted amount'
      using errcode = '42501';
  end if;
  if p_amount < 0 then
    raise exception 'Amount cannot be negative';
  end if;

  update budget_line
     set amount_due = p_amount,
         amount_overridden = true,
         status = (case
                    when amount_paid <= 0        then 'scheduled'
                    when amount_paid >= p_amount then 'paid'
                    else 'partial'
                  end)::line_status
   where id = p_line_id
   returning * into ln;

  if not found then
    raise exception 'budget_line % not found or not visible', p_line_id;
  end if;

  -- Push forward onto later unpaid lines so the change sticks for the
  -- periods already on screen. Paid and partial lines are never touched,
  -- and closed periods are skipped.
  if p_cascade and ln.account_id is not null then
    update budget_line l
       set amount_due = p_amount,
           amount_overridden = true
      from budget_period p
     where l.budget_period_id = p.id
       and l.account_id = ln.account_id
       and l.id <> ln.id
       and l.due_date > ln.due_date
       and l.status = 'scheduled'
       and l.amount_paid = 0
       and not p.is_closed;
    get diagnostics cascaded = row_count;
  end if;

  if p_remember and ln.account_id is not null then
    update account
       set default_amount = p_amount,
           amount_set_on  = current_date
     where id = ln.account_id;
  end if;

  return ln;
end $$;

-- ---------------------------------------------------------------------
-- reset_line_amount() — undo an override and let the line be repriced
-- automatically again (carry-forward or percent-of-income).
-- ---------------------------------------------------------------------
create or replace function reset_line_amount(p_line_id bigint)
returns budget_line
language plpgsql security invoker
set search_path = public, pg_temp as $$
declare ln budget_line;
begin
  if not app_is_owner() then
    raise exception 'Only an owner may reset a budgeted amount'
      using errcode = '42501';
  end if;

  update budget_line l
     set amount_overridden = false,
         amount_due = next_amount_for(l.account_id, l.due_date, l.budget_period_id)
   where l.id = p_line_id
     and l.account_id is not null
   returning * into ln;

  if not found then
    raise exception 'budget_line % not found, not visible, or has no account', p_line_id;
  end if;
  return ln;
end $$;

-- Add a one-off expense that has no catalog entry.
create or replace function add_adhoc_line(
  p_period_id   bigint,
  p_name        text,
  p_amount      numeric,
  p_category_id bigint default null,
  p_kind        account_kind default 'expense',
  p_due_date    date default null
) returns budget_line
language plpgsql security invoker
set search_path = public, pg_temp as $$
declare per budget_period; ln budget_line;
begin
  if not app_is_owner() then
    raise exception 'Only an owner may add a budget line' using errcode = '42501';
  end if;
  select * into per from budget_period where id = p_period_id;
  if not found then raise exception 'budget_period % not visible', p_period_id; end if;

  insert into budget_line (
    household_id, budget_period_id, account_id, name, category_id,
    kind, due_date, amount_due, is_manual
  ) values (
    per.household_id, per.id, null, p_name, p_category_id,
    p_kind, coalesce(p_due_date, per.pay_date), p_amount, true
  ) returning * into ln;

  return ln;
end $$;

-- ---------------------------------------------------------------------
-- mark_paid() / mark_unpaid()
-- ---------------------------------------------------------------------
create or replace function mark_paid(
  p_line_id bigint,
  p_amount  numeric default null,
  p_paid_on date default null
) returns budget_line
language plpgsql security invoker
set search_path = public, pg_temp as $$
declare ln budget_line; amt numeric(12,2);
begin
  select * into ln from budget_line where id = p_line_id;
  if not found then
    raise exception 'budget_line % not found or not visible', p_line_id;
  end if;

  amt := coalesce(p_amount, ln.amount_due);

  update budget_line
     set amount_paid = amt,
         paid_on     = coalesce(p_paid_on, current_date),
         paid_by     = auth.uid(),
         status      = (case
                          when amt <= 0             then 'scheduled'
                          when amt >= ln.amount_due then 'paid'
                          else 'partial'
                        end)::line_status
   where id = p_line_id
   returning * into ln;

  return ln;
end $$;

create or replace function mark_unpaid(p_line_id bigint)
returns budget_line language sql security invoker
set search_path = public, pg_temp as $$
  update budget_line
     set amount_paid = 0, paid_on = null, paid_by = null, status = 'scheduled'
   where id = p_line_id
   returning *;
$$;

-- ---------------------------------------------------------------------
-- Member write scope.
-- RLS has no access to the pre-update row and Supabase runs both spouses
-- as the same `authenticated` role, so column-level GRANT can't help
-- either. A BEFORE UPDATE trigger is the only place this can live.
-- ---------------------------------------------------------------------
create or replace function enforce_member_write_scope()
returns trigger language plpgsql as $$
begin
  -- auth.uid() is NULL for system contexts: bulk migration, pg_cron, and
  -- referential actions such as the ON DELETE SET NULL cascade from
  -- account. Those are already gated by RLS and table grants — an
  -- unauthenticated client matches no rows at all, because every policy
  -- keys off app_household_id(), which is NULL without a session.
  if auth.uid() is null or app_is_owner() then return new; end if;

  if (new.household_id, new.budget_period_id, new.account_id, new.name,
      new.category_id, new.kind, new.due_date, new.amount_due,
      new.is_manual, new.funds_held, new.funds_held_amount)
     is distinct from
     (old.household_id, old.budget_period_id, old.account_id, old.name,
      old.category_id, old.kind, old.due_date, old.amount_due,
      old.is_manual, old.funds_held, old.funds_held_amount)
  then
    raise exception
      'Members may only update payment fields (amount_paid, status, paid_on, notes)'
      using errcode = '42501';
  end if;

  return new;
end $$;

create trigger t_budget_line_member_scope
  before update on budget_line
  for each row execute function enforce_member_write_scope();

-- ---------------------------------------------------------------------
-- Audit
-- ---------------------------------------------------------------------
create or replace function write_audit()
returns trigger language plpgsql security definer
set search_path = public, pg_temp as $$
declare rec record;
begin
  rec := coalesce(new, old);
  insert into audit_log (household_id, actor, table_name, row_id, action, old_row, new_row)
  values (
    (to_jsonb(rec) ->> 'household_id')::uuid,
    auth.uid(), tg_table_name, to_jsonb(rec) ->> 'id', tg_op,
    case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end,
    case when tg_op in ('UPDATE','INSERT') then to_jsonb(new) end
  );
  return null;
end $$;

create trigger t_budget_line_audit after insert or update or delete on budget_line
  for each row execute function write_audit();
create trigger t_account_audit     after insert or update or delete on account
  for each row execute function write_audit();
create trigger t_income_audit      after insert or update or delete on income
  for each row execute function write_audit();
create trigger t_debt_balance_audit after insert or update or delete on debt_balance
  for each row execute function write_audit();
