-- =====================================================================
-- Money moved in: what it is, where it came from, and how to remove it.
--
-- 09_seed_example.sql does NOT create any of this — it only calls
-- record_paycheck, which writes a wage row. So a from_savings or
-- line_of_credit row is one of two things, and they are not the same:
--
--   IMPORTED  — Finance's BudgetIncome had FromSaving / LineOfCredit /
--               Bonus types, and the import brought them across. This is
--               real history. notes begin 'Imported from BudgetIncome'.
--
--   ADDED HERE — someone used Add funds in the app. notes are whatever
--               was typed, or empty.
--
-- Deleting an imported row rewrites how a past period was funded, so the
-- two are worth separating before anything is removed.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Every non-wage income row, newest period first, with its origin.
-- ---------------------------------------------------------------------
select
  p.period_start,
  p.period_end,
  i.id as income_id,
  i.kind,
  i.received_on,
  i.net,
  a.name as source_account,
  coalesce(i.notes, '') as notes,
  case
    when i.notes like 'Imported from BudgetIncome%' then 'imported'
    else 'added in the app'
  end as origin
from income i
join budget_period p on p.id = i.budget_period_id
left join account a  on a.id = i.source_account_id
where not is_wage(i.kind)
order by p.period_start desc, i.id;


-- ---------------------------------------------------------------------
-- 2. Remove specific rows. Put the income_id values from STEP 1 in v_ids.
--
-- Mirrors remove_funds(): a line_of_credit draw grew the debt it came
-- from, so taking it back out has to shrink that balance again. Every
-- other kind is a plain delete. Doing it here rather than calling
-- remove_funds because that function requires a signed-in owner and the
-- SQL Editor has no session.
-- ---------------------------------------------------------------------
do $$
declare
  v_ids  bigint[] := '{}';   -- <-- e.g. '{204}' from STEP 1
  r      record;
  v_n    int := 0;
begin
  if array_length(v_ids, 1) is null then
    raise exception 'Put the income_id values from STEP 1 in v_ids first.';
  end if;

  if exists (select 1 from income where id = any(v_ids) and is_wage(kind)) then
    raise exception 'One of those is a paycheck. Use correct_income() for those.';
  end if;

  for r in select * from income where id = any(v_ids) loop
    if r.kind = 'line_of_credit' and r.source_account_id is not null then
      update debt_balance
         set balance = balance - coalesce(r.gross_override, 0)
       where account_id = r.source_account_id and as_of = r.received_on;
    end if;
    delete from income where id = r.id;
    v_n := v_n + 1;
  end loop;

  raise notice 'Removed % money-moved-in row(s).', v_n;
end $$;


-- Confirm what is left in the affected periods.
select p.period_start, i.kind, i.net, coalesce(i.notes,'') as notes
from income i
join budget_period p on p.id = i.budget_period_id
where not is_wage(i.kind)
order by p.period_start desc, i.id;
