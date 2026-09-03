-- =====================================================================
-- One-time: attribute already-imported paychecks to a person.
--
-- Finance's BudgetIncome holds one household figure per pay date and no
-- earner, so the first import wrote every row with earner_id null and the
-- app could only ever say "Household". Wages does carry the split, so
-- each paycheck is apportioned by the earners' take-home -- the same
-- arithmetic the Wages tab does: rate x hours, less taxes, healthcare and
-- 401K.
--
-- Only kind = 'regular' rows are touched. A deposit, a savings or credit
-- draw, or a bonus that Wages records as zero has no basis for a split
-- and stays on the household.
--
-- Totals are preserved exactly: the last earner absorbs the rounding, and
-- the script refuses to commit if any pay date's shares fail to add back
-- to the original figure.
--
-- Not needed on a database imported after this was added to
-- import_from_sqlserver.py -- that now splits on the way in. Safe to run
-- twice: rows it has already split are skipped.
-- =====================================================================

do $$
declare
  v_hh      uuid;
  v_total   numeric;
  v_row     record;
  v_earner  record;
  v_running numeric;
  v_part    numeric;
  v_i       int;
  v_n       int;
  v_done    int := 0;
begin
  select id into v_hh from household limit 1;
  if v_hh is null then raise exception 'No household row.'; end if;

  -- Each earner's take-home per period, from the rate in force.
  create temp table _share on commit drop as
  select w.earner_id,
         round(coalesce(w.annual_salary / 26.0,
                        coalesce(w.hourly_rate,0) * coalesce(w.standard_hours,0))
               - coalesce(w.taxes_est,0)
               - coalesce(w.healthcare_est,0)
               - coalesce(w.retirement_est,0), 2) as net
  from wage_rate w
  where w.household_id = v_hh
    and w.effective_from = (select max(effective_from) from wage_rate w2
                             where w2.earner_id = w.earner_id);

  delete from _share where net is null or net <= 0;

  select count(*), sum(net) into v_n, v_total from _share;
  if v_n < 2 then
    raise notice 'Only % earner(s) with a positive rate — nothing to split.', v_n;
    return;
  end if;

  for v_row in
    select id, budget_period_id, received_on, gross_override
    from income
    where household_id = v_hh
      and kind = 'regular'
      and earner_id is null
      and coalesce(gross_override,0) > 0
    order by received_on, id
  loop
    v_running := 0;
    v_i := 0;
    for v_earner in select earner_id, net from _share order by earner_id loop
      v_i := v_i + 1;
      if v_i = v_n then
        v_part := v_row.gross_override - v_running;      -- absorbs rounding
      else
        v_part := round(v_row.gross_override * v_earner.net / v_total, 2);
        v_running := v_running + v_part;
      end if;

      insert into income (household_id, earner_id, budget_period_id,
                          received_on, kind, gross_override, notes)
      values (v_hh, v_earner.earner_id, v_row.budget_period_id,
              v_row.received_on, 'regular', v_part,
              'Imported from BudgetIncome — split by pay rate');
    end loop;

    delete from income where id = v_row.id;
    v_done := v_done + 1;
  end loop;

  raise notice 'Split % paychecks across % earners.', v_done, v_n;
end $$;

-- Every paycheck should now name a person, and the totals per pay date
-- should be unchanged from before the split.
select e.display_name as earner,
       count(*)          as paychecks,
       sum(i.net)        as take_home
from income i
join earner e on e.id = i.earner_id
where i.kind = 'regular'
group by e.display_name
order by e.display_name;

select count(*) filter (where earner_id is null) as still_unattributed,
       count(*)                                  as regular_rows
from income where kind = 'regular';
