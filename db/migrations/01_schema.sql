-- =====================================================================
-- Household Budget App — schema v2 (merged with Finance DDL)
-- Target: Supabase (PostgreSQL 15+)
-- Run order: 01_schema -> 02_functions -> 03_rls -> 04_views
--
-- WHAT CHANGED FROM v1 (see REVIEW.md for the reasoning):
--   * Bills + Expenses + SavingAccounts + Debts collapse into ONE
--     `account` table with a `kind` discriminator. This kills the
--     polymorphic Budget.AccountId, which is the most serious bug in
--     the current design.
--   * Expenses are first-class: frequency 'per_paycheck', amount varies
--     every period, carried on budget_line not on the catalog row.
--   * Wages + BudgetIncome collapse into `income` (no repeating groups).
--   * `is_always_due` replaces the hardcoded account-name list baked
--     into vw_BI_WeeklyBudget.
--   * Pay calendar is a table, not derived from MAX(PayDate).
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- Enumerated domains
-- ---------------------------------------------------------------------

-- 'per_paycheck' is the Expenses cadence: appears every period, amount
-- entered fresh each time. AccountFrequencies.Frequence 'N/A' maps here.
create type frequency as enum (
  'per_paycheck','weekly','biweekly','semimonthly','monthly',
  'quarterly','semiannual','annual','one_time'
);

-- Replaces the isBill/isExpenses/isSaving/isDebt flag quartet, which
-- could be all-true or all-false. Matches the AccountType legend in
-- sp_AddBillsToBudget: 1-Bill, 2-Debts, 3-Savings, 4-Expenses.
create type account_kind as enum ('bill','debt','saving','expense');

-- How a period's amount_due is decided when a line is materialized.
--
--   carry_forward     - use the last settled amount for this account;
--                       fall back to default_amount if there's no history.
--                       This is the Excel rule:
--                         IF(LastPaidAmount > 0, LastPaidAmount, BudgetAmount)
--   fixed             - always default_amount, ignore history.
--   percent_of_income - a share of the period's net income. Replaces the
--                       hardcoded Tithes branch: SUM(Wages[Net]) * 0.1
create type amount_mode as enum ('carry_forward','fixed','percent_of_income');

-- PayType + IncomeType merged, plus the funding sources that let a period
-- balance when the paychecks alone don't cover it. 'from_savings' and
-- 'line_of_credit' are money moved IN, not earned — v_period_summary keeps
-- them separate from wages so you can always see how much of a period was
-- actually covered by pay.
create type income_kind as enum (
  'regular','overtime','pto','holiday','bonus','commission',
  'deposit','tax_refund','from_savings','line_of_credit','other'
);


create type debt_kind as enum (
  'credit_card','auto_loan','mortgage','personal_loan','student_loan','other'
);

create type household_role as enum ('owner','member');

create type line_status as enum ('scheduled','paid','partial','skipped');

-- ---------------------------------------------------------------------
-- Household & membership
-- ---------------------------------------------------------------------
create table household (
  id             uuid primary key default gen_random_uuid(),
  name           text not null,
  base_frequency frequency not null default 'biweekly',
  timezone       text not null default 'America/New_York',
  created_at     timestamptz not null default now()
);

create table profile (
  id           uuid primary key references auth.users(id) on delete cascade,
  household_id uuid not null references household(id) on delete cascade,
  display_name text not null,
  role         household_role not null default 'member',
  created_at   timestamptz not null default now()
);
create index on profile (household_id);

-- ---------------------------------------------------------------------
-- Category taxonomy  (CategoryType, self-referencing parent/child)
-- Kept as an adjacency list like yours, but with a real FK and a guard
-- against two-level nesting, which vw_CategoryType silently assumes.
-- ---------------------------------------------------------------------
create table category (
  id             bigint generated always as identity primary key,
  household_id   uuid not null references household(id) on delete cascade,
  name           text not null,
  parent_id      bigint references category(id) on delete restrict,
  description    text,
  legacy_type_id int,                        -- CategoryType.TypeId
  is_income      boolean not null default false,
  sort_order     int not null default 0,
  created_at     timestamptz not null default now()
);
create unique index category_uq
  on category (household_id, name, parent_id) nulls not distinct;
create index on category (household_id);
create index on category (parent_id);

