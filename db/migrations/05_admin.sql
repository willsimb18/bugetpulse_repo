-- =====================================================================
-- 05 — Admin / back-office operations
--
-- These are the "not often, but I need to" operations: raises, a bill
-- going up, a bill going away, fixing a record that was entered wrong.
--
-- Every one of them is OWNER-ONLY and writes to audit_log. None of them
-- requires opening a SQL console — call them as Supabase RPCs from an
-- admin screen in the app.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Guard used by every function in this file.
-- ---------------------------------------------------------------------
create or replace function require_owner()
returns void language plpgsql stable as $$
begin
  if not app_is_owner() then
    raise exception 'This operation requires the owner role'
      using errcode = '42501';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- log_correction() — the only path from a client into audit_log.
--
-- The correction functions below are SECURITY INVOKER on purpose, so RLS
-- still decides which rows the caller can touch. But `authenticated` has
-- no INSERT grant on audit_log (by design — the trail must not be
-- client-writable), so the audit write has to hop through a definer
-- function. This one appends only; it cannot update or delete.
-- ---------------------------------------------------------------------
create or replace function log_correction(
  p_household uuid,
  p_table     text,
  p_row_id    text,
  p_action    text,
  p_old       jsonb default null,
  p_new       jsonb default null
) returns void
language plpgsql security definer
set search_path = public, pg_temp as $$
begin
  -- Never log for a household the caller isn't in.
  if p_household is distinct from app_household_id() then
    raise exception 'Cannot write an audit entry for another household'
      using errcode = '42501';
  end if;

  insert into audit_log (household_id, actor, table_name, row_id, action, old_row, new_row)
  values (p_household, auth.uid(), p_table, p_row_id, p_action, p_old, p_new);
end $$;

-- =====================================================================
-- WAGES
-- =====================================================================

-- ---------------------------------------------------------------------
-- rate_on() — what was this person earning on a given date?
-- The row with the latest effective_from that is <= the date.
-- ---------------------------------------------------------------------
create or replace function rate_on(p_earner_id bigint, p_date date)
returns wage_rate language sql stable
set search_path = public, pg_temp as $$
  select * from wage_rate
  where earner_id = p_earner_id
    and effective_from <= p_date
  order by effective_from desc
  limit 1;
$$;

-- ---------------------------------------------------------------------
-- apply_raise() — record a new pay rate from a date forward.
--
-- Historical income rows are NOT touched: they keep the rate that was
-- actually paid. Only checks created after this take the new rate.
--
-- Passing an effective_from that already exists updates that row instead
-- of erroring, so a mistyped raise is easy to correct.
-- ---------------------------------------------------------------------
create or replace function apply_raise(
  p_earner_id      bigint,
  p_effective_from date,
  p_hourly_rate    numeric default null,
  p_annual_salary  numeric default null,
  p_standard_hours numeric default null,
  p_taxes_est      numeric default null,
  p_healthcare_est numeric default null,
  p_retirement_est numeric default null,
  p_note           text    default null
) returns wage_rate
language plpgsql security invoker
set search_path = public, pg_temp as $$
declare
  prev wage_rate;
  rec  wage_rate;
  hh   uuid;
begin
  perform require_owner();

  select household_id into hh from earner where id = p_earner_id;
  if hh is null then
    raise exception 'earner % not found or not visible', p_earner_id;
  end if;

  -- Carry forward anything not supplied, so a rate-only raise doesn't
  -- silently zero out the deduction estimates.
  prev := rate_on(p_earner_id, p_effective_from);

  insert into wage_rate (
    household_id, earner_id, effective_from, hourly_rate, annual_salary,
    standard_hours, taxes_est, healthcare_est, retirement_est, note
  ) values (
    hh, p_earner_id, p_effective_from,
    coalesce(p_hourly_rate,    prev.hourly_rate),
    coalesce(p_annual_salary,  prev.annual_salary),
    coalesce(p_standard_hours, prev.standard_hours, 80),
    coalesce(p_taxes_est,      prev.taxes_est,      0),
    coalesce(p_healthcare_est, prev.healthcare_est, 0),
    coalesce(p_retirement_est, prev.retirement_est, 0),
    p_note
  )
  on conflict (earner_id, effective_from) do update
    set hourly_rate    = excluded.hourly_rate,
        annual_salary  = excluded.annual_salary,
        standard_hours = excluded.standard_hours,
        taxes_est      = excluded.taxes_est,
        healthcare_est = excluded.healthcare_est,
        retirement_est = excluded.retirement_est,
        note           = excluded.note
  returning * into rec;

  return rec;
