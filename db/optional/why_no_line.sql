-- =====================================================================
-- Why is this bill not on the budget?
--
-- A line reaches a period only if materialize_period puts it there, and
-- it can decline for five different reasons. This asks each one in turn
-- for every active account, against the period containing today.
--
--   inactive          is_active = false. Finance's isActive = 0.
--   expense           migration 16 stopped materialising kind='expense'
--                     every period, on purpose. is_always_due is the
--                     opt-in for the ones that genuinely do recur — and
--                     the Excel's CTE_AlwaysDueList never came across,
--                     because Bills has no column for it to come from.
--   no occurrence     the schedule produces no date inside this period.
--                     Correct for a monthly bill in the wrong fortnight;
--                     wrong if the due day is inside it.
--   already there     it did materialise. Nothing to explain.
--
-- Read-only.
-- =====================================================================

with per as (
  select * from budget_period
  where period_start <= current_date and current_date <= period_end
  order by period_start
  limit 1
)
select
  a.id,
  a.kind,
  a.name,
  a.is_active,
  a.is_always_due,
  a.frequency,
  a.due_day,
  a.anchor_date,
  a.default_amount,
  (select count(*) from budget_line l
    where l.account_id = a.id and l.budget_period_id = (select id from per)) as has_line,
  (select array_agg(d.due_date order by d.due_date)
     from per p,
          lateral occurrences_in_window(
            a.frequency, a.due_day, a.due_day_2, a.due_month, a.anchor_date,
            p.period_start, p.period_end, p.pay_date
          ) as d(due_date)) as schedule_would_give,
  case
    when not a.is_active                                      then 'inactive'
    when exists (select 1 from budget_line l
                  where l.account_id = a.id
                    and l.budget_period_id = (select id from per))
                                                              then 'already there'
    when a.kind = 'expense' and not a.is_always_due           then 'expense — tick Always due to include it'
    when not exists (
      select 1 from per p,
        lateral occurrences_in_window(
          a.frequency, a.due_day, a.due_day_2, a.due_month, a.anchor_date,
          p.period_start, p.period_end, p.pay_date) as d(due_date))
                                                              then 'no occurrence in this period'
    else 'should be there — run Refresh budget'
  end as verdict
from account a
order by
  case
    when not a.is_active then 4
    when exists (select 1 from budget_line l
                  where l.account_id = a.id
                    and l.budget_period_id = (select id from per)) then 5
    else 1
  end,
  a.kind, a.name;


-- ---------------------------------------------------------------------
-- The period this was asked about, so the dates above have context.
-- ---------------------------------------------------------------------
select id, period_start, period_end, pay_date, is_closed
from budget_period
where period_start <= current_date and current_date <= period_end;