-- ---------------------------------------------------------------------
-- Earners  (Users + Wages.isCurrent)
-- ---------------------------------------------------------------------
create table earner (
  id             bigint generated always as identity primary key,
  household_id   uuid not null references household(id) on delete cascade,
  display_name   text not null,
  profile_id     uuid references profile(id) on delete set null,
  pay_frequency  frequency not null default 'biweekly',
  pay_anchor     date,
  num_dependents int not null default 0,
  is_active      boolean not null default true,
  created_at     timestamptz not null default now(),
  unique (household_id, display_name)
);
create index on earner (household_id);
-- One earner per login. Without this, renaming someone creates a second
-- earner instead of renaming the existing one. Partial, because an earner
-- can exist without a login (imported from Users, no account yet).
create unique index earner_one_per_profile
  on earner (household_id, profile_id) where profile_id is not null;

-- ---------------------------------------------------------------------
-- wage_rate — effective-dated pay rates.
--
-- Wages.isCurrent = 1 keeps exactly one row per person, so a raise
-- overwrites the old rate and historical checks lose the rate that
-- produced them. Here a raise is a NEW ROW with an effective_from date;
-- nothing is ever overwritten, and rate_on(earner, date) answers "what
-- were they earning that week" for any point in the past.
-- ---------------------------------------------------------------------
create table wage_rate (
  id              bigint generated always as identity primary key,
  household_id    uuid not null references household(id) on delete cascade,
  earner_id       bigint not null references earner(id) on delete cascade,
  effective_from  date not null,
  hourly_rate     numeric(12,4),
  annual_salary   numeric(12,2),
  standard_hours  numeric(8,2) default 80,      -- hours per pay period
  -- Typical deductions, used to pre-fill a new paycheck. Actuals still
  -- live on the income row.
  taxes_est       numeric(12,2) not null default 0,
  healthcare_est  numeric(12,2) not null default 0,
  retirement_est  numeric(12,2) not null default 0,
  employer        text,
  note            text,                          -- 'Annual merit 4%'
  created_at      timestamptz not null default now(),
  unique (earner_id, effective_from),
  constraint rate_or_salary check (hourly_rate is not null or annual_salary is not null)
);
create index on wage_rate (household_id);
create index on wage_rate (earner_id, effective_from desc);

-- ---------------------------------------------------------------------
-- Budget periods — the pay calendar as DATA
--
-- Replaces CTE_LastPayDate, which derived LastPayDate /
-- CurrentPayCheckDate / NextPayCheckDate from MAX(PayDate) with nested
-- CASE and hardcoded DATEADD(WEEK,2,...). That made bi-weekly the only
-- possible cadence and meant the calendar didn't exist until a Budget
-- row did.
-- ---------------------------------------------------------------------
create table budget_period (
  id              bigint generated always as identity primary key,
  household_id    uuid not null references household(id) on delete cascade,
  period_start    date not null,
  period_end      date not null,
  pay_date        date not null,
  frequency       frequency not null,
  label           text,
  is_closed       boolean not null default false,
  opening_balance numeric(12,2) not null default 0,  -- LastPayCheckRemBal
  notes           text,
  created_at      timestamptz not null default now(),
  constraint period_order check (period_end >= period_start),
  unique (household_id, period_start, frequency)
);
create index on budget_period (household_id, pay_date desc);

