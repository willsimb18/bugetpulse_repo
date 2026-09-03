-- =====================================================================
-- 12 — Give v_income_history the row's own id.
--
-- The view exposed every column of income except its primary key, so the
-- app had nothing stable to key a list on: React logged a missing-key
-- warning on the Income tab for every paycheck, and IncomeRow.id was
-- typed as a number that was always undefined.
--
-- create or replace view only permits new columns at the end, which is
-- why id lands last rather than first.
-- =====================================================================

create or replace view v_income_history
with (security_invoker = true) as
select
  i.household_id, e.display_name as earner,
  date_trunc('month', i.received_on)::date as month,
  i.received_on, i.kind, i.hours, i.gross, i.taxes,
  i.healthcare, i.retirement, i.other_deductions, i.net,
  i.budget_period_id,
  i.id
from income i
left join earner e on e.id = i.earner_id;

grant select on v_income_history to authenticated;
