-- =====================================================================
-- Move an account from expense to bill, and give it a schedule.
--
-- The import reads Finance's Bills table into kind='bill' and its
-- Expenses table into kind='expense'. Anything that is a monthly
-- subscription but landed as an expense came across from the wrong table,
-- and since migration 16 stopped materialising expenses it now never
-- appears on a period at all.
--
-- Converting is not just the kind. A monthly bill has to satisfy
-- account_schedule_present, which wants a due_day, so that is set here
-- too and the open periods are rebuilt afterwards.
--
-- HISTORY IS LEFT ALONE. Imported lines keep kind='expense' because that
-- is what Finance said at the time, and rewriting them would make the
-- past disagree with the source it came from. Only unpaid lines in open
-- periods are rebuilt.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Find them. Widen the pattern as needed.
-- ---------------------------------------------------------------------
select id, kind, name, is_active, is_always_due, frequency,
       due_day, anchor_date, default_amount,
       (select count(*) from budget_line l where l.account_id = a.id) as lines_total,
       (select count(*) from budget_line l
         where l.account_id = a.id and l.amount_overridden)          as imported_lines
from account a
where name ilike any (array['%icloud%', '%google%', '%storage%', '%drive%'])
order by kind, name;


-- ---------------------------------------------------------------------
-- 2. Convert one. Set the id and the day of the month it bills on,
--    then run. Repeat per account.
-- ---------------------------------------------------------------------
do $$
declare
  v_id      bigint := 0;    -- <-- account id from STEP 1
  v_due_day int    := 1;    -- <-- day of the month it bills on
  v_hh      uuid;
  v_name    text;
  v_pid     bigint;
  v_made    int := 0;
begin
  if v_id = 0 then
    raise exception 'Set v_id from STEP 1 first.';
  end if;
  if v_due_day < 1 or v_due_day > 31 then
    raise exception 'v_due_day must be between 1 and 31.';
  end if;

  select household_id, name into v_hh, v_name from account where id = v_id;
  if v_hh is null then
    raise exception 'No account with id %.', v_id;
  end if;

  -- unique (household_id, name, kind): a bill of the same name already
  -- existing would make this a duplicate rather than a conversion.
  if exists (select 1 from account
              where household_id = v_hh and name = v_name
                and kind = 'bill' and id <> v_id) then
    raise exception
      'A bill called "%" already exists. Merge them instead of converting '
      'this one, or the two will sit side by side.', v_name;
  end if;

  update account
     set kind        = 'bill',
         frequency   = 'monthly',
         due_day     = v_due_day,
         anchor_date = null,
         is_active   = true
   where id = v_id;

  -- Clear unpaid lines in open periods; they carry the old kind and the
  -- old dates. Paid lines and closed periods are untouched.
  delete from budget_line l
   using budget_period p
   where l.budget_period_id = p.id
     and l.account_id = v_id
     and l.status = 'scheduled'
     and l.amount_paid = 0
     and not p.is_closed
     and p.period_end >= current_date;

  for v_pid in
    select id from budget_period
    where household_id = v_hh and not is_closed and period_end >= current_date
    order by period_start
  loop
    v_made := v_made + materialize_period(v_pid);
  end loop;

  raise notice
    '"%" is now a monthly bill due on day %. % line(s) rebuilt.',
    v_name, v_due_day, v_made;
end $$;


-- Confirm, and show where it now lands.
select a.id, a.kind, a.name, a.frequency, a.due_day, a.is_active,
       p.period_start, l.due_date, l.amount_due, l.status
from account a
left join budget_line l   on l.account_id = a.id
left join budget_period p on p.id = l.budget_period_id
                         and p.period_end >= current_date
where a.name ilike any (array['%icloud%', '%google%', '%storage%', '%drive%'])
order by a.name, p.period_start;
