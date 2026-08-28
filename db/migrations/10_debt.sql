-- =====================================================================
-- 10 — Recording debt balances the way statements report them.
--
-- Run after 01-07. Additive.
--
-- A credit card statement gives you AVAILABLE CREDIT. A car loan gives
-- you the PAYOFF AMOUNT. A mortgage statement gives you PRINCIPAL
-- REMAINING. Only one of those is the balance directly — the others need
-- arithmetic, and doing that in your head every month is where errors
-- creep in. record_debt_balance() takes whichever number is printed in
-- front of you and derives the rest.
-- =====================================================================

-- ---------------------------------------------------------------------
-- record_debt_balance()
--
-- Supply exactly ONE of:
--   p_balance          what you owe        (loan payoff, card balance)
--   p_available_credit what you can still spend  -> balance = limit - avail
--   p_paid_to_date     how much you've repaid    -> balance = limit - paid
--
-- credit_limit doubles as the original principal on a loan, which is what
-- makes paid_to_date work for both.
-- ---------------------------------------------------------------------
create or replace function record_debt_balance(
  p_account_id       bigint,
  p_balance          numeric default null,
  p_available_credit numeric default null,
  p_paid_to_date     numeric default null,
  p_as_of            date default null
-- OUT names are prefixed: a RETURNS TABLE column named `as_of` shadows
-- debt_balance.as_of inside this function, which makes the ON CONFLICT
-- target ambiguous and fails at runtime.
) returns table (
  out_as_of            date,
  out_balance          numeric,
  out_available_credit numeric,
  out_paid_to_date     numeric,
  out_utilization      numeric
)
language plpgsql security invoker
set search_path = public, pg_temp as $$
declare
  hh      uuid;
  lim     numeric(12,2);
  bal     numeric(12,2);
  d       date;
  supplied int;
begin
  perform require_owner();

  supplied := (case when p_balance          is not null then 1 else 0 end)
            + (case when p_available_credit is not null then 1 else 0 end)
            + (case when p_paid_to_date     is not null then 1 else 0 end);

  if supplied = 0 then
    raise exception 'Enter one of: balance owed, available credit, or paid to date';
  end if;
  if supplied > 1 then
    raise exception 'Enter only one of: balance owed, available credit, or paid to date';
  end if;

  select a.household_id, dd.credit_limit
    into hh, lim
  from account a
  join debt_detail dd on dd.account_id = a.id
  where a.id = p_account_id and a.kind = 'debt';

  if hh is null then
    raise exception 'Debt % not found or not visible', p_account_id;
  end if;

  d := coalesce(p_as_of, current_date);

  if p_balance is not null then
    bal := p_balance;
  else
    if lim is null then
      raise exception
        'This debt has no credit limit or original amount set, so % cannot be converted to a balance. Set the limit first.',
        case when p_available_credit is not null then 'available credit' else 'paid to date' end;
    end if;
    bal := lim - coalesce(p_available_credit, p_paid_to_date);
  end if;

  if bal < 0 then
    raise exception 'That works out to a negative balance (%). Check the number and the credit limit.',
      to_char(bal, 'FM999999990.00');
  end if;

  insert into debt_balance (household_id, account_id, as_of, balance)
  values (hh, p_account_id, d, bal)
  on conflict (account_id, as_of) do update set balance = excluded.balance;

  return query
  select d, bal,
         case when lim is not null then lim - bal end,
         case when lim is not null then lim - bal end,
         case when lim > 0 then round(bal / lim, 4) end;
end $$;

-- ---------------------------------------------------------------------
-- update_debt_detail() — limits change, rates change, cards get closed.
-- Only overwrites what you pass; nulls leave the existing value alone.
-- ---------------------------------------------------------------------
create or replace function update_debt_detail(
  p_account_id       bigint,
  p_credit_limit     numeric default null,
  p_apr              numeric default null,
  p_minimum_payment  numeric default null,
  p_debt_type        debt_kind default null,
  p_target_utilization numeric default null
) returns debt_detail
language plpgsql security invoker
set search_path = public, pg_temp as $$
declare rec debt_detail;
begin
  perform require_owner();

  update debt_detail
     set credit_limit     = coalesce(p_credit_limit, credit_limit),
         -- Accept 13.09 or 0.1309; store the fraction either way.
         apr              = coalesce(
                              case when p_apr is null then null
                                   when p_apr > 1     then p_apr / 100
                                   else p_apr end, apr),
         minimum_payment  = coalesce(p_minimum_payment, minimum_payment),
         debt_type        = coalesce(p_debt_type, debt_type),
         target_utilization = coalesce(p_target_utilization, target_utilization)
   where account_id = p_account_id
   returning * into rec;

  if not found then
    raise exception 'Debt % not found or not visible', p_account_id;
  end if;
  return rec;
end $$;

-- ---------------------------------------------------------------------
-- CREATE OR REPLACE VIEW can only APPEND columns, never insert one into
-- the middle, so the old definition has to go first.
drop view if exists v_debt_status;

-- v_debt_status gains paid_to_date and the previous reading, so the app
-- can show progress since last month rather than just a snapshot.
-- ---------------------------------------------------------------------
create or replace view v_debt_status
with (security_invoker = true) as
select
  a.id, a.household_id, a.name, dd.debt_type,
  dd.credit_limit, dd.apr, dd.minimum_payment, a.due_day,
  e.display_name as owner_name,
  b.balance as current_balance,
  b.as_of    as balance_as_of,
  dd.credit_limit - b.balance as available_credit,
  -- On a loan this reads as "principal repaid"; on a card it's the same
  -- number the statement calls available credit.
  dd.credit_limit - b.balance as paid_to_date,
  prev.balance as previous_balance,
  prev.as_of   as previous_as_of,
  case when prev.balance is not null then prev.balance - b.balance end as change_since_last,
  case when dd.credit_limit > 0 then round(b.balance / dd.credit_limit, 4) end as utilization,
  case when dd.credit_limit > 0 then round(1 - (b.balance / dd.credit_limit), 4) end as paid_off_pct,
  dd.target_utilization,
  case when dd.credit_limit > 0
       then round(b.balance - (dd.credit_limit * dd.target_utilization), 2) end as amount_over_target,
  rank() over (partition by a.household_id order by dd.apr desc nulls last)   as avalanche_rank,
  rank() over (partition by a.household_id order by b.balance asc nulls last) as snowball_rank
from account a
join debt_detail dd on dd.account_id = a.id
left join earner e on e.id = a.owner_earner_id
left join lateral (
  select balance, as_of from debt_balance
  where account_id = a.id order by as_of desc limit 1
) b on true
left join lateral (
  select balance, as_of from debt_balance
  where account_id = a.id order by as_of desc offset 1 limit 1
) prev on true
where a.is_active and a.kind = 'debt';

-- Every reading for one debt, for a history list or a sparkline.
create or replace view v_debt_history
with (security_invoker = true) as
select
  db.household_id,
  db.account_id,
  a.name,
  db.as_of,
  db.balance,
  dd.credit_limit - db.balance as available_credit,
  case when dd.credit_limit > 0 then round(db.balance / dd.credit_limit, 4) end as utilization,
  lag(db.balance) over (partition by db.account_id order by db.as_of) - db.balance as paid_since_previous
from debt_balance db
join account a      on a.id = db.account_id
join debt_detail dd on dd.account_id = db.account_id;

grant select on v_debt_status, v_debt_history to authenticated;
grant execute on all functions in schema public to authenticated;
revoke execute on all functions in schema public from public, anon;
