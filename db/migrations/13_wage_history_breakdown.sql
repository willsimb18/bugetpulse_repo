-- =====================================================================
-- 13 — Expose the paycheck breakdown on v_wage_history.
--
-- Finance's Wages table carries, per person, the figures that make up a
-- paycheck: WageAmount, Hours, Taxes, Healthcare and 401K. The importer
-- loaded all of them into wage_rate, but v_wage_history only ever
-- returned the rate, so the app had no way to show the breakdown and it
-- looked as though the data had not come across.
--
-- gross_per_period and net_per_period reproduce the Wages tab's own
-- arithmetic: rate x hours, less the three deductions.
--
-- create or replace view only permits new columns at the end, so these
-- land after note.
-- =====================================================================

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
  w.note,
  -- New below this line.
  w.earner_id,
  w.taxes_est,
  w.healthcare_est,
  w.retirement_est,
  round(coalesce(w.annual_salary / 26.0,
                 coalesce(w.hourly_rate, 0) * coalesce(w.standard_hours, 0)), 2)
    as gross_per_period,
  round(coalesce(w.annual_salary / 26.0,
                 coalesce(w.hourly_rate, 0) * coalesce(w.standard_hours, 0))
        - coalesce(w.taxes_est, 0)
        - coalesce(w.healthcare_est, 0)
        - coalesce(w.retirement_est, 0), 2)
    as net_per_period
from wage_rate w
join earner e on e.id = w.earner_id;

grant select on v_wage_history to authenticated;
