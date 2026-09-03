-- =====================================================================
-- Merge a duplicate earner into the one that owns the login.
--
-- Why this exists: import_from_sqlserver.py creates earners from
-- users.FirstName, keyed on (household_id, display_name). 06_bootstrap.sql
-- has already created one earner per profile using whatever names were
-- typed into its CONFIGURE block. If the two spellings differ at all you
-- get two rows for the same person -- one holding the profile link and
-- pay_anchor, the other holding the imported wage_rate. Paycheck
-- attribution reads through earner -> profile, so the rates end up on the
-- row the app does not look at.
--
-- Run STEP 1, read the output, fill in STEP 2, run it. Once per person.
-- Harmless to re-run: STEP 2 refuses to do anything until it is filled in.
-- =====================================================================

-- ---------------------------------------------------------------------
-- STEP 1 -- who is who.
--   keep = the row with a profile_id (a real login)
--   drop = the row with wage rates but no profile_id (from the import)
-- ---------------------------------------------------------------------
select e.id,
       e.display_name,
       e.profile_id is not null                                        as linked_to_login,
       e.pay_anchor,
       (select count(*) from wage_rate w where w.earner_id = e.id)     as wage_rates,
       (select count(*) from income    i where i.earner_id = e.id)     as income_rows,
       (select count(*) from account   a where a.owner_earner_id = e.id) as owned_accounts
from earner e
order by e.id;


-- ---------------------------------------------------------------------
-- STEP 2 -- edit the three values below, then run this block.
-- ---------------------------------------------------------------------
do $$
declare
  -- ================= CONFIGURE — edit these three =================
  v_keep     bigint := 0;    -- id of the earner WITH the profile link
  v_drop     bigint := 0;    -- id of the duplicate to fold into it
  v_new_name text   := '';   -- name to keep, as it should read in the app
  -- ================================================================
  v_hh uuid;
begin
  if v_keep = 0 or v_drop = 0 or v_new_name = '' then
    raise exception 'Fill in v_keep, v_drop and v_new_name from STEP 1 first.';
  end if;
  if v_keep = v_drop then
    raise exception 'v_keep and v_drop are the same row.';
  end if;

  select household_id into v_hh from earner where id = v_keep;
  if v_hh is null then
    raise exception 'No earner with id %.', v_keep;
  end if;
  if not exists (select 1 from earner where id = v_drop and household_id = v_hh) then
    raise exception 'Earner % is not in the same household as %.', v_drop, v_keep;
  end if;

  -- wage_rate is unique on (earner_id, effective_from). Drop a duplicate
  -- date rather than failing the whole merge on it.
  delete from wage_rate w
   where w.earner_id = v_drop
     and exists (select 1 from wage_rate k
                  where k.earner_id = v_keep
                    and k.effective_from = w.effective_from);

  update wage_rate set earner_id       = v_keep where earner_id       = v_drop;
  update income    set earner_id       = v_keep where earner_id       = v_drop;
  update account   set owner_earner_id = v_keep where owner_earner_id = v_drop;

  delete from earner where id = v_drop;
  update earner set display_name = v_new_name, is_active = true where id = v_keep;

  raise notice 'Merged earner % into %, now named %.', v_drop, v_keep, v_new_name;
end $$;


-- Confirm: one row per person, each with a login and its wage rate.
select e.id, e.display_name,
       e.profile_id is not null                                    as linked_to_login,
       (select count(*) from wage_rate w where w.earner_id = e.id) as wage_rates
from earner e
order by e.id;
