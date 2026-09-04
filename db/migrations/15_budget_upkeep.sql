-- =====================================================================
-- 15 — Keep the next pay period ready, without anyone remembering to.
--
-- Nothing has ever called refresh_household_amounts(): the nightly job in
-- 06_bootstrap.sql was left commented out and the app never invokes it.
-- So budget lines only appeared when someone ran it by hand.
--
-- Two things have to happen, and only the second was ever written down.
-- materialize_period() fills periods that ALREADY EXIST, so once the
-- generated calendar runs out there is nothing left to fill. Upkeep
-- therefore extends the calendar first, then materializes.
--
-- Runs as security definer so the cron worker -- which has no session and
-- so no app_household_id() -- can still write.
-- =====================================================================

create or replace function run_budget_upkeep(p_days_ahead int default 60)
returns table (household_id uuid, periods_added int, lines_created int, lines_repriced int)
language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  h          record;
  v_target   date := current_date + (p_days_ahead || ' days')::interval;
  v_last_end date;
  v_last_str date;
  v_added    int;
  v_guard    int;
  r          record;
begin
  for h in select id, base_frequency from household loop
    v_added := 0;
    v_guard := 0;

    -- Extend the calendar in small steps until it reaches far enough
    -- ahead. generate_budget_periods is `on conflict do nothing`, so
    -- re-covering existing periods costs nothing and adds nothing.
    loop
      select max(period_end), max(period_start)
        into v_last_end, v_last_str
        from budget_period where budget_period.household_id = h.id;

      exit when v_last_str is null;          -- no calendar to extend from
      exit when v_last_end >= v_target;
      exit when v_guard >= 12;               -- never spin

      v_added := v_added + generate_budget_periods(
        h.id, h.base_frequency, v_last_str, 5);
      v_guard := v_guard + 1;
    end loop;

    -- Then fill and reprice every open period that has not ended.
    select * into r from refresh_household_amounts(h.id);

    household_id   := h.id;
    periods_added  := v_added;
    lines_created  := coalesce(r.lines_created, 0);
    lines_repriced := coalesce(r.lines_repriced, 0);
    return next;
  end loop;
end $$;

comment on function run_budget_upkeep(int) is
  'Extends the pay-period calendar to p_days_ahead and materializes lines '
  'for every open period. Safe to run repeatedly; scheduled nightly.';

revoke execute on function run_budget_upkeep(int) from public, anon;
grant  execute on function run_budget_upkeep(int) to authenticated;


-- ---------------------------------------------------------------------
-- Schedule it. pg_cron has to be enabled on the project first
-- (Database -> Extensions). If it is not, this leaves a notice rather
-- than failing the migration, and re-running the file once the extension
-- is on will pick it up.
--
-- 07:15 UTC is a little after 2am Eastern, so a run never lands in the
-- middle of a day either of you is looking at the app.
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice
      'pg_cron is not enabled — budget upkeep is NOT scheduled. Enable it under '
      'Database -> Extensions, then re-run this file.';
    return;
  end if;

  -- Replace any previous definition of the job rather than stacking them.
  perform cron.unschedule(jobid) from cron.job where jobname = 'budget-upkeep';
  perform cron.schedule('budget-upkeep', '15 7 * * *',
                        'select run_budget_upkeep()');
  raise notice 'budget-upkeep scheduled nightly at 07:15 UTC.';
end $$;