end $$;

-- ---------------------------------------------------------------------
-- record_paycheck() — create an income row pre-filled from the rate that
-- was in effect on the check date. Override any field explicitly.
-- ---------------------------------------------------------------------
create or replace function record_paycheck(
  p_earner_id  bigint,
  p_period_id  bigint,
  p_check_date date default null,
  p_hours      numeric default null,
  p_kind       income_kind default 'regular',
  p_taxes      numeric default null,
  p_healthcare numeric default null,
  p_retirement numeric default null,
  p_gross_override numeric default null
) returns income
language plpgsql security invoker
set search_path = public, pg_temp as $$
declare
  per budget_period;
  wr  wage_rate;
  d   date;
  rec income;
begin
  perform require_owner();

  select * into per from budget_period where id = p_period_id;
  if not found then raise exception 'budget_period % not visible', p_period_id; end if;

  d  := coalesce(p_check_date, per.pay_date);
  wr := rate_on(p_earner_id, d);

  if wr.id is null and p_gross_override is null then
    raise exception 'No wage rate on file for earner % as of %. Call apply_raise() first.',
      p_earner_id, d;
  end if;

  insert into income (
    household_id, earner_id, budget_period_id, received_on, kind,
    hourly_rate, hours, gross_override, taxes, healthcare, retirement
  ) values (
    per.household_id, p_earner_id, per.id, d, p_kind,
    case when p_gross_override is null then wr.hourly_rate end,
    case when p_gross_override is null then coalesce(p_hours, wr.standard_hours) end,
    p_gross_override,
    coalesce(p_taxes,      case when p_gross_override is null then wr.taxes_est      else 0 end),
    coalesce(p_healthcare, case when p_gross_override is null then wr.healthcare_est else 0 end),
    coalesce(p_retirement, case when p_gross_override is null then wr.retirement_est else 0 end)
  ) returning * into rec;

  return rec;
end $$;

-- ---------------------------------------------------------------------
-- add_funds() — money into a period that isn't a paycheck.
--
-- Covers the FromSavings / Bonuses / LineOfCredit columns from the old
-- Budget History: pulling from savings, drawing on a credit line, or
-- dropping a bonus in to make a heavy period balance.
--
-- p_from_account_id is optional but worth setting for from_savings and
-- line_of_credit — it records WHICH savings pot or credit line the money
-- came out of, and for a credit line it also grows that debt's balance so
-- your payoff numbers stay true.
-- ---------------------------------------------------------------------
create or replace function add_funds(
  p_period_id       bigint,
  p_kind            income_kind,
  p_amount          numeric,
  p_from_account_id bigint default null,
  p_received_on     date default null,
  p_note            text default null
) returns income
language plpgsql security invoker
set search_path = public, pg_temp as $$
declare
  per budget_period;
  rec income;
  cur_bal numeric(12,2);
  d date;
begin
  perform require_owner();

  if p_amount is null or p_amount <= 0 then
    raise exception 'Amount must be greater than zero';
  end if;
  if is_wage(p_kind) then
    raise exception 'Use record_paycheck() for wages; add_funds() is for '
                    'bonuses, savings draws, and credit line draws';
  end if;

  select * into per from budget_period where id = p_period_id;
  if not found then raise exception 'budget_period % not visible', p_period_id; end if;
  if per.is_closed then raise exception 'budget_period % is closed', p_period_id; end if;

  d := coalesce(p_received_on, per.pay_date);

  insert into income (household_id, budget_period_id, received_on, kind,
                      gross_override, source_account_id, notes)
  values (per.household_id, per.id, d, p_kind, p_amount, p_from_account_id, p_note)
  returning * into rec;

  -- Drawing on a credit line increases what you owe on it.
  if p_kind = 'line_of_credit' and p_from_account_id is not null then
    select balance into cur_bal from debt_balance
     where account_id = p_from_account_id order by as_of desc limit 1;

    insert into debt_balance (household_id, account_id, as_of, balance)
    values (per.household_id, p_from_account_id, d, coalesce(cur_bal, 0) + p_amount)
    on conflict (account_id, as_of) do update
      set balance = debt_balance.balance + p_amount;
  end if;

  return rec;
