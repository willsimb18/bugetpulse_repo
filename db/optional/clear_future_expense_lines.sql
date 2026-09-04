-- =====================================================================
-- Clear auto-created expense lines out of periods that have not started.
--
-- Migration 16 stops materialize_period creating them, but it cannot undo
-- what earlier runs already made. If upkeep ran before that migration
-- landed, every future period is carrying an expense line per account.
--
-- WHAT THIS WILL NOT TOUCH — history is the point of the exercise:
--   * anything in a period that has already started (period_start <= today)
--   * anything paid or part paid, in any period
--   * anything added by hand (is_manual), in any period
--   * anything on an is_always_due account, which is an explicit
--     instruction that it belongs in every period
--   * bills, debts and savings — expenses only
--
-- So it only removes scheduled, untouched, auto-generated expense lines
-- in periods still ahead of you. Run STEP 1, read it, then run STEP 2.
-- =====================================================================

-- ---------------------------------------------------------------------
-- STEP 1 — what would go, and what is being kept.
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
  and p.period_start > current_date;

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
  and p.period_start > current_date;


-- ---------------------------------------------------------------------
-- Confirm. expense_paid must be unchanged from STEP 1 — if it moved,
-- something was deleted that should not have been.
-- ---------------------------------------------------------------------
select
  count(*) filter (where kind = 'expense')                    as expense_lines_total,
  count(*) filter (where kind = 'expense' and status = 'paid') as expense_paid,
  count(*)                                                    as all_lines
from budget_line;
