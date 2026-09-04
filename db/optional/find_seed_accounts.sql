-- =====================================================================
-- Accounts that came from the example seed, not from Finance.
--
-- 09_seed_example.sql creates five accounts and three categories so the
-- app has something to show before a real import:
--
--     Mortgage 2290.82 · Water 149.88 · Groceries 300
--     Emergency Fund 200 · Visa 561
--     Housing · Utilities · Food
--
-- If that file was run on a database that was later imported into, any of
-- those names Finance also uses were merged and repriced by the import's
-- upsert on (household_id, name, kind) — those are fine. The ones Finance
-- does NOT use survived as inventions, and materialize_period has been
-- putting them on every period since.
--
-- HOW THEY ARE TOLD APART: the import wrote every line it created with
-- amount_overridden = true. An account with no such line was never in
-- Finance, whatever it is called.
--
-- Read-only until STEP 3, which needs account ids typed in.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Candidates: active accounts with no imported history at all.
--
-- looks_like_seed flags the exact name-and-amount pairs 09_seed_example
-- creates, so a genuine account you added by hand is not mistaken for one.
-- ---------------------------------------------------------------------
select
  a.id,
  a.kind,
  a.name,
  a.default_amount,
  a.is_active,
  (select count(*) from budget_line l
    where l.account_id = a.id and l.amount_overridden) as imported_lines,
  (select count(*) from budget_line l
    where l.account_id = a.id)                          as lines_total,
  (select count(*) from budget_line l
    where l.account_id = a.id and l.status = 'paid')    as lines_paid,
  ((a.name, a.kind::text, a.default_amount) in (
     ('Mortgage','bill',2290.82), ('Water','bill',149.88),
     ('Groceries','expense',300), ('Emergency Fund','saving',200),
     ('Visa','debt',561)
   )) as looks_like_seed
from account a
where not exists (
  select 1 from budget_line l where l.account_id = a.id and l.amount_overridden
)
order by looks_like_seed desc, a.kind, a.name;


-- ---------------------------------------------------------------------
-- 2. Every line those accounts have put on the budget, and where.
--    Check nothing here is a payment you actually made.
-- ---------------------------------------------------------------------
select
  a.name, a.kind, p.period_start, p.period_end,
  l.id as budget_line_id, l.due_date, l.status,
  l.amount_due, l.amount_paid, l.paid_on
from budget_line l
join account a       on a.id = l.account_id
join budget_period p on p.id = l.budget_period_id
where not exists (
  select 1 from budget_line x where x.account_id = a.id and x.amount_overridden
)
order by a.name, p.period_start;


-- ---------------------------------------------------------------------
-- 3. Remove them. Put the ids from STEP 1 in v_ids.
--
-- Lines are deleted BEFORE the account, because budget_line.account_id is
-- ON DELETE SET NULL — dropping the account first would leave its lines
-- on the budget as orphans with no account behind them, which is worse
-- than the problem being fixed.
-- ---------------------------------------------------------------------
do $$
declare
  v_ids   bigint[] := '{}';   -- <-- e.g. '{12,17}' from STEP 1
  v_lines int;
  v_accts int;
begin
  if array_length(v_ids, 1) is null then
    raise exception 'Put the account ids from STEP 1 in v_ids first.';
  end if;

  -- Refuse to touch anything the import created, whatever was typed in.
  if exists (select 1 from budget_line l
              where l.account_id = any(v_ids) and l.amount_overridden) then
    raise exception
      'One of those accounts has imported history. It came from Finance — '
      'deactivate it instead of deleting it.';
  end if;

  delete from budget_line where account_id = any(v_ids);
  get diagnostics v_lines = row_count;

  delete from debt_detail  where account_id = any(v_ids);
  delete from debt_balance where account_id = any(v_ids);
  delete from account      where id = any(v_ids);
  get diagnostics v_accts = row_count;

  raise notice 'Removed % account(s) and % budget line(s).', v_accts, v_lines;
end $$;


-- Confirm: no orphaned lines left behind, and the candidate list is empty.
select count(*) as orphaned_lines from budget_line where account_id is null and not is_manual;