end $$;

-- Undo a funding entry (and roll back the credit-line balance it added).
create or replace function remove_funds(p_income_id bigint)
returns void
language plpgsql security invoker
set search_path = public, pg_temp as $$
declare rec income;
begin
  perform require_owner();
  select * into rec from income where id = p_income_id;
  if not found then raise exception 'income % not visible', p_income_id; end if;
  if is_wage(rec.kind) then
    raise exception 'Use correct_income() for paychecks';
  end if;

  if rec.kind = 'line_of_credit' and rec.source_account_id is not null then
    update debt_balance
       set balance = balance - coalesce(rec.gross_override, 0)
     where account_id = rec.source_account_id and as_of = rec.received_on;
  end if;

  delete from income where id = p_income_id;
end $$;

-- =====================================================================
-- BILLS & ACCOUNTS
-- =====================================================================

-- ---------------------------------------------------------------------
-- update_account_amount() — a bill went up.
--
-- p_apply_to_open decides the hard part: does the increase hit periods
-- already on screen, or only future ones? Default is future-only, and
-- ALREADY-PAID lines are never touched under either setting — changing
-- the amount on something you already paid would corrupt history.
-- ---------------------------------------------------------------------
create or replace function update_account_amount(
  p_account_id    bigint,
  p_new_amount    numeric,
  p_apply_to_open boolean default true,
  p_note          text default null
) returns table (account_id bigint, new_amount numeric, lines_updated int)
language plpgsql security invoker
set search_path = public, pg_temp as $$
declare
  n int := 0;
begin
  perform require_owner();
  if p_new_amount < 0 then raise exception 'Amount cannot be negative'; end if;

  -- p_apply_to_open defaults TRUE because for a carry_forward account
  -- that is the only way a rate change takes effect: the next period
  -- carries whatever the previous line ended up at.
  update account
     set default_amount = p_new_amount,
         amount_set_on  = current_date,
         notes = coalesce(p_note, notes)
   where id = p_account_id;

  if not found then
    raise exception 'account % not found or not visible', p_account_id;
  end if;

  if p_apply_to_open then
    update budget_line l
       set amount_due = p_new_amount,
           amount_overridden = true,
           status = (case
                       when l.amount_paid <= 0          then 'scheduled'
                       when l.amount_paid >= p_new_amount then 'paid'
                       else 'partial'
                     end)::line_status
      from budget_period p
     where l.budget_period_id = p.id
       and l.account_id = p_account_id
       and not p.is_closed
       and l.status <> 'paid'        -- never rewrite a settled line
       and p.period_end >= current_date;
    get diagnostics n = row_count;
  end if;

  return query select p_account_id, p_new_amount, n;
end $$;

-- ---------------------------------------------------------------------
-- deactivate_account() — a bill is no longer active.
--
-- Soft delete. The account row and all PAID history survive; only
-- unpaid future lines are removed so they stop cluttering the budget.
-- Use this instead of DELETE — deleting the account nulls account_id on
-- every historical line and you lose the ability to trend it.
-- ---------------------------------------------------------------------
create or replace function deactivate_account(
  p_account_id bigint,
  p_effective  date default null,
  p_note       text default null
) returns table (account_id bigint, lines_removed int)
language plpgsql security invoker
set search_path = public, pg_temp as $$
declare
  eff date := coalesce(p_effective, current_date);
  n   int  := 0;
begin
  perform require_owner();

  update account
     set is_active = false,
         notes = coalesce(p_note, notes)
   where id = p_account_id;

  if not found then
    raise exception 'account % not found or not visible', p_account_id;
  end if;

  delete from budget_line l
   using budget_period p
   where l.budget_period_id = p.id
     and l.account_id = p_account_id
     and l.status = 'scheduled'
     and l.amount_paid = 0
     and l.due_date >= eff
     and not p.is_closed;
  get diagnostics n = row_count;

  return query select p_account_id, n;
end $$;

create or replace function reactivate_account(p_account_id bigint)
returns account
language plpgsql security invoker
set search_path = public, pg_temp as $$
declare rec account;
begin
  perform require_owner();
  update account set is_active = true where id = p_account_id returning * into rec;
  if not found then
    raise exception 'account % not found or not visible', p_account_id;
  end if;
  return rec;
