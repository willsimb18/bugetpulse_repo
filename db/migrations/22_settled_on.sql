-- =====================================================================
-- 22 — Separate when a bill counts as paid from when it was ticked.
--
-- paid_on was doing both jobs and could only tell the truth about one.
-- Settling an August bill in September set paid_on to the September date,
-- which put the payment outside the period it belonged to; backdating it
-- instead would have lost any record of when the entry was actually made.
--
--   paid_on    — the date the payment counts against. Backdated into the
--                period when a closed one is settled late.
--   settled_on — the day the tick happened. Never backdated, so the audit
--                question "when did someone record this" has an answer.
--
-- In the current period the two are the same day, which is why one column
-- got away with it until late settlement became possible.
-- =====================================================================

alter table budget_line
  add column if not exists settled_on date;

comment on column budget_line.paid_on is
  'The date the payment counts against — inside the period, backdated when '
  'a closed period is settled late.';
comment on column budget_line.settled_on is
  'The day the payment was actually recorded. Never backdated.';


-- ---------------------------------------------------------------------
-- mark_paid: record both, and choose the backdate when none is given.
--
-- A period still running takes today, as before. A period already ended
-- takes the line's own due date, which is inside it — so the money lands
-- in the fortnight it was owed in rather than the one it was typed in.
-- ---------------------------------------------------------------------
create or replace function mark_paid(
  p_line_id bigint,
  p_amount  numeric default null,
  p_paid_on date default null
) returns budget_line
language plpgsql security invoker
set search_path = public, pg_temp as $$
declare
  ln  budget_line;
  per budget_period;
  amt numeric(12,2);
  eff date;
begin
  select * into ln from budget_line where id = p_line_id;
  if not found then
    raise exception 'budget_line % not found or not visible', p_line_id;
  end if;

  select * into per from budget_period where id = ln.budget_period_id;

  amt := coalesce(p_amount, ln.amount_due);

  eff := coalesce(
    p_paid_on,
    case
      when per.period_end is not null and per.period_end < current_date
        then least(coalesce(ln.due_date, per.period_end), per.period_end)
      else current_date
    end);

  update budget_line
     set amount_paid = amt,
         paid_on     = eff,
         settled_on  = current_date,
         paid_by     = auth.uid(),
         status      = (case
                          when amt <= 0             then 'scheduled'
                          when amt >= ln.amount_due then 'paid'
                          else 'partial'
                        end)::line_status
   where id = p_line_id
   returning * into ln;

  return ln;
end $$;


create or replace function mark_unpaid(p_line_id bigint)
returns budget_line language sql security invoker
set search_path = public, pg_temp as $$
  update budget_line
     set amount_paid = 0, paid_on = null, settled_on = null,
         paid_by = null, status = 'scheduled'
   where id = p_line_id
   returning *;
$$;


-- ---------------------------------------------------------------------
-- v_budget_line_detail has to be dropped rather than replaced.
--
-- It was written as `select l.*`, which Postgres expands to an explicit
-- column list when the view is created. settled_on lands in the middle of
-- that list in table order, and create-or-replace only tolerates new
-- columns at the end — so replacing it in place fails.
-- ---------------------------------------------------------------------
drop view if exists v_budget_line_detail;

create view v_budget_line_detail
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


-- Anything already paid was recorded on the day it was paid, since late
-- settlement did not exist before now. Seeding settled_on from paid_on
-- keeps the column honest instead of leaving history blank.
update budget_line
   set settled_on = paid_on
 where paid_on is not null and settled_on is null;
