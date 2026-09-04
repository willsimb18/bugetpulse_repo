-- =====================================================================
-- Remove the example starting rate left behind by 09_seed_example.sql.
--
-- That file calls apply_raise(..., p_note => 'Starting rate') to give the
-- app something to show before a real import. If it was run on a database
-- that was later imported into, the earner ends up with two rates: the
-- example one, and the real one from Finance's Wages table. The Income
-- tab then lists that person twice.
--
-- Only rows whose note is exactly 'Starting rate' are considered, and
-- only where that earner has another rate to fall back on -- so this can
-- never leave someone with no rate at all.
-- =====================================================================

-- ---------------------------------------------------------------------
-- STEP 1 -- what is on file, and what would go.
-- ---------------------------------------------------------------------
select w.id, e.display_name as earner, w.effective_from,
       w.hourly_rate, w.note,
       case when w.note = 'Starting rate'
             and exists (select 1 from wage_rate o
                          where o.earner_id = w.earner_id and o.id <> w.id)
            then 'WOULD DELETE' else 'keeps' end as verdict
from wage_rate w
join earner e on e.id = w.earner_id
order by e.display_name, w.effective_from;


-- ---------------------------------------------------------------------
-- STEP 2 -- remove them.
-- ---------------------------------------------------------------------
delete from wage_rate w
where w.note = 'Starting rate'
  and exists (select 1 from wage_rate o
               where o.earner_id = w.earner_id and o.id <> w.id);


-- Confirm: one rate per earner.
select e.display_name as earner, count(*) as rates,
       max(w.effective_from) as current_from
from wage_rate w
join earner e on e.id = w.earner_id
group by e.display_name
order by e.display_name;