end $$;

-- ---------------------------------------------------------------------
-- reschedule_account() — the due date or cadence changed.
-- Future unpaid lines are dropped and re-materialized on the new schedule.
-- ---------------------------------------------------------------------
create or replace function reschedule_account(
  p_account_id  bigint,
  p_frequency   frequency default null,
  p_due_day     int default null,
  p_due_day_2   int default null,
  p_due_month   int default null,
  p_anchor_date date default null,
  p_is_always_due boolean default null
) returns int
language plpgsql security invoker
set search_path = public, pg_temp as $$
declare
  hh   uuid;
  pid  bigint;
  made int := 0;
begin
  perform require_owner();

  update account
     set frequency   = coalesce(p_frequency,   frequency),
         due_day     = coalesce(p_due_day,     due_day),
         due_day_2   = coalesce(p_due_day_2,   due_day_2),
         due_month   = coalesce(p_due_month,   due_month),
         anchor_date = coalesce(p_anchor_date, anchor_date),
         is_always_due = coalesce(p_is_always_due, is_always_due)
   where id = p_account_id
   returning household_id into hh;

  if hh is null then
    raise exception 'account % not found or not visible', p_account_id;
  end if;

  delete from budget_line l
   using budget_period p
   where l.budget_period_id = p.id
     and l.account_id = p_account_id
     and l.status = 'scheduled'
     and l.amount_paid = 0
     and not p.is_closed
     and p.period_end >= current_date;

  for pid in
    select id from budget_period
    where household_id = hh and not is_closed and period_end >= current_date
  loop
    made := made + materialize_period(pid);
  end loop;

  return made;
end $$;

-- ---------------------------------------------------------------------
-- set_amount_mode() — how this bill's amount gets decided each period.
--
--   carry_forward     variable bills (water, electric): repeat what you
--                     actually paid last time
--   fixed             stable bills (mortgage, insurance): always the
--                     catalog amount
--   percent_of_income tithes and similar: a share of the period's net
-- ---------------------------------------------------------------------
create or replace function set_amount_mode(
  p_account_id bigint,
  p_mode       amount_mode,
  p_percent    numeric default null,
  p_amount     numeric default null
) returns account
language plpgsql security invoker
set search_path = public, pg_temp as $$
declare rec account;
begin
  perform require_owner();

  if p_mode = 'percent_of_income' and coalesce(p_percent, -1) < 0 then
    raise exception 'percent_of_income requires p_percent (0.10 = 10%%)';
  end if;

  update account
     set amount_mode    = p_mode,
         amount_percent = case when p_mode = 'percent_of_income'
                               then p_percent else amount_percent end,
         default_amount = coalesce(p_amount, default_amount),
         amount_set_on  = case when p_amount is not null
                               then current_date else amount_set_on end
   where id = p_account_id
   returning * into rec;

  if not found then
    raise exception 'account % not found or not visible', p_account_id;
  end if;
  return rec;
end $$;

-- ---------------------------------------------------------------------
-- set_always_due() — the checkbox.
--
-- ON  : the account gets exactly one line per pay period, dated on the
--       pay date, regardless of its own frequency/due_day. Its normal
--       schedule is ignored while this is set.
-- OFF : it reverts to its frequency + due_day / anchor_date schedule.
--
-- Flipping this changes which dates the lines fall on, so unpaid future
-- lines are dropped and rebuilt. PAID and PARTIAL lines are left alone —
-- history is never rewritten by a settings change — and closed periods
-- are untouched.
-- ---------------------------------------------------------------------
create or replace function set_always_due(
  p_account_id bigint,
  p_on         boolean
) returns table (account_id bigint, is_always_due boolean, lines_rebuilt int)
language plpgsql security invoker
set search_path = public, pg_temp as $$
declare
  hh   uuid;
  pid  bigint;
  made int := 0;
