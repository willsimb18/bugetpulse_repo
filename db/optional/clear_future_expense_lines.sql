-- =====================================================================
-- Clear auto-created expense lines out of the current and future periods.
--
-- Migration 16 stops materialize_period creating them, but it cannot undo
-- what earlier runs already made. If upkeep ran before that migration
-- landed, every future period is carrying an expense line per account.
--
-- Covers the period you are in as well as every one after it. The
-- current period was excluded at first, which was too cautious: it is the
-- one you are looking at, and it was carrying the whole catalogue.
--
-- WHAT THIS WILL NOT TOUCH — history is the point of the exercise:
--   * any period that has already ended (period_end < today)
--   * anything paid or part paid, in any period
--   * anything added by hand (is_manual), in any period
--   * anything on an is_always_due account, which is an explicit
--     instruction that it belongs in every period
--   * bills, debts and savings — expenses only
--
-- So it only removes scheduled, untouched, auto-generated expense lines
-- from today's period onwards. Anything you have already paid in the
-- current period stays exactly where it is.
--
-- Run STEP 1, read it, then run STEP 2.
-- =====================================================================

-- ---------------------------------------------------------------------
-- STEP 1 — what would go, and what is being kept.
--
-- Check that migration 16 has applied before running STEP 2, or
-- materialize_period will simply put them back on the next upkeep:
--   select filename from schema_migrations where filename like '16%';
-- ---------------------------------------------------------------------
select
  count(*)                                         as would_delete,
  count(distinct l.budget_period_id)               as across_periods,
  min(p.period_start)                              as first_period,
  max(p.period_start)                              as last_period
from budget_line l
join budget_period p on p.id = l.budget_period_id
join account a       on a.id = l.account_id
where l.kind = 'expense'
  and l.status = 'scheduled'
  and not coalesce(l.is_manual, false)
  and not a.is_always_due
  and p.period_end >= current_date;

-- Everything that stays, so the numbers can be checked before and after.
select
  count(*) filter (where kind = 'expense')                    as expense_lines_total,
  count(*) filter (where kind = 'expense' and status = 'paid') as expense_paid,
  count(*)                                                    as all_lines
from budget_line;


-- ---------------------------------------------------------------------
-- STEP 2 — remove them.
-- ---------------------------------------------------------------------
delete from budget_line l
using budget_period p, account a
where p.id = l.budget_period_id
  and a.id = l.account_id
  and l.kind = 'expense'
  and l.status = 'scheduled'
  and not coalesce(l.is_manual, false)
  and not a.is_always_due
  and p.period_end >= current_date;


-- ---------------------------------------------------------------------
-- Confirm. expense_paid must be unchanged from STEP 1 — if it moved,
-- something was deleted that should not have been.
-- ---------------------------------------------------------------------
select
  count(*) filter (where kind = 'expense')                    as expense_lines_total,
  count(*) filter (where kind = 'expense' and status = 'paid') as expense_paid,
  count(*)                                                    as all_lines
from budget_line;
