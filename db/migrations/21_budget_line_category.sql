-- =====================================================================
-- 21 — Put the category name on v_budget_line_detail.
--
-- The Budget tab reads this view, and budget_line only carries
-- category_id. So the page could group and total by category only by
-- fetching the category table separately and joining in the browser --
-- and it never did, which is why nothing on that tab has ever shown a
-- category at all.
--
-- type_name is the parent ("Kids"), sub_type_name the child where one
-- exists ("Child Care"), matching how v_current_budget and
-- v_account_admin already name them.
--
-- create or replace view only permits new columns at the end, so these
-- land after the last_paid trio from migration 14.
-- =====================================================================

create or replace view v_budget_line_detail
with (security_invoker = true) as
select
  l.*,
  prev.amount_paid  as last_paid_amount,
  prev.paid_on      as last_paid_on,
  prev.period_start as last_paid_period,
  parent.name       as type_name,
  case when c.parent_id is null then null else c.name end as sub_type_name
from budget_line l
join budget_period p on p.id = l.budget_period_id
left join category c      on c.id = l.category_id
left join category parent on parent.id = coalesce(c.parent_id, c.id)
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
