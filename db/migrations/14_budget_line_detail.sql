-- =====================================================================
-- 14 — v_budget_line_detail: a budget line plus what it cost last time.
--
-- The Budget tab reads the budget_line table directly, so it has never
-- had the two figures the old spreadsheet showed beside every bill: what
-- was last paid on that account, and when. v_account_admin computes them
-- for the Bills tab, but that is keyed on the account, not the line.
--
-- "Last" means the most recent earlier period in which this account was
-- settled — not this line, and not a later one — so an unpaid bill can be
-- read against what it actually came to last time.
--
-- Everything on budget_line is carried through unchanged, so the app can
-- swap the table for this view without losing a column.
-- =====================================================================

create or replace view v_budget_line_detail
with (security_invoker = true) as
select
  l.*,
  prev.amount_paid as last_paid_amount,
  prev.paid_on     as last_paid_on,
  prev.period_start as last_paid_period
from budget_line l
join budget_period p on p.id = l.budget_period_id
left join lateral (
  select bl.amount_paid, bl.paid_on, bp.period_start
  from budget_line bl
  join budget_period bp on bp.id = bl.budget_period_id
  where bl.account_id = l.account_id
    and l.account_id is not null
    and bl.id <> l.id
    and bl.status in ('paid', 'partial')
    and bp.period_start < p.period_start
  order by bp.period_start desc, bl.paid_on desc nulls last
  limit 1
) prev on true;

grant select on v_budget_line_detail to authenticated;
