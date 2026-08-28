-- =====================================================================
-- 09 — Optional starter data.
--
-- Purpose: get the four remaining TODOs to OK in five minutes, so you can
-- log in and confirm the app works end to end BEFORE wrestling with the
-- SQL Server migration.
--
-- Skip this entirely if you're going straight to migrate.py — it imports
-- rates, accounts, lines and income from Finance and this would just be
-- extra rows to clean up.
--
-- Everything here is easy to undo (see the bottom of the file).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. A pay rate. record_paycheck() reads the rate in effect on the pay
--    date, so this has to exist before any paycheck can be recorded.
--
--    Edit the name and the numbers. Every later raise is apply_raise()
--    with a new effective_from — never an edit to this row.
-- ---------------------------------------------------------------------
select apply_raise(
  (select id from earner order by id limit 1),   -- first earner
  '2026-08-21',                                  -- effective from
  p_hourly_rate    => 77.50,
  p_standard_hours => 80,
  p_taxes_est      => 1661.38,
  p_healthcare_est => 110.62,
  p_retirement_est => 248.00,
  p_note           => 'Starting rate'
);

-- ---------------------------------------------------------------------
-- 2. A few accounts, one of each kind, so every section of the Budget
--    screen has something in it. Replace with your real ones.
-- ---------------------------------------------------------------------
select create_category('Housing');
select create_category('Utilities');
select create_category('Food');

-- A fixed monthly bill, due on the 1st.
select create_account('Mortgage', 'bill', 'monthly', 2290.82,
       (select id from category where name = 'Housing'), 1,
       p_amount_mode => 'fixed');

-- A variable monthly bill: carries forward whatever you last paid.
select create_account('Water', 'bill', 'monthly', 149.88,
       (select id from category where name = 'Utilities'), 6,
       p_amount_mode => 'carry_forward');

-- A per-paycheck expense: appears every period, amount varies.
select create_account('Groceries', 'expense', 'per_paycheck', 300,
       (select id from category where name = 'Food'));

-- Savings.
select create_account('Emergency Fund', 'saving', 'per_paycheck', 200,
       p_amount_mode => 'fixed');

-- A credit card, with its limit, rate and current balance.
-- APR can be typed either way: 13.09 or 0.1309.
select create_account('Visa', 'debt', 'monthly', 561,
       null, 25,
       p_debt_type       => 'credit_card',
       p_credit_limit    => 19000,
       p_apr             => 13.09,
       p_minimum_payment => 561,
       p_opening_balance => 15554.77);

-- ---------------------------------------------------------------------
-- 3. A paycheck for the current period. Rate, taxes, healthcare and 401k
--    all come from the wage_rate above.
-- ---------------------------------------------------------------------
select record_paycheck(
  (select id from earner order by id limit 1),
  (select id from budget_period where period_start = '2026-08-21')
);

-- ---------------------------------------------------------------------
-- 4. Build the lines and price them.
-- ---------------------------------------------------------------------
select refresh_household_amounts(id) from household;

-- ---------------------------------------------------------------------
-- 5. What the app will show you.
-- ---------------------------------------------------------------------
select period_start, wage_income, bills_due, expenses_due, debts_due,
       savings_due, total_due, projected_balance
from v_period_summary
order by period_start
limit 3;

select name, kind, due_date, amount_due, status
from budget_line
where budget_period_id = (select id from budget_period where period_start = '2026-08-21')
order by kind, name;


-- =====================================================================
-- UNDO — wipes the starter data, leaves logins, household and periods.
-- Run this before migrate.py if you seeded first and then changed
-- your mind.
-- =====================================================================
-- delete from budget_line;
-- delete from income;
-- delete from debt_balance;
-- delete from debt_detail;
-- delete from account;
-- delete from wage_rate;
-- delete from category;
