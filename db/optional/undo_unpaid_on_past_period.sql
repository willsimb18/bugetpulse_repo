-- =====================================================================
-- Find, and put back, a bill unmarked as paid on a past period.
--
-- mark_paid / mark_unpaid were not gated on the period, so a line in a
-- fortnight already gone could be unticked. The audit trigger on
-- budget_line recorded it, so the old values are recoverable rather than
-- having to be remembered.
--
-- STEP 1 finds it. STEP 2 puts it back from what the audit row holds.
-- =====================================================================

-- ---------------------------------------------------------------------
-- STEP 1 — recent changes that took a line OUT of paid, newest first.
--
-- old_row.status = 'paid' and new_row.status is something else is exactly
-- the shape of an untick.
-- ---------------------------------------------------------------------
select
  a.changed_at,
  a.actor_name,
  a.row_id                          as budget_line_id,
  a.row_name                        as line,
  p.period_start,
  p.period_end,
  a.old_row ->> 'status'            as was,
  a.new_row ->> 'status'            as now,
  a.old_row ->> 'amount_paid'       as was_paid,
  a.old_row ->> 'paid_on'           as was_paid_on
from v_audit_trail a
join budget_line l  on l.id = a.row_id
join budget_period p on p.id = l.budget_period_id
where a.table_name = 'budget_line'
  and a.action = 'UPDATE'
  and a.old_row ->> 'status' = 'paid'
  and coalesce(a.new_row ->> 'status', '') <> 'paid'
  and a.changed_at > now() - interval '7 days'
order by a.changed_at desc
limit 20;


-- ---------------------------------------------------------------------
-- STEP 2 — restore one line to what the audit row says it was.
--
-- Put the budget_line_id from STEP 1 in v_line. Reads the amount and date
-- back out of the audit entry rather than being told them, so the line
-- returns to exactly what it was rather than to a best guess.
-- ---------------------------------------------------------------------
do $$
declare
  v_line bigint := 0;      -- <-- the budget_line_id from STEP 1
  v_old  jsonb;
begin
  if v_line = 0 then
    raise exception 'Put the budget_line_id from STEP 1 in v_line first.';
  end if;

  select a.old_row into v_old
  from v_audit_trail a
  where a.table_name = 'budget_line'
    and a.row_id = v_line
    and a.old_row ->> 'status' = 'paid'
  order by a.changed_at desc
  limit 1;

  if v_old is null then
    raise exception 'No audit entry showing line % was ever paid.', v_line;
  end if;

  update budget_line
     set status      = 'paid',
         amount_paid = (v_old ->> 'amount_paid')::numeric,
         paid_on     = (v_old ->> 'paid_on')::date,
         paid_by     = nullif(v_old ->> 'paid_by', '')::uuid
   where id = v_line;

  raise notice 'Line % restored to paid: % on %.',
    v_line, (v_old ->> 'amount_paid'), (v_old ->> 'paid_on');
end $$;


-- Confirm.
select l.id, l.name, l.status, l.amount_paid, l.paid_on, p.period_start
from budget_line l
join budget_period p on p.id = l.budget_period_id
where l.id = 0;   -- <-- same id
