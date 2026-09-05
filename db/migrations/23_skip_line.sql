-- =====================================================================
-- 23 — Skip a bill for one period, without deleting it.
--
-- line_status has carried 'skipped' since 01_schema.sql and nothing has
-- ever set it. Two things had to be true for it to mean anything.
--
-- IT HAD TO STOP COUNTING. v_period_summary summed amount_due across
-- every line whatever its status, so a skipped bill still showed as owed
-- and still pulled projected_balance down — skipping would have changed
-- the label on a row and nothing else.
--
-- AND IT HAD TO SURVIVE THE NIGHTLY JOB, which it already does:
-- refresh_period_amounts only reprices status = 'scheduled', and
-- materialize_period ends in `on conflict (budget_period_id, account_id,
-- due_date) do nothing`, so the skipped row stays put and blocks its own
-- recreation in that period. The next period materialises a fresh line at
-- the account's own cadence, which is the "reappears next month"
-- behaviour wanted here.
--
-- Deleting the line instead would have let the nightly job put it
-- straight back.
-- =====================================================================

create or replace function skip_line(
  p_line_id bigint,
  p_reason  text default null
) returns budget_line
language plpgsql security invoker
set search_path = public, pg_temp as $$
declare rec budget_line;
begin
  perform require_owner();

  select * into rec from budget_line where id = p_line_id;
  if not found then
    raise exception 'budget_line % not found or not visible', p_line_id;
  end if;
  if rec.status in ('paid', 'partial') then
    raise exception
      'This one is already paid. Unmark it before skipping, or leave it as it is.'
      using errcode = '22023';
  end if;

  update budget_line
     set status = 'skipped',
         notes  = coalesce(nullif(btrim(coalesce(p_reason, '')), ''), notes)
   where id = p_line_id
   returning * into rec;

  return rec;
end $$;


create or replace function unskip_line(p_line_id bigint)
returns budget_line
language plpgsql security invoker
set search_path = public, pg_temp as $$
declare rec budget_line;
begin
  perform require_owner();

  update budget_line
     set status = 'scheduled'
   where id = p_line_id and status = 'skipped'
   returning * into rec;

  if not found then
    raise exception 'budget_line % is not skipped', p_line_id;
  end if;
  return rec;
end $$;

revoke execute on function skip_line(bigint, text)  from public, anon;
revoke execute on function unskip_line(bigint)      from public, anon;
grant  execute on function skip_line(bigint, text)  to authenticated;
grant  execute on function unskip_line(bigint)      to authenticated;


-- ---------------------------------------------------------------------
-- Keep skipped money out of every total.
--
-- Same columns in the same order — skipped_count and skipped_due are
-- appended, which is all create-or-replace allows.
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
  coalesce(ln.paid_count, 0)                               as paid_count,
  -- Added in 23. What was set aside this period, and how much it came to.
  coalesce(ln.skipped_count, 0)                            as skipped_count,
  coalesce(ln.skipped_due, 0)                              as skipped_due
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
  -- Every money figure here excludes skipped. line_count keeps counting
  -- them, because they are still on the period and still on screen.
  select sum(amount_due)  filter (where status <> 'skipped') as total_due,
         sum(amount_paid) filter (where status <> 'skipped') as total_paid,
         sum(amount_due) filter (where kind = 'bill'    and status <> 'skipped') as bills_due,
         sum(amount_due) filter (where kind = 'expense' and status <> 'skipped') as expenses_due,
         sum(amount_due) filter (where kind = 'debt'    and status <> 'skipped') as debts_due,
         sum(amount_due) filter (where kind = 'saving'  and status <> 'skipped') as savings_due,
         count(*)                                        as line_count,
         count(*) filter (where status = 'paid')         as paid_count,
         count(*) filter (where status = 'skipped')      as skipped_count,
         sum(amount_due) filter (where status = 'skipped') as skipped_due
  from budget_line where budget_period_id = p.id
) ln on true;

grant select on v_period_summary to authenticated;


-- ---------------------------------------------------------------------
-- v_account_admin: the two schedule fields the Bills page needs to show
-- a "Due On" column honestly.
--
-- It already returns due_day and anchor_date but not due_day_2 or
-- due_month, so a semimonthly account read as though it billed once and
-- an annual one lost the month entirely.
-- ---------------------------------------------------------------------
create or replace view v_account_admin
with (security_invoker = true) as
select
  a.id, a.household_id, a.name, a.kind, a.frequency,
  a.default_amount, a.due_day, a.anchor_date,
  a.is_always_due, a.is_variable, a.is_active,
  a.amount_mode, a.amount_percent, a.amount_set_on,
  parent.name as type_name,
  case when c.parent_id is null then null else c.name end as sub_type_name,
  e.display_name as owner_name,
  st.last_paid_on,
  st.last_paid_amount,
  st.open_lines,
  a.updated_at,
  a.due_day_2,
  a.due_month
from account a
left join category c on c.id = a.category_id
left join category parent on parent.id = coalesce(c.parent_id, c.id)
left join earner e on e.id = a.owner_earner_id
left join lateral (
  select max(paid_on) filter (where status = 'paid') as last_paid_on,
         (array_agg(amount_paid order by paid_on desc nulls last)
            filter (where status = 'paid'))[1]      as last_paid_amount,
         count(*) filter (where status = 'scheduled') as open_lines
  from budget_line where account_id = a.id
) st on true;

grant select on v_account_admin to authenticated;
