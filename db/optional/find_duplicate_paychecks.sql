-- =====================================================================
-- Duplicate paychecks: find them, then clear them.
--
-- record_paycheck had no guard until migration 17, so the same paycheck
-- could be recorded more than once for one earner in one period. Each
-- extra row inflates that period's income and everything derived from
-- it, and migration 17 will not add its unique index while any remain.
--
-- Run STEP 1 and look at what it found. Only run STEP 2 if the extra
-- rows really are duplicates rather than two genuine paychecks.
-- =====================================================================

-- ---------------------------------------------------------------------
-- STEP 1 — every group holding more than one row, and what they are.
-- ---------------------------------------------------------------------
select
  e.display_name              as earner,
  p.period_start,
  i.kind,
  count(*)                    as rows_held,
  sum(i.net)                  as combined_net,
  min(i.net)                  as smallest,
  max(i.net)                  as largest,
  array_agg(i.id order by i.id) as income_ids,
  array_agg(coalesce(i.notes,'') order by i.id) as notes
from income i
join earner e        on e.id = i.earner_id
join budget_period p on p.id = i.budget_period_id
where i.earner_id is not null and i.budget_period_id is not null
group by e.display_name, p.period_start, i.kind
having count(*) > 1
order by p.period_start desc;


-- ---------------------------------------------------------------------
-- STEP 2 — keep the earliest row of each group, delete the rest.
--
-- Earliest by id, so the first one recorded is the one that survives and
-- anything added afterwards by a double press goes. Nothing outside a
-- duplicated group is touched.
--
-- If two rows in a group are genuinely different paychecks, do NOT run
-- this — delete the specific id from STEP 1 instead.
-- ---------------------------------------------------------------------
delete from income
where id in (
  select id from (
    select id,
           row_number() over (
             partition by earner_id, budget_period_id, kind
             order by id
           ) as rn
    from income
    where earner_id is not null and budget_period_id is not null
  ) ranked
  where rn > 1
);


-- ---------------------------------------------------------------------
-- Confirm: this must come back empty. Then re-run migration 17 so it can
-- add the unique index it skipped.
-- ---------------------------------------------------------------------
select earner_id, budget_period_id, kind, count(*)
from income
where earner_id is not null and budget_period_id is not null
group by earner_id, budget_period_id, kind
having count(*) > 1;
