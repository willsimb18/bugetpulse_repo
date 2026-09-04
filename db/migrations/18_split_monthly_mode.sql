-- =====================================================================
-- 18 — Add the 'split_monthly' amount mode.
--
-- The old spreadsheet budgeted the mortgage across the paychecks in a
-- month rather than all at once: BudgetAmount held the month's figure
-- (4,491.90), each paycheck put roughly half against it, and isPaid only
-- fired when the payments reached the month's total. Nothing here does
-- that -- a monthly bill materialises once, at its full amount, in
-- whichever period contains its due day. That makes one fortnight look
-- ruinous and the next look easy.
--
-- Migration 19 teaches materialize_period and next_amount_for what to do
-- with it. This file only adds the value, because Postgres allows
-- ALTER TYPE ... ADD VALUE inside a transaction only while the new value
-- goes unreferenced until that transaction commits -- and migrate.sh runs
-- each file in one.
-- =====================================================================

alter type amount_mode add value if not exists 'split_monthly';
