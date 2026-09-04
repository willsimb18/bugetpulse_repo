-- =====================================================================
-- 17 — Stop the same paycheck being recorded twice.
--
-- income has no unique constraint and record_paycheck inserted without
-- looking, so pressing the button twice — or two people pressing it —
-- silently doubled a period's income. Every figure downstream then reads
-- high: net_income, balance_on_wages, projected_balance, and the year on
-- year card.
--
-- Two layers, because they fail differently:
--
--   record_paycheck now refuses, with a message naming the date and
--   amount already on file, so the person pressing the button finds out
--   what happened rather than seeing a constraint code.
--
--   A unique index backs that up for anything reaching the table another
--   way. It can only be created if the data is already clean, so this
--   checks first and leaves a notice rather than failing the migration
--   on a duplicate that is already there.
--
-- p_allow_duplicate is the escape hatch for the case that is genuinely
-- two paychecks in one period — a final cheque and a first cheque in the
-- same fortnight after a job change, say.
-- =====================================================================

-- The new signature takes a tenth argument, so `create or replace` would
-- leave an OVERLOAD rather than replacing anything: the old unguarded
-- nine-argument version would still be there, still callable, and with
-- every argument after the second defaulted the two would be ambiguous.
-- Drop it first.
drop function if exists record_paycheck(
  bigint, bigint, date, numeric, income_kind, numeric, numeric, numeric, numeric);

create or replace function record_paycheck(
  p_earner_id  bigint,
  p_period_id  bigint,
  p_check_date date default null,
  p_hours      numeric default null,
  p_kind       income_kind default 'regular',
  p_taxes      numeric default null,
  p_healthcare numeric default null,
  p_retirement numeric default null,
  p_gross_override numeric default null,
  p_allow_duplicate boolean default false
) returns income
language plpgsql security invoker
set search_path = public, pg_temp as $$
declare
  per budget_period;
  wr  wage_rate;
  d   date;
  rec income;
  dup income;
begin
  perform require_owner();

  select * into per from budget_period where id = p_period_id;
  if not found then raise exception 'budget_period % not visible', p_period_id; end if;

  -- Already have one of these for this person, in this period?
  if not p_allow_duplicate then
    select * into dup
    from income
    where earner_id = p_earner_id
      and budget_period_id = p_period_id
      and kind = p_kind
    order by id
    limit 1;

    if found then
      raise exception
        'A % paycheck for this earner is already recorded in this period: % on %. '
        'Delete it first, or pass p_allow_duplicate => true if there really were two.',
        p_kind, to_char(dup.net, 'FM999999990.00'), dup.received_on
        using errcode = 'unique_violation';
    end if;
  end if;

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

revoke execute on function record_paycheck(
  bigint, bigint, date, numeric, income_kind, numeric, numeric, numeric, numeric, boolean
) from public, anon;
grant execute on function record_paycheck(
  bigint, bigint, date, numeric, income_kind, numeric, numeric, numeric, numeric, boolean
) to authenticated;


-- ---------------------------------------------------------------------
-- The backstop, if the data will take it.
-- ---------------------------------------------------------------------
do $$
declare n int;
begin
  select count(*) into n from (
    select 1 from income
    where earner_id is not null and budget_period_id is not null
    group by earner_id, budget_period_id, kind
    having count(*) > 1
  ) d;

  if n > 0 then
    raise notice
      'Not adding the unique index: % (earner, period, kind) group(s) already hold '
      'more than one row. Clear the duplicates, then re-run this file.', n;
    return;
  end if;

  create unique index if not exists income_one_per_earner_period_kind
    on income (earner_id, budget_period_id, kind)
    where earner_id is not null and budget_period_id is not null;

  raise notice 'Unique index added: one paycheck per earner, per period, per kind.';
end $$;
