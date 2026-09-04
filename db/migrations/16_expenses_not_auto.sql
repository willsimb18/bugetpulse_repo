-- =====================================================================
-- 16 — Stop materialising expenses into every period.
--
-- The Finance import brought across 286 expense accounts, nearly all of
-- them per_paycheck, so materialize_period was creating an expense line
-- for every one of them in every period. That is not a budget, it is a
-- catalogue reprinted fortnightly, and it buries the bills that actually
-- have to be paid.
--
-- Expenses are decided period by period -- groceries this fortnight, a
-- car repair the next -- so they are now added deliberately, through the
-- one-off expense form, rather than appearing on their own.
--
-- The exception is is_always_due. That flag is an explicit per-account
-- statement that something belongs in every period, and the Bills tab
-- already exposes it as a checkbox, so it stays the opt-in for an expense
-- that genuinely does recur every time.
--
-- Only future materialisation changes. Expense lines already created stay
-- exactly as they are, paid or not.
-- =====================================================================

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
      -- Expenses are chosen per period, not scheduled. See the header.
      and a.kind <> 'expense'

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
-- Past expense names, for the one-off expense form to suggest from.
--
-- Reads both the catalogue and what has actually been used, because an
-- expense typed in once as a one-off has no account behind it and would
-- otherwise never be offered again.
-- ---------------------------------------------------------------------
create or replace view v_expense_names
with (security_invoker = true) as
select household_id, name, max(last_used) as last_used, sum(times) as times
from (
  select household_id, name, max(due_date) as last_used, count(*) as times
  from budget_line
  where kind = 'expense' and coalesce(btrim(name), '') <> ''
  group by household_id, name

  union all

  select household_id, name, null::date, 0
  from account
  where kind = 'expense' and is_active and coalesce(btrim(name), '') <> ''
) x
group by household_id, name;

grant select on v_expense_names to authenticated;
