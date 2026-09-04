-- =====================================================================
-- Pay calendar health check. Read-only.
--
-- Two things built this calendar and they did not agree.
--
--   06_bootstrap.sql ran generate_budget_periods from the anchor date,
--   laying down exact 14-day periods: Aug 21, Sep 4, Sep 18 ...
--
--   import_from_sqlserver.py laid down one period per distinct PayDate in
--   Budget, each ending the day before the next pay date — so their
--   length follows whatever the real gaps between paychecks were.
--
-- Where the two disagree on where a fortnight starts, the unique
-- constraint (household_id, period_start, frequency) does not fire,
-- because the period_starts differ. Both rows are inserted and the
-- calendar ends up with two periods covering the same days.
--
-- That is what a short period — 11 days instead of 14 — is telling you.
-- Budget lines then land in whichever period materialised them, and the
-- Budget tab shows whichever its date lookup happens to match first.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Overlapping periods. Anything here is the actual fault.
--    keep_hint suggests the one carrying real activity.
-- ---------------------------------------------------------------------
select
  a.id            as period_a,
  a.period_start  as a_start,
  a.period_end    as a_end,
  (a.period_end - a.period_start + 1) as a_days,
  (select count(*) from budget_line l where l.budget_period_id = a.id) as a_lines,
  (select count(*) from income     i where i.budget_period_id = a.id) as a_income,
  b.id            as period_b,
  b.period_start  as b_start,
  b.period_end    as b_end,
  (b.period_end - b.period_start + 1) as b_days,
  (select count(*) from budget_line l where l.budget_period_id = b.id) as b_lines,
  (select count(*) from income     i where i.budget_period_id = b.id) as b_income
from budget_period a
join budget_period b
  on b.household_id = a.household_id
 and b.id > a.id
 and a.period_start <= b.period_end
 and b.period_start <= a.period_end
order by a.period_start;

-- ---------------------------------------------------------------------
-- 2. Periods whose length is not the cadence. A biweekly period that is
--    not 14 days was cut short by the period that follows it.
-- ---------------------------------------------------------------------
select id, period_start, period_end,
       (period_end - period_start + 1) as days,
       is_closed,
       (select count(*) from budget_line l where l.budget_period_id = budget_period.id) as lines,
       (select count(*) from income     i where i.budget_period_id = budget_period.id) as income_rows
from budget_period
where frequency = 'biweekly'
  and (period_end - period_start + 1) <> 14
order by period_start;

-- ---------------------------------------------------------------------
-- 3. Gaps — days no period covers at all. The opposite failure, and just
--    as worth knowing about.
-- ---------------------------------------------------------------------
select period_end as gap_after,
       lead(period_start) over (order by period_start) as next_starts,
       lead(period_start) over (order by period_start) - period_end - 1 as missing_days
from budget_period
order by period_start;

-- ---------------------------------------------------------------------
-- 4. What today resolves to. More than one row here is the bug you are
--    seeing on the Budget tab: the app picks the first match.
-- ---------------------------------------------------------------------
select id, period_start, period_end, pay_date, label, is_closed
from budget_period
where period_start <= current_date and current_date <= period_end
order by period_start;
