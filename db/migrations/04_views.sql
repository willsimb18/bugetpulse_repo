-- =====================================================================
-- Views — v2. All security_invoker: RLS on base tables still applies.
-- =====================================================================

create or replace view v_current_period
with (security_invoker = true) as
select * from budget_period
where current_date between period_start and period_end
order by pay_date desc;

-- ---------------------------------------------------------------------
-- v_current_budget — the replacement for vw_BI_WeeklyBudget.
--
-- The original was 288 lines because it had to *derive* the pay calendar
-- from MAX(PayDate) and *guess* isDue from six chained CASE branches.
-- With budget_period as a real table and lines materialized against it,
-- "is it due this period" is just a join.
-- ---------------------------------------------------------------------
create or replace view v_current_budget
with (security_invoker = true) as
select
  l.id                    as budget_line_id,
  l.household_id,
  l.budget_period_id,
  p.period_start,
  p.period_end,
  p.pay_date,
  l.account_id,
  l.name                  as account_name,
  parent.name             as type_name,
  case when c.parent_id is null then null else c.name end as sub_type_name,
  l.kind,
  a.frequency,
  l.due_date,
  l.amount_due,
  l.amount_paid,
  l.amount_due - l.amount_paid as balance_due,
  l.status,
  l.paid_on,
  pr.display_name         as paid_by_name,
  l.funds_held,
  l.funds_held_amount,
  l.funds_held_until,
  l.from_savings,
  l.is_manual,
  a.is_variable,
  -- AccountType legend preserved from sp_AddBillsToBudget:
  -- 1-Bill, 2-Debts, 3-Savings, 4-Expenses
  case l.kind when 'bill' then 1 when 'debt' then 2
              when 'saving' then 3 else 4 end as account_type
from budget_line l
join budget_period p  on p.id = l.budget_period_id
left join account  a  on a.id = l.account_id
left join category c  on c.id = l.category_id
left join category parent on parent.id = coalesce(c.parent_id, c.id)
left join profile  pr on pr.id = l.paid_by;

-- ---------------------------------------------------------------------
-- v_period_expenses — your variable per-paycheck expenses.
--
-- Finance modelled this as Expenses.isNew = 1 plus a re-amount on every
-- run, so only the CURRENT paycheck's expenses existed. Here each period
-- keeps its own amounts, so expense history is queryable.
-- ---------------------------------------------------------------------
create or replace view v_period_expenses
with (security_invoker = true) as
select
  l.household_id,
  l.budget_period_id,
  p.pay_date,
  l.id            as budget_line_id,
  l.account_id,
  l.name          as expense_name,
  parent.name     as expense_type,
  c.name          as sub_type,
  a.default_amount as usual_amount,
  l.amount_due,
  l.amount_paid,
  l.amount_due - a.default_amount as variance_from_usual,
  l.status,
  l.is_manual
from budget_line l
join budget_period p on p.id = l.budget_period_id
left join account  a on a.id = l.account_id
left join category c on c.id = l.category_id
left join category parent on parent.id = coalesce(c.parent_id, c.id)
where l.kind = 'expense';

-- Expense trend: what each expense has actually cost, period over period.
create or replace view v_expense_trend
with (security_invoker = true) as
select
  l.household_id,
  l.name,
  count(*)                       as periods_tracked,
  round(avg(l.amount_due), 2)    as avg_budgeted,
  round(avg(l.amount_paid), 2)   as avg_actual,
  min(l.amount_paid)             as min_actual,
  max(l.amount_paid)             as max_actual,
  round(stddev_samp(l.amount_paid), 2) as volatility
from budget_line l
where l.kind = 'expense'
group by l.household_id, l.name;

-- ---------------------------------------------------------------------
-- Period rollup
-- ---------------------------------------------------------------------
create or replace view v_period_summary
with (security_invoker = true) as
select
  p.id as budget_period_id, p.household_id, p.period_start, p.period_end,
  p.pay_date, p.label, p.is_closed, p.opening_balance,
  coalesce(inc.net_income, 0)                              as net_income,
  coalesce(inc.gross_income, 0)                            as gross_income,
  -- Wages only. This is what the paychecks actually covered.
  coalesce(inc.wage_income, 0)                             as wage_income,
  -- Money moved in from somewhere else to make the period balance.
  coalesce(inc.from_savings, 0)                            as from_savings,
  coalesce(inc.from_credit, 0)                             as from_credit,
  coalesce(inc.bonus_income, 0)                            as bonus_income,
  coalesce(inc.other_funding, 0)                           as other_funding,
  coalesce(ln.total_due, 0)                                as total_due,
  coalesce(ln.total_paid, 0)                               as total_paid,
  coalesce(ln.total_due,0) - coalesce(ln.total_paid,0)     as remaining_due,
  coalesce(ln.bills_due, 0)                                as bills_due,
  coalesce(ln.expenses_due, 0)                             as expenses_due,
  coalesce(ln.debts_due, 0)                                as debts_due,
  coalesce(ln.savings_due, 0)                              as savings_due,
  p.opening_balance + coalesce(inc.net_income,0) - coalesce(ln.total_due,0)  as projected_balance,
  p.opening_balance + coalesce(inc.net_income,0) - coalesce(ln.total_paid,0) as actual_balance,
  -- What the period looks like on pay alone, before any savings draw or
  -- credit draw is counted. Negative means the paychecks didn't cover it.
  p.opening_balance + coalesce(inc.wage_income,0) - coalesce(ln.total_due,0)
                                                                            as balance_on_wages,
  coalesce(ln.line_count, 0)                               as line_count,
  coalesce(ln.paid_count, 0)                               as paid_count
