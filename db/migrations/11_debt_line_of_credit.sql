-- =====================================================================
-- 11 — Add 'line_of_credit' to debt_kind.
--
-- Finance's DebtType table has a "Line Of Credit" row, but debt_kind was
-- written without a matching value, so the importer had nowhere to put it
-- and DEBT_TYPE quietly fell through to 'other'. income_kind already has
-- 'line_of_credit'; this brings debt_kind in line with it.
--
-- Nothing in this file USES the new value. Postgres 12+ allows
-- ALTER TYPE ... ADD VALUE inside a transaction — which is how migrate.sh
-- runs every file — only so long as the value is not referenced before
-- that transaction commits. Reclassifying existing rows therefore has to
-- happen after this file, not in it.
-- =====================================================================

alter type debt_kind add value if not exists 'line_of_credit';