begin
  perform require_owner();

  update account a
     set is_always_due = p_on
   where a.id = p_account_id
   returning a.household_id into hh;

  if hh is null then
    raise exception 'account % not found or not visible', p_account_id;
  end if;

  -- Clear only lines that are still open, in the future, in open periods.
  delete from budget_line l
   using budget_period p
   where l.budget_period_id = p.id
     and l.account_id = p_account_id
     and l.status = 'scheduled'
     and l.amount_paid = 0
     and not p.is_closed
     and p.period_end >= current_date;

  for pid in
    select p.id from budget_period p
    where p.household_id = hh
      and not p.is_closed
      and p.period_end >= current_date
    order by p.period_start
  loop
    made := made + materialize_period(pid);
  end loop;

  return query select p_account_id, p_on, made;
end $$;

-- =====================================================================
-- RECORD CORRECTIONS
-- =====================================================================

-- ---------------------------------------------------------------------
-- correct_budget_line() — fix a record that was entered wrong.
--
-- Owner-only, works on paid and closed lines (the one path that can),
-- and REQUIRES a reason, which lands in audit_log alongside the before
-- and after images. Pass null for any field to leave it unchanged.
-- ---------------------------------------------------------------------
create or replace function correct_budget_line(
  p_line_id     bigint,
  p_reason      text,
  p_amount_due  numeric default null,
  p_amount_paid numeric default null,
  p_due_date    date    default null,
  p_paid_on     date    default null,
  p_status      line_status default null,
  p_category_id bigint  default null,
  p_notes       text    default null
) returns budget_line
language plpgsql security invoker
set search_path = public, pg_temp as $$
declare
  before_row budget_line;
  rec        budget_line;
  new_due    numeric;
  new_paid   numeric;
begin
  perform require_owner();

  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A reason is required when correcting a record';
  end if;

  select * into before_row from budget_line where id = p_line_id;
  if not found then
    raise exception 'budget_line % not found or not visible', p_line_id;
  end if;

  new_due  := coalesce(p_amount_due,  before_row.amount_due);
  new_paid := coalesce(p_amount_paid, before_row.amount_paid);

  update budget_line
     set amount_due  = new_due,
         amount_overridden = amount_overridden or (p_amount_due is not null),
         amount_paid = new_paid,
         due_date    = coalesce(p_due_date,    due_date),
         paid_on     = coalesce(p_paid_on,     paid_on),
         category_id = coalesce(p_category_id, category_id),
         notes       = coalesce(p_notes,       notes),
         -- If status wasn't given, recompute it from the amounts so the
         -- row can't end up marked paid with nothing paid against it.
         status = coalesce(p_status, (case
                    when new_paid <= 0        then 'scheduled'
                    when new_paid >= new_due  then 'paid'
                    else 'partial'
                  end)::line_status)
   where id = p_line_id
   returning * into rec;

  perform log_correction(rec.household_id, 'budget_line', rec.id::text,
                         'CORRECTION: ' || p_reason, to_jsonb(before_row), to_jsonb(rec));

  return rec;
end $$;

-- ---------------------------------------------------------------------
-- correct_income() — same idea for a paycheck entered wrong.
-- ---------------------------------------------------------------------
create or replace function correct_income(
  p_income_id  bigint,
  p_reason     text,
  p_hourly_rate numeric default null,
  p_hours       numeric default null,
  p_gross_override numeric default null,
  p_taxes       numeric default null,
  p_healthcare  numeric default null,
  p_retirement  numeric default null,
  p_received_on date default null
) returns income
language plpgsql security invoker
set search_path = public, pg_temp as $$
declare before_row income; rec income;
begin
  perform require_owner();
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A reason is required when correcting a record';
  end if;

  select * into before_row from income where id = p_income_id;
  if not found then
    raise exception 'income % not found or not visible', p_income_id;
  end if;

  update income
     set hourly_rate    = coalesce(p_hourly_rate,    hourly_rate),
         hours          = coalesce(p_hours,          hours),
         gross_override = coalesce(p_gross_override, gross_override),
         taxes          = coalesce(p_taxes,          taxes),
         healthcare     = coalesce(p_healthcare,     healthcare),
         retirement     = coalesce(p_retirement,     retirement),
         received_on    = coalesce(p_received_on,    received_on)
   where id = p_income_id
   returning * into rec;

  perform log_correction(rec.household_id, 'income', rec.id::text,
                         'CORRECTION: ' || p_reason, to_jsonb(before_row), to_jsonb(rec));

  return rec;
end $$;

