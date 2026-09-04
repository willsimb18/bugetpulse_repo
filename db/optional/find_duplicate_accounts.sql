-- =====================================================================
-- Accounts whose names differ only by case or spacing.
--
-- account's unique constraint is on the raw name, so "Mortgage" and
-- "mortgage" are two accounts, each materialising its own budget line
-- every period. Migration 20 adds a case-insensitive index, but it can
-- only do so once none are left.
--
-- Read-only. Merging is a judgement call: which name to keep, and what to
-- do with the budget lines already attached to the other.
-- =====================================================================

select
  kind,
  lower(btrim(name))                       as normalised,
  count(*)                                 as accounts,
  array_agg(id order by id)                as account_ids,
  array_agg(name order by id)              as names_as_stored,
  array_agg(is_active order by id)         as active,
  array_agg(
    (select count(*) from budget_line l where l.account_id = a.id)
    order by id)                           as budget_lines
from account a
group by kind, lower(btrim(name))
having count(*) > 1
order by kind, normalised;

-- To merge: point the loser's budget lines at the keeper, then delete it.
-- Fill in the two ids from above.
--
--   update budget_line set account_id = <keep_id> where account_id = <drop_id>;
--   delete from account where id = <drop_id>;
--
-- Do it one pair at a time and re-run the query above until it is empty.
