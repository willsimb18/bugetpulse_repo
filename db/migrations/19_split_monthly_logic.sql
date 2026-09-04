-- =====================================================================
-- 19 — Make 'split_monthly' work.
--
-- An account in this mode carries a MONTHLY figure in default_amount and
-- is budgeted across the paychecks that fall in that month, the way the
-- mortgage worked in the spreadsheet.
--
-- Two changes:
--
--   materialize_period gives it one line per period, on the pay date,
--   instead of a single line on its monthly due day.
--
--   next_amount_for divides what is still owed for the month by the
--   number of pay dates left in it. So a 4,491.90 mortgage over two
--   paychecks asks for 2,245.95, and if the first is paid at 2,290.82 the
--   second asks for 2,201.08 -- the month lands on its figure exactly,
--   whatever was actually paid earlier. Once the month is covered the
--   remaining ask is zero rather than negative.
--
-- Set it per account with:
--   select set_amount_mode(<account_id>, 'split_monthly');
-- and put the MONTH's amount in default_amount, not the per-paycheck one.
-- =====================================================================

create or replace function next_amount_for(
  p_account_id bigint,
  p_due_date   date,
  p_period_id  bigint default null
) returns numeric
language plpgsql stable
set search_path = public, pg_temp as $$
declare
  a          account;
  last_amt   numeric(12,2);
  inc        numeric(12,2);
  m_start    date;
  paid_so_far numeric(12,2);
  left_count int;
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

  if a.amount_mode = 'split_monthly' then
    m_start := date_trunc('month', p_due_date)::date;

    -- What this account has already taken from the month, on any earlier
    -- line. Paid figures win over budgeted ones, so an overpayment early
    -- correctly reduces what is asked for later.
    select coalesce(sum(coalesce(nullif(l.amount_paid, 0), l.amount_due)), 0)
      into paid_so_far
    from budget_line l
    where l.account_id = p_account_id
      and l.due_date >= m_start
      and l.due_date < (m_start + interval '1 month')::date
      and l.due_date < p_due_date;

    -- Pay dates still to come in the month, this one included.
    select count(*) into left_count
    from budget_period p
    where p.household_id = a.household_id
      and p.pay_date >= p_due_date
      and p.pay_date >= m_start
      and p.pay_date < (m_start + interval '1 month')::date;

    if left_count < 1 then left_count := 1; end if;

    return greatest(round((a.default_amount - paid_so_far) / left_count, 2), 0);
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
      -- Expenses are chosen per period, not scheduled (migration 16).
      and a.kind <> 'expense'
      -- split_monthly has its own branch: it appears every period, not
      -- on the monthly due day its schedule would give it.
      and a.amount_mode <> 'split_monthly'

    union all

    -- is_always_due: exactly one line per period, on the pay date,
    -- regardless of the account's own schedule. Replaces the hardcoded
    -- name list in CTE_AlwaysDueList. An expense reaches a period only
    -- through this branch now, and only because someone ticked the box.
    select a.id, a.household_id, a.name, a.category_id,
           a.kind, per.pay_date
    from account a
    where a.household_id = per.household_id
      and a.is_active
      and a.is_always_due
      and a.amount_mode <> 'split_monthly'

    union all

    -- split_monthly: one line per period, on the pay date, carrying that
    -- paycheck's share of the month. next_amount_for works out the share.
    select a.id, a.household_id, a.name, a.category_id,
           a.kind, per.pay_date
    from account a
    where a.household_id = per.household_id
      and a.is_active
      and a.amount_mode = 'split_monthly'
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


comment on type amount_mode is
  'carry_forward = repeat what last settled; fixed = always the set amount; '
  'percent_of_income = a share of the period''s net; '
  'split_monthly = default_amount is a MONTHLY figure, spread across the '
  'pay dates in each month and self-correcting for what was already paid.';
