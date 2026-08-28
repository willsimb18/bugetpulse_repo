-- =====================================================================
-- Row Level Security
--
-- Model: everyone in a household reads everything in that household.
-- Owners write everything. Members write only budget_line payment fields
-- (the column restriction is enforced by t_budget_line_member_scope).
--
-- Nothing is reachable without a profile row, so an authenticated user
-- who is not in your household sees an empty database, not an error.
-- =====================================================================

do $$
declare t text;
begin
  foreach t in array array[
    'household','profile','category','earner','wage_rate','budget_period',
    'income','account','debt_detail','debt_balance','budget_line','bank',
    'statement_txn','category_keyword','audit_log'
  ] loop
    execute format('alter table %I enable row level security', t);
    -- FORCE so a connection using the table owner cannot bypass policies.
    execute format('alter table %I force row level security', t);
  end loop;
end $$;


-- ---------------------------------------------------------------------
-- household / profile
-- ---------------------------------------------------------------------
create policy household_read on household
  for select using (id = app_household_id());

create policy household_write on household
  for update using (id = app_household_id() and app_is_owner())
          with check (id = app_household_id());

-- A user always sees their own row; owners see the whole household.
create policy profile_read on profile
  for select using (id = auth.uid() or household_id = app_household_id());

create policy profile_owner_write on profile
  for all using (household_id = app_household_id() and app_is_owner())
      with check (household_id = app_household_id() and app_is_owner());

-- ---------------------------------------------------------------------
-- Owner-writable reference & money tables.
-- Read for all household members, write for owners only.
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array[
    'category','earner','wage_rate','budget_period','income','account',
    'debt_detail','debt_balance','bank','category_keyword'
  ] loop
    execute format($f$
      create policy %1$s_read on %1$s
        for select using (household_id = app_household_id());
      create policy %1$s_owner_write on %1$s
        for all using (household_id = app_household_id() and app_is_owner())
            with check (household_id = app_household_id() and app_is_owner());
    $f$, t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- budget_line — the shared write surface
-- ---------------------------------------------------------------------
create policy budget_line_read on budget_line
  for select using (household_id = app_household_id());

-- Any household member may update. WHICH columns is the trigger's job.
create policy budget_line_update on budget_line
  for update using (household_id = app_household_id())
          with check (household_id = app_household_id());

-- Only owners create or remove lines (materialize_period is SECURITY
-- DEFINER, so scheduled sync still works regardless of who triggers it).
create policy budget_line_owner_insert on budget_line
  for insert with check (household_id = app_household_id() and app_is_owner());

create policy budget_line_owner_delete on budget_line
  for delete using (household_id = app_household_id() and app_is_owner());

-- ---------------------------------------------------------------------
-- statement_txn — both spouses may import and categorize
-- ---------------------------------------------------------------------
create policy statement_txn_read on statement_txn
  for select using (household_id = app_household_id());
create policy statement_txn_write on statement_txn
  for all using (household_id = app_household_id())
      with check (household_id = app_household_id());

-- ---------------------------------------------------------------------
-- audit_log — readable by owners, never writable from the client
-- ---------------------------------------------------------------------
create policy audit_read on audit_log
  for select using (household_id = app_household_id() and app_is_owner());

-- ---------------------------------------------------------------------
-- Grants. Supabase exposes tables to `authenticated` via PostgREST;
-- RLS above is what actually constrains them.
-- ---------------------------------------------------------------------
grant usage on schema public to authenticated;
grant select on all tables in schema public to authenticated;
grant insert, update, delete on
  category, earner, wage_rate, budget_period, income, account, debt_detail,
  debt_balance, bank, category_keyword, budget_line, statement_txn
  to authenticated;
grant update on household to authenticated;
grant usage on all sequences in schema public to authenticated;

-- The anon role gets nothing at all.
revoke all on all tables in schema public from anon;