-- ---------------------------------------------------------------------
-- Period open / close.
-- Closing freezes a period: materialize_period refuses to touch it and
-- update_account_amount skips it. Reopening is deliberate and logged.
-- ---------------------------------------------------------------------
create or replace function close_period(p_period_id bigint)
returns budget_period
language plpgsql security invoker
set search_path = public, pg_temp as $$
declare rec budget_period;
begin
  perform require_owner();
  update budget_period set is_closed = true where id = p_period_id returning * into rec;
  if not found then raise exception 'budget_period % not visible', p_period_id; end if;
  return rec;
end $$;

create or replace function reopen_period(p_period_id bigint, p_reason text)
returns budget_period
language plpgsql security invoker
set search_path = public, pg_temp as $$
declare rec budget_period;
begin
  perform require_owner();
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A reason is required to reopen a closed period';
  end if;
  update budget_period set is_closed = false where id = p_period_id returning * into rec;
  if not found then raise exception 'budget_period % not visible', p_period_id; end if;

  perform log_correction(rec.household_id, 'budget_period', rec.id::text,
                         'REOPEN: ' || p_reason, null, to_jsonb(rec));
  return rec;
end $$;

-- =====================================================================
-- ADMIN VIEWS
-- =====================================================================

-- Wage history with the size of each raise.
create or replace view v_wage_history
with (security_invoker = true) as
select
  w.household_id,
  e.display_name as earner,
  w.effective_from,
  lead(w.effective_from) over (partition by w.earner_id order by w.effective_from)
    - interval '1 day' as effective_to,
  w.hourly_rate,
  w.annual_salary,
  w.standard_hours,
  coalesce(w.annual_salary, round(w.hourly_rate * w.standard_hours * 26, 2)) as annualized,
  w.hourly_rate - lag(w.hourly_rate) over (partition by w.earner_id order by w.effective_from)
    as rate_change,
  case when lag(w.hourly_rate) over (partition by w.earner_id order by w.effective_from) > 0
       then round((w.hourly_rate / lag(w.hourly_rate) over
              (partition by w.earner_id order by w.effective_from) - 1) * 100, 2)
  end as pct_increase,
  w.note
from wage_rate w
join earner e on e.id = w.earner_id;

-- Everything the owner might need to change, in one place.
create or replace view v_account_admin
with (security_invoker = true) as
select
  a.id, a.household_id, a.name, a.kind, a.frequency,
  a.default_amount, a.due_day, a.anchor_date,
  a.is_always_due, a.is_variable, a.is_active,
  a.amount_mode, a.amount_percent, a.amount_set_on,
  parent.name as type_name,
  case when c.parent_id is null then null else c.name end as sub_type_name,
  e.display_name as owner_name,
  st.last_paid_on,
  st.last_paid_amount,
  st.open_lines,
  a.updated_at
from account a
left join category c on c.id = a.category_id
left join category parent on parent.id = coalesce(c.parent_id, c.id)
left join earner e on e.id = a.owner_earner_id
left join lateral (
  select max(paid_on) filter (where status = 'paid') as last_paid_on,
         (array_agg(amount_paid order by paid_on desc nulls last)
            filter (where status = 'paid'))[1]      as last_paid_amount,
         count(*) filter (where status = 'scheduled') as open_lines
  from budget_line where account_id = a.id
) st on true;

-- Human-readable audit trail.
create or replace view v_audit_trail
with (security_invoker = true) as
select
  al.id, al.household_id, al.changed_at, al.table_name, al.row_id, al.action,
  coalesce(p.display_name, 'system') as actor_name,
  al.old_row ->> 'name'        as row_name,
  al.old_row ->> 'amount_due'  as old_amount_due,
  al.new_row ->> 'amount_due'  as new_amount_due,
  al.old_row ->> 'amount_paid' as old_amount_paid,
  al.new_row ->> 'amount_paid' as new_amount_paid,
  al.old_row, al.new_row
from audit_log al
left join profile p on p.id = al.actor;

grant select on v_wage_history, v_account_admin, v_audit_trail to authenticated;

grant execute on function
  apply_raise, record_paycheck, rate_on, log_correction,
  update_account_amount, deactivate_account, reactivate_account, reschedule_account,
  set_always_due, set_amount_mode, refresh_period_amounts,
  refresh_household_amounts, next_amount_for, reset_line_amount,
  add_funds, remove_funds, is_wage,
  correct_budget_line, correct_income, close_period, reopen_period
  to authenticated;
