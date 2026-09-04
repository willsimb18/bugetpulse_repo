-- =====================================================================
-- Per-period reconciliation: what came from Finance vs what this app
-- generated on top.
--
-- The import was checked at the total: 2,898 source rows in, 2,898
-- budget_lines out, budget_line_unresolved = 0, and account counts
-- matching 62/286/13/2 exactly. That proves nothing was LOST.
--
-- It does not prove nothing was ADDED, and that is the gap. Lines reach a
-- period two ways — the import wrote history, and materialize_period
-- writes forward from the account catalogue — so an account that is not
-- from Finance quietly appears in every period without any total going
-- wrong.
--
-- The import wrote amount_overridden = true on every line it created.
-- That flag is what separates the two.
--
-- Read-only.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Every period: imported history against generated lines.
--
-- A period from before the app existed should be entirely imported.
-- Anything generated in one of those is this app inventing history.
-- ---------------------------------------------------------------------
select
  p.period_start,
  p.period_end,
  count(*) filter (where l.amount_overridden)       as imported,
  count(*) filter (where not l.amount_overridden)   as generated,
  count(*) filter (where l.is_manual)               as added_by_hand,
  sum(l.amount_due) filter (where l.amount_overridden)     as imported_due,
  sum(l.amount_due) filter (where not l.amount_overridden) as generated_due
from budget_period p
left join budget_line l on l.budget_period_id = p.id
group by p.period_start, p.period_end
order by p.period_start;


-- ---------------------------------------------------------------------
-- 2. The accounts behind the generated lines, and whether Finance knows
--    them. no_finance_history = true is the one to look at.
-- ---------------------------------------------------------------------
select
  a.id, a.kind, a.name, a.default_amount, a.frequency, a.is_always_due,
  count(*)                                as generated_lines,
  min(p.period_start)                     as first_seen,
  max(p.period_start)                     as last_seen,
  not exists (
    select 1 from budget_line x
    where x.account_id = a.id and x.amount_overridden
  )                                       as no_finance_history
from budget_line l
join account a       on a.id = l.account_id
join budget_period p on p.id = l.budget_period_id
where not l.amount_overridden
group by a.id, a.kind, a.name, a.default_amount, a.frequency, a.is_always_due
order by no_finance_history desc, a.kind, a.name;


-- ---------------------------------------------------------------------
-- 3. Accounts Finance sent that have stopped appearing. The opposite
--    failure: something real that is no longer being budgeted, because
--    it is inactive or its schedule never lands in a period.
-- ---------------------------------------------------------------------
select
  a.id, a.kind, a.name, a.is_active, a.frequency, a.due_day, a.anchor_date,
  max(p.period_start) as last_budgeted
from account a
join budget_line l   on l.account_id = a.id
join budget_period p on p.id = l.budget_period_id
where exists (
  select 1 from budget_line x where x.account_id = a.id and x.amount_overridden
)
group by a.id, a.kind, a.name, a.is_active, a.frequency, a.due_day, a.anchor_date
having max(p.period_start) < current_date - interval '60 days'
order by a.kind, a.name;