from budget_period p
left join lateral (
  select sum(net)                                        as net_income,
         sum(gross)                                      as gross_income,
         sum(net) filter (where is_wage(kind))           as wage_income,
         sum(net) filter (where kind = 'from_savings')   as from_savings,
         sum(net) filter (where kind = 'line_of_credit') as from_credit,
         sum(net) filter (where kind = 'bonus')          as bonus_income,
         sum(net) filter (where kind in ('deposit','tax_refund','other'))
                                                         as other_funding
  from income where budget_period_id = p.id
) inc on true
left join lateral (
  select sum(amount_due)  as total_due,
         sum(amount_paid) as total_paid,
         sum(amount_due) filter (where kind = 'bill')    as bills_due,
         sum(amount_due) filter (where kind = 'expense') as expenses_due,
         sum(amount_due) filter (where kind = 'debt')    as debts_due,
         sum(amount_due) filter (where kind = 'saving')  as savings_due,
         count(*)                                        as line_count,
         count(*) filter (where status = 'paid')         as paid_count
  from budget_line where budget_period_id = p.id
) ln on true;

-- ---------------------------------------------------------------------
-- Funding entries for a period: bonuses, savings draws, credit draws.
-- ---------------------------------------------------------------------
create or replace view v_period_funding
with (security_invoker = true) as
select
  i.id, i.household_id, i.budget_period_id, i.received_on, i.kind,
  i.net as amount, i.notes,
  a.name  as source_account,
  a.kind  as source_kind
from income i
left join account a on a.id = i.source_account_id
where not is_wage(i.kind);

-- ---------------------------------------------------------------------
-- Due dates
-- ---------------------------------------------------------------------
create or replace view v_upcoming_due
with (security_invoker = true) as
select
  l.id, l.household_id, l.budget_period_id, l.name,
  parent.name as type_name, c.name as sub_type_name,
  l.kind, l.due_date, (l.due_date - current_date) as days_until,
  l.amount_due, l.amount_paid,
  l.amount_due - l.amount_paid as balance_due,
  l.status, l.paid_on, pr.display_name as paid_by_name,
  l.funds_held, l.funds_held_until,
  case
    when l.status = 'paid'              then 'paid'
    when l.due_date < current_date      then 'overdue'
    when l.due_date <= current_date + 3 then 'due_soon'
    else                                     'upcoming'
  end as urgency
from budget_line l
left join category c on c.id = l.category_id
left join category parent on parent.id = coalesce(c.parent_id, c.id)
left join profile pr on pr.id = l.paid_by;

-- ---------------------------------------------------------------------
-- Debt
-- ---------------------------------------------------------------------
create or replace view v_debt_status
with (security_invoker = true) as
select
  a.id, a.household_id, a.name, dd.debt_type,
  dd.credit_limit, dd.apr, dd.minimum_payment, a.due_day,
  e.display_name as owner_name,
  b.balance as current_balance, b.as_of as balance_as_of,
  dd.credit_limit - b.balance as available_credit,
  case when dd.credit_limit > 0 then round(b.balance / dd.credit_limit, 4) end as utilization,
  case when dd.credit_limit > 0 then round(1 - (b.balance / dd.credit_limit), 4) end as paid_off_pct,
  dd.target_utilization,
  case when dd.credit_limit > 0
       then round(b.balance - (dd.credit_limit * dd.target_utilization), 2) end as amount_over_target,
  rank() over (partition by a.household_id order by dd.apr desc nulls last)    as avalanche_rank,
  rank() over (partition by a.household_id order by b.balance asc nulls last)  as snowball_rank
from account a
join debt_detail dd on dd.account_id = a.id
left join earner e on e.id = a.owner_earner_id
left join lateral (
  select balance, as_of from debt_balance
  where account_id = a.id order by as_of desc limit 1
) b on true
where a.is_active and a.kind = 'debt';

-- ---------------------------------------------------------------------
-- Income
-- ---------------------------------------------------------------------
create or replace view v_income_history
with (security_invoker = true) as
select
  i.household_id, e.display_name as earner,
  date_trunc('month', i.received_on)::date as month,
  i.received_on, i.kind, i.hours, i.gross, i.taxes,
  i.healthcare, i.retirement, i.other_deductions, i.net,
  i.budget_period_id
from income i
left join earner e on e.id = i.earner_id;

create or replace view v_income_vs_spending
with (security_invoker = true) as
select household_id, month,
       sum(inc) as income, sum(spend) as spending,
       sum(inc) - sum(spend) as saved
from (
  select household_id, date_trunc('month', received_on)::date as month,
         net as inc, 0::numeric as spend
  from income
  union all
  select household_id, date_trunc('month', paid_on)::date,
         0::numeric, amount_paid
  from budget_line
  where status in ('paid','partial') and paid_on is not null
) x
group by household_id, month;

create or replace view v_category_spend
with (security_invoker = true) as
select
  l.household_id, l.budget_period_id,
  coalesce(parent.name, 'Uncategorized') as type_name,
  case when c.parent_id is null then null else c.name end as sub_type_name,
  sum(l.amount_due)  as budgeted,
  sum(l.amount_paid) as spent,
  count(*)           as line_count
from budget_line l
left join category c on c.id = l.category_id
left join category parent on parent.id = coalesce(c.parent_id, c.id)
group by l.household_id, l.budget_period_id, parent.name,
         case when c.parent_id is null then null else c.name end;

grant select on
  v_current_period, v_current_budget, v_period_expenses, v_expense_trend,
  v_period_summary, v_period_funding, v_upcoming_due, v_debt_status, v_income_history,
  v_income_vs_spending, v_category_spend
  to authenticated;
