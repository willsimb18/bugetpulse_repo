-- =====================================================================
-- 20 — Harden the duplicate-account rule.
--
-- account already carries unique (household_id, name, kind), so an exact
-- repeat cannot be inserted. Two gaps sat behind it.
--
-- IT WAS CASE AND SPACING SENSITIVE. The index is on the raw name, so
-- "Mortgage", "mortgage" and "MORTGAGE" are three different accounts,
-- each getting its own budget line every period. create_account btrims,
-- but nothing folds case.
--
-- AND A DUPLICATE WAS SILENTLY A WRITE. create_account ended in
--   on conflict (household_id, name, kind) do update
--     set is_active = true, default_amount = excluded.default_amount
-- so adding "Mortgage" a second time did not fail — it repriced the
-- existing account to whatever amount was in the form and switched it
-- back on. You would think you had added something; you had quietly
-- changed something, possibly one that was deactivated on purpose.
--
-- Now it refuses and says which account it clashed with. The two things
-- the upsert used to do both have their own explicit paths already:
-- reactivate_account() for switching one back on, update_account_amount()
-- for repricing. Neither should happen by accident from an add form.
-- =====================================================================

create or replace function create_account(
  p_name            text,
  p_kind            account_kind,
  p_frequency       frequency default 'monthly',
  p_amount          numeric default 0,
  p_category_id     bigint default null,
  p_due_day         int default null,
  p_due_day_2       int default null,
  p_due_month       int default null,
  p_anchor_date     date default null,
  p_always_due      boolean default false,
  p_amount_mode     amount_mode default 'carry_forward',
  p_amount_percent  numeric default null,
  p_owner_earner_id bigint default null,
  p_is_variable     boolean default false,
  p_autopay         boolean default false,
  p_notes           text default null,
  -- debts only
  p_debt_type       debt_kind default 'credit_card',
  p_credit_limit    numeric default null,
  p_apr             numeric default null,
  p_minimum_payment numeric default null,
  p_opening_balance numeric default null
) returns account
language plpgsql security invoker
set search_path = public, pg_temp as $$
declare
  rec account;
  dup account;
  hh  uuid;
  pid bigint;
begin
  perform require_owner();
  -- In the SQL Editor there is no session, so fall back to the household.
  -- Harmless: this app is single-household per project.
  hh := coalesce(app_household_id(), (select id from household limit 1));
  if hh is null then
    raise exception 'No household exists yet. Run 06_bootstrap.sql first.';
  end if;

  if p_name is null or btrim(p_name) = '' then
    raise exception 'This needs a name';
  end if;

  -- Fail with something readable rather than letting the check constraint
  -- fire, because "account_schedule_present" means nothing to a user.
  if p_frequency in ('monthly','quarterly','semiannual','annual','semimonthly')
     and p_due_day is null and not p_always_due then
    raise exception 'A % bill needs a day of the month it is due on', p_frequency;
  end if;
  if p_frequency in ('weekly','biweekly','one_time')
     and p_anchor_date is null and not p_always_due then
    raise exception 'A % bill needs a starting date to count from', p_frequency;
  end if;
  if p_amount_mode = 'percent_of_income' and p_amount_percent is null then
    raise exception 'Percent of income needs a percentage (0.10 = 10%%)';
  end if;

  -- Already have one of these, however it was capitalised?
  select * into dup
  from account
  where household_id = hh
    and kind = p_kind
    and lower(btrim(name)) = lower(btrim(p_name))
  limit 1;

  if found then
    raise exception
      '% "%" already exists%. Reprice it from the Bills tab, or switch it '
      'back on there if it is stopped.',
      initcap(p_kind::text), dup.name,
      case when dup.is_active then '' else ' (currently stopped)' end
      using errcode = 'unique_violation';
  end if;

  insert into account (
    household_id, name, kind, category_id, frequency, default_amount,
    amount_mode, amount_percent, due_day, due_day_2, due_month, anchor_date,
    is_always_due, owner_earner_id, is_variable, is_autopay, notes
  ) values (
    hh, btrim(p_name), p_kind, p_category_id, p_frequency, coalesce(p_amount, 0),
    p_amount_mode, p_amount_percent, p_due_day, p_due_day_2, p_due_month, p_anchor_date,
    coalesce(p_always_due, false), p_owner_earner_id,
    coalesce(p_is_variable, false), coalesce(p_autopay, false), p_notes
  )
  returning * into rec;

  if p_kind = 'debt' then
    insert into debt_detail (account_id, household_id, debt_type,
                             credit_limit, apr, minimum_payment)
    values (rec.id, hh, coalesce(p_debt_type, 'credit_card'),
            p_credit_limit,
            -- Accept either 13.09 or 0.1309 and store the fraction. People
            -- type the percentage; the old Debts table stored whole percent.
            case when p_apr is null then null
                 when p_apr > 1     then p_apr / 100
                 else p_apr end,
            coalesce(p_minimum_payment, p_amount))
    on conflict (account_id) do update
      set debt_type       = excluded.debt_type,
          credit_limit    = excluded.credit_limit,
          apr             = excluded.apr,
          minimum_payment = excluded.minimum_payment;

    if p_opening_balance is not null then
      insert into debt_balance (household_id, account_id, as_of, balance)
      values (hh, rec.id, current_date, p_opening_balance)
      on conflict (account_id, as_of) do update set balance = excluded.balance;
    end if;
  end if;

  -- Put it on the budget straight away.
  for pid in
    select id from budget_period
    where household_id = hh and not is_closed and period_end >= current_date
    order by period_start
  loop
    perform materialize_period(pid);
  end loop;

  return rec;
end $$;


-- ---------------------------------------------------------------------
-- The case-insensitive backstop, for anything not going through
-- create_account. Only added if the data will take it — the import may
-- already have brought across names that differ only in case.
-- ---------------------------------------------------------------------
do $$
declare n int;
begin
  select count(*) into n from (
    select 1 from account
    group by household_id, lower(btrim(name)), kind
    having count(*) > 1
  ) d;

  if n > 0 then
    raise notice
      'Not adding the case-insensitive index: % name(s) already differ only by '
      'case or spacing. List them with db/optional/find_duplicate_accounts.sql, '
      'merge or rename them, then re-run this file.', n;
    return;
  end if;

  create unique index if not exists account_one_per_name_kind_ci
    on account (household_id, lower(btrim(name)), kind);

  raise notice 'Case-insensitive unique index added on (household, name, kind).';
end $$;
