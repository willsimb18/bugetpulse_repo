-- =====================================================================
-- Pre-flight for the PRODUCTION SQL Server import. Read-only — this
-- writes nothing. Run it against prod and read every section before
-- exporting HOUSEHOLD_ID and running import_from_sqlserver.py.
--
-- The dev rehearsal proved the transform works. What it could not prove
-- is how the import lands on a database that already has rows in it,
-- which is what prod is.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. HOUSEHOLD_ID for the import. Every Supabase project mints its own,
--    so the dev value will silently do nothing here.
-- ---------------------------------------------------------------------
select id as household_id, name, base_frequency, timezone
from household;


-- ---------------------------------------------------------------------
-- 2. THE ONE THAT BITES. The import keys earners on
--    (household_id, display_name) taken from users.FirstName.
--
--    Compare exact_spelling below, character for character, against:
--        select UserId, FirstName, UserName from [users];
--    on SQL Server.
--
--    Any difference — nickname, capitalisation, a trailing space —
--    creates a SECOND earner per person instead of merging. Rename these
--    to match BEFORE importing; merge_earners.sql is the cleanup if you
--    find out afterwards.
-- ---------------------------------------------------------------------
select id,
       '[' || display_name || ']' as exact_spelling,
       profile_id is not null     as linked_to_login,
       pay_anchor,
       (select count(*) from wage_rate w where w.earner_id = earner.id) as wage_rates
from earner
order by id;


-- ---------------------------------------------------------------------
-- 3. Accounts already here. The import upserts on
--    (household_id, name, kind) and overwrites default_amount, so a
--    hand-made account whose name matches one in Finance is repriced
--    without warning.
-- ---------------------------------------------------------------------
select kind, count(*) as accounts
from account
group by kind
order by kind;

select kind, name, default_amount, frequency, due_day, anchor_date, is_always_due
from account
order by kind, name;


-- ---------------------------------------------------------------------
-- 4. History already here. The import adds to this; it never clears it.
--    Anything above zero means you are loading on top of existing data
--    and the totals afterwards will be the sum of both.
-- ---------------------------------------------------------------------
select 'budget_line'   as table_name, count(*) from budget_line
union all select 'income',        count(*) from income
union all select 'budget_period', count(*) from budget_period
union all select 'wage_rate',     count(*) from wage_rate
union all select 'category',      count(*) from category
union all select 'debt_detail',   count(*) from debt_detail;


-- ---------------------------------------------------------------------
-- 5. Migration ledger. All eight files should be listed, or the schema
--    the import expects may not be fully in place.
-- ---------------------------------------------------------------------
select filename, applied_at::date as applied
from schema_migrations
order by filename;