-- ---------------------------------------------------------------------
-- Income  (Wages + BudgetIncome, normalized)
--
-- BudgetIncome had IncomeTypeID/Amount, IncomeType2ID/OtherAmount,
-- IncomeType3ID/OtherAmount2 — a repeating group capped at three
-- sources, with no primary key. One row per income event instead.
-- ---------------------------------------------------------------------
create table income (
  id               bigint generated always as identity primary key,
  household_id     uuid not null references household(id) on delete cascade,
  earner_id        bigint references earner(id) on delete set null,
  budget_period_id bigint references budget_period(id) on delete set null,
  received_on      date not null,
  kind             income_kind not null default 'regular',
  -- Wage rows use rate x hours; bonuses/deposits/refunds use the override.
  hourly_rate      numeric(12,4),
  hours            numeric(8,2),
  gross_override   numeric(12,2),
  taxes            numeric(12,2) not null default 0,
  healthcare       numeric(12,2) not null default 0,
  retirement       numeric(12,2) not null default 0,   -- 401K
  other_deductions numeric(12,2) not null default 0,
  gross numeric(12,2) generated always as (
    coalesce(gross_override, round(coalesce(hourly_rate,0) * coalesce(hours,0), 2))
  ) stored,
  net numeric(12,2) generated always as (
    coalesce(gross_override, round(coalesce(hourly_rate,0) * coalesce(hours,0), 2))
    - taxes - healthcare - retirement - other_deductions
  ) stored,
  -- For from_savings / line_of_credit: which account the money came out of,
  -- so a transfer is traceable to the savings or credit account it drained.
  -- FK added after `account` is created (see below) — income is declared
  -- first because budget_period/earner order reads better that way.
  source_account_id bigint,
  notes      text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on income (household_id, received_on desc);
create index on income (budget_period_id);
create index on income (earner_id, received_on desc);

-- ---------------------------------------------------------------------
-- ACCOUNT — the unified catalog.
--
-- One table for what Finance splits across Bills, Expenses,
-- SavingAccounts, and Debts. Budget.AccountId pointed into whichever of
-- those four the Is* flags implied, with four independent IDENTITY
-- sequences and no discriminator on the history join — so BillId 3 and
-- ExpenseID 3 sharing a CategoryTypeId collided silently. A single
-- table makes budget_line.account_id a real, enforceable FK.
-- ---------------------------------------------------------------------
create table account (
  id              bigint generated always as identity primary key,
  household_id    uuid not null references household(id) on delete cascade,
  name            text not null,                       -- BillName / ExpenseName / Account
  kind            account_kind not null,
  category_id     bigint references category(id) on delete set null,
  frequency       frequency not null default 'monthly',
  -- Fallback / starting amount. Whether it is actually used depends on
  -- amount_mode below — for a carry_forward account it only applies when
  -- there is no prior history to carry.
  default_amount  numeric(12,2) not null default 0,
  amount_mode     amount_mode not null default 'carry_forward',
  -- For percent_of_income: 0.10 = 10% of the period's net income.
  amount_percent  numeric(6,4) check (amount_percent >= 0 and amount_percent <= 1),
  -- Informational only: when the catalog amount was last changed by hand.
  -- Shown in v_account_admin; deliberately NOT used in amount resolution.
  amount_set_on   date not null default current_date,
  -- Scheduling: monthly+ uses due_day; weekly/biweekly uses anchor_date;
  -- semimonthly uses both due_days; per_paycheck uses the period pay_date.
  due_day         smallint check (due_day between 1 and 31),
  due_day_2       smallint check (due_day_2 between 1 and 31),
  due_month       smallint check (due_month between 1 and 12),  -- annual
  anchor_date     date,
  -- Replaces CTE_AlwaysDueList, which hardcoded 'Ford F-150', '4Runner',
  -- 'BOA (Willes)', 'Mortgage', etc. directly in the view.
  is_always_due   boolean not null default false,
  owner_earner_id bigint references earner(id) on delete set null,
  is_variable     boolean not null default false,      -- amount is an estimate
  is_autopay      boolean not null default false,
  is_active       boolean not null default true,       -- Bills.isActive
  notes           text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (household_id, name, kind),
  constraint pct_needs_value check (
    amount_mode <> 'percent_of_income' or amount_percent is not null
  ),
  constraint account_schedule_present check (
    frequency in ('per_paycheck','one_time')
    or due_day is not null
    or anchor_date is not null
    or is_always_due
  )
);
create index on account (household_id, kind) where is_active;
create index on account (household_id, frequency);

-- Debt-specific attributes. 1:1 extension of account, so a debt is still
-- one account row and budget_line still has a single FK target.
create table debt_detail (
  account_id         bigint primary key references account(id) on delete cascade,
  household_id       uuid not null references household(id) on delete cascade,
  debt_type          debt_kind not null default 'credit_card',
  credit_limit       numeric(12,2),          -- Debts.CreditAmount
  -- Stored as a FRACTION (0.1309 = 13.09%). Finance stored whole percent
  -- in decimal(5,2) and divided by 100 in vw_Debts.
  apr                numeric(6,4) check (apr >= 0 and apr < 2),
  minimum_payment    numeric(12,2),          -- MonthlyPaymentAmount
  target_utilization numeric(5,4) default 0.30,
  opened_on          date
);
create index on debt_detail (household_id);

-- Balance snapshots. Debts has no balance column at all — current
-- balance lived only in the workbook, so payoff progress had no history.
create table debt_balance (
  id           bigint generated always as identity primary key,
  household_id uuid not null references household(id) on delete cascade,
  account_id   bigint not null references account(id) on delete cascade,
  as_of        date not null,
  balance      numeric(12,2) not null,
  created_at   timestamptz not null default now(),
  unique (account_id, as_of)
);
create index on debt_balance (household_id, account_id, as_of desc);

-- ---------------------------------------------------------------------
alter table income
  add constraint income_source_account_fk
  foreign key (source_account_id) references account(id) on delete set null;
create index on income (source_account_id);

-- ---------------------------------------------------------------------
-- BUDGET_LINE — one account occurrence in one period.
-- Replaces dbo.Budget. This is the table your wife writes to.
-- ---------------------------------------------------------------------
create table budget_line (
  id               bigint generated always as identity primary key,
  household_id     uuid not null references household(id) on delete cascade,
  budget_period_id bigint not null references budget_period(id) on delete cascade,
  account_id       bigint references account(id) on delete set null,
  -- Snapshots so history survives a rename or a deactivated account.
  name             text not null,
  category_id      bigint references category(id) on delete set null,
  kind             account_kind not null default 'bill',
  due_date         date not null,
  -- THE per-period amount. For expenses this differs every paycheck and
  -- is the whole point; account.default_amount is only the starting value.
  amount_due       numeric(12,2) not null default 0,
  -- TRUE once a human has typed a figure into this line. Automatic
  -- repricing (carry-forward, percent-of-income, the nightly refresh)
  -- must never overwrite an overridden line — the line is the source of
  -- truth, exactly like editing the Budget tab.
  amount_overridden boolean not null default false,
  amount_paid      numeric(12,2) not null default 0,
  status           line_status not null default 'scheduled',
  paid_on          date,
  paid_by          uuid references profile(id) on delete set null,
  -- Funds set aside now for a bill paid later (Budget.FundsHeld).
  -- Finance carried BOTH FundsHeldAmount and FundsOnHoldAmt; the view
  -- read only one of them. Collapsed to a single column.
  funds_held       boolean not null default false,
  funds_held_amount numeric(12,2) not null default 0,
  funds_held_until date,                     -- FundsHeldUpToDate
  from_savings     numeric(12,2) not null default 0,
  is_manual        boolean not null default false,
  notes            text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint paid_needs_date check (status <> 'paid' or paid_on is not null),
  constraint amount_paid_nonneg check (amount_paid >= 0),
  constraint funds_held_needs_date check (not funds_held or funds_held_until is not null)
);
create unique index budget_line_uq
  on budget_line (budget_period_id, account_id, due_date)
  where account_id is not null;
create index on budget_line (household_id, budget_period_id);
create index on budget_line (household_id, due_date) where status <> 'paid';
create index on budget_line (household_id, kind);
create index on budget_line (account_id, due_date desc);

-- ---------------------------------------------------------------------
-- Banks & imported transactions  (Banks, EStatements)
-- ---------------------------------------------------------------------
create table bank (
  id           bigint generated always as identity primary key,
  household_id uuid not null references household(id) on delete cascade,
  name         text not null,
  unique (household_id, name)
);

create table statement_txn (
  id             bigint generated always as identity primary key,
  household_id   uuid not null references household(id) on delete cascade,
  bank_id        bigint references bank(id) on delete set null,
  statement_date date,
  txn_date       date not null,
  description    text,
  amount         numeric(12,2) not null,   -- negative = outflow
  category_id    bigint references category(id) on delete set null,
  account_ref    text,                     -- last4 or nickname ONLY
  account_type   text,
  external_id    text,                     -- dedupe key
  budget_line_id bigint references budget_line(id) on delete set null,
  imported_at    timestamptz not null default now()
);
create unique index statement_txn_dedupe
  on statement_txn (household_id, external_id) where external_id is not null;
create index on statement_txn (household_id, txn_date desc);

-- Auto-categorization rules  (KeywordsCategoryMapping)
create table category_keyword (
  id           bigint generated always as identity primary key,
  household_id uuid not null references household(id) on delete cascade,
  keyword      text not null,
  category_id  bigint not null references category(id) on delete cascade,
  priority     int not null default 0,
  unique (household_id, keyword)
);

-- ---------------------------------------------------------------------
-- Audit trail
-- ---------------------------------------------------------------------
create table audit_log (
  id           bigint generated always as identity primary key,
  household_id uuid,
  actor        uuid,
  table_name   text not null,
  row_id       text,
  action       text not null,
  old_row      jsonb,
  new_row      jsonb,
  changed_at   timestamptz not null default now()
);
create index on audit_log (household_id, changed_at desc);
