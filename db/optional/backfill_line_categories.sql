-- =====================================================================
-- Fill in categories on lines added before the picker existed.
--
-- The one-off expense form sent p_category_id => null until migration 25,
-- so anything added by hand before that is sitting uncategorised — and
-- shows as "Uncategorised" in the donut and the category column.
--
-- This runs the same suggest_category() the form now uses, so a line
-- backfilled here gets what it would have got had the picker existed:
-- where the same name went last time if it has been used before,
-- otherwise the longest matching keyword.
--
-- Scoped to the period containing today. Past periods are history and are
-- left alone.
-- =====================================================================

-- ---------------------------------------------------------------------
-- STEP 1 — what is uncategorised, and what would be suggested for it.
--
-- suggestion null means neither source had anything to say; those need
-- picking by hand on the Budget tab.
-- ---------------------------------------------------------------------
select
  l.id as budget_line_id,
  l.name,
  l.kind,
  l.amount_due,
  l.is_manual,
  s.category_id   as suggested_id,
  s.category_name as suggestion,
  s.source,
  s.matched_on
from budget_line l
join budget_period p on p.id = l.budget_period_id
left join lateral suggest_category(l.name) s on true
where p.period_start <= current_date and current_date <= p.period_end
  and l.category_id is null
order by l.kind, l.name;


-- ---------------------------------------------------------------------
-- STEP 2 — apply them.
--
-- Only lines that are still uncategorised, only in the current period,
-- and only where there is a suggestion to apply. A line the query above
-- showed as null is skipped rather than blanked.
-- ---------------------------------------------------------------------
do $$
declare v_n int := 0;
begin
  update budget_line l
     set category_id = s.category_id
    from budget_period p,
         lateral suggest_category(l.name) s
   where p.id = l.budget_period_id
     and p.period_start <= current_date and current_date <= p.period_end
     and l.category_id is null
     and s.category_id is not null;
  get diagnostics v_n = row_count;

  raise notice 'Categorised % line(s).', v_n;
end $$;


-- Confirm: what is left without one, and where the rest landed.
select l.name, l.kind, l.amount_due,
       case when c.parent_id is null then c.name
            else parent.name || ' / ' || c.name end as category
from budget_line l
join budget_period p on p.id = l.budget_period_id
left join category c      on c.id = l.category_id
left join category parent on parent.id = c.parent_id
where p.period_start <= current_date and current_date <= p.period_end
order by (l.category_id is not null), l.kind, l.name;
