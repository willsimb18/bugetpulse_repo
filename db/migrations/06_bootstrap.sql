-- =====================================================================
-- 06 — Bootstrap. Run once, after 01-05.
--
-- Paste this whole file into the Supabase SQL Editor and hit Run.
-- Edit only the six values in the CONFIGURE block below.
--
-- No psql backslash commands here: the Supabase SQL Editor talks straight
-- to the server, so \set and friends don't exist. Everything runs inside
-- one DO block instead, which also means it either fully succeeds or
-- fully rolls back.
--
-- Safe to run more than once. It reuses an existing household rather than
-- creating a second one, and updates names in place.
-- =====================================================================

-- ---------------------------------------------------------------------
-- BEFORE YOU RUN THIS
--
-- Authentication -> Users -> "Add user" for BOTH of you.
--   * Tick "Auto Confirm User", or the login won't work.
--   * Use the same two emails you put below.
--
-- Then Authentication -> Sign In / Providers -> turn OFF
-- "Allow new users to sign up".
--
-- You do NOT need to copy any UUIDs. This looks them up by email.
-- ---------------------------------------------------------------------

do $$
declare
  -- ================= CONFIGURE — edit these six =================
  v_owner_email    text := 'you@example.com';      -- your login
  v_spouse_email   text := 'her@example.com';      -- her login
  v_owner_name     text := 'Owner';                -- shown in the app
  v_spouse_name    text := 'Spouse';
  v_household_name text := 'Our Household';
  v_anchor         date := '2026-08-21';           -- the current paycheck
  -- ==============================================================

  v_hh      uuid;
  v_owner   uuid;
  v_spouse  uuid;
  v_periods int;
begin
  -- Look up both logins by email.
  select id into v_owner  from auth.users where lower(email) = lower(v_owner_email);
  select id into v_spouse from auth.users where lower(email) = lower(v_spouse_email);

  if v_owner is null then
    raise exception
      'No user found for %. Create it under Authentication -> Users (tick Auto Confirm User), then run this again.',
      v_owner_email;
  end if;
  if v_spouse is null then
    raise exception
      'No user found for %. Create it under Authentication -> Users (tick Auto Confirm User), then run this again.',
      v_spouse_email;
  end if;
  if v_owner = v_spouse then
    raise exception 'Both emails resolve to the same user. Use two different logins.';
  end if;

  -- Reuse the household if this has been run before.
  select household_id into v_hh from profile where id = v_owner;

  if v_hh is null then
    insert into household (name, base_frequency, timezone)
    values (v_household_name, 'biweekly', 'America/New_York')
    returning id into v_hh;
  else
    update household set name = v_household_name where id = v_hh;
  end if;

  -- Profiles. You get owner, she gets member: she can mark anything paid,
  -- you control amounts and which bills exist. Change her role to 'owner'
  -- here if you'd rather you both have full control.
  insert into profile (id, household_id, display_name, role)
  values (v_owner,  v_hh, v_owner_name,  'owner'),
         (v_spouse, v_hh, v_spouse_name, 'member')
  on conflict (id) do update
    set household_id = excluded.household_id,
        display_name = excluded.display_name,
        role         = excluded.role;

  -- Earners: who the paychecks belong to.
  --
  -- Keyed on profile_id, not display_name. Keying on the name means
  -- changing "Owner" to your actual name on a re-run creates a SECOND
  -- earner and orphans the paychecks attached to the first one.
  update earner
     set display_name = v_owner_name, pay_anchor = v_anchor, is_active = true
   where household_id = v_hh and profile_id = v_owner;
  if not found then
    insert into earner (household_id, display_name, profile_id, pay_frequency, pay_anchor)
    values (v_hh, v_owner_name, v_owner, 'biweekly', v_anchor);
  end if;

  update earner
     set display_name = v_spouse_name, pay_anchor = v_anchor, is_active = true
   where household_id = v_hh and profile_id = v_spouse;
  if not found then
    insert into earner (household_id, display_name, profile_id, pay_frequency, pay_anchor)
    values (v_hh, v_spouse_name, v_spouse, 'biweekly', v_anchor);
  end if;

  -- Pay calendar: 26 biweekly periods forward from the anchor = one year.
  select generate_budget_periods(v_hh, 'biweekly', v_anchor, 26) into v_periods;

  raise notice 'Household % ready. % new pay periods from %.', v_hh, v_periods, v_anchor;
end $$;


-- =====================================================================
-- Check it worked. Each of these should return rows.
-- =====================================================================

-- Your household id. Keep it — migrate.py needs it as HOUSEHOLD_ID.
select id as household_id, name, base_frequency from household;

-- Both logins, linked and with the right roles.
select p.display_name, p.role, u.email
from profile p
join auth.users u on u.id = p.id
order by p.role desc;

-- First few pay periods. The first should start 2026-08-21.
select period_start, period_end, pay_date, label
from budget_period
order by period_start
limit 5;


-- =====================================================================
-- NEXT
-- =====================================================================

-- 1. Load your SQL Server data (see SETUP.md):
--      python3 migrate.py --dry-run
--      python3 migrate.py
--
--    Or, if you'd rather start clean, add accounts in the app and skip it.

-- 2. Build the budget lines and price them:
--      select refresh_household_amounts(id) from household;

-- 3. Starting pay rate — ONLY if you skipped migrate.py, which imports
--    rates from Wages. Every later raise is apply_raise(), never an edit.
--
--    select apply_raise(
--      (select id from earner where display_name = 'Owner'),
--      '2026-08-21',
--      p_hourly_rate    => 77.50,
--      p_standard_hours => 80,
--      p_taxes_est      => 1661.38,
--      p_healthcare_est => 110.62,
--      p_retirement_est => 248.00,
--      p_note           => 'Starting rate');

-- 4. Nightly upkeep. Database -> Extensions -> enable pg_cron, then:
--
--    select cron.schedule('nightly-budget', '15 3 * * *', $cron$
--      select refresh_household_amounts(id) from household $cron$);

-- 5. Database -> Replication -> enable realtime on budget_line, so the
--    two of you see each other's payments without refreshing.
