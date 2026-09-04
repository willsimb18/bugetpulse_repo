-- =====================================================================
-- Turn on realtime for budget_line, so the two of you see each other's
-- payments without refreshing.
--
-- usePeriod.ts subscribes to postgres_changes on this table, filtered to
-- the period on screen. Without the table in the publication that
-- subscription connects, reports success, and then simply never fires —
-- which looks like the app working, not like a setting being off.
--
-- Two statements, and the second is the one the dashboard toggle does not
-- do for you. Safe to run twice.
-- =====================================================================

-- 1. Add the table to the realtime publication.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'budget_line'
  ) then
    alter publication supabase_realtime add table budget_line;
    raise notice 'budget_line added to supabase_realtime.';
  else
    raise notice 'budget_line was already in supabase_realtime.';
  end if;
end $$;

-- 2. REPLICA IDENTITY FULL.
--
-- budget_line is behind RLS. To decide whether YOU are allowed to see an
-- UPDATE or DELETE, realtime has to check the row as it was BEFORE the
-- change — and with the default replica identity the WAL carries only the
-- primary key of the old row, so that check cannot be made and the event
-- is dropped. FULL puts the whole old row in the WAL.
--
-- The cost is a little more WAL per write, which for a household budget
-- is nothing.
alter table budget_line replica identity full;


-- Confirm: one row, and replica identity 'f'.
select
  (select count(*) from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public' and tablename = 'budget_line') as in_publication,
  (select relreplident from pg_class where oid = 'public.budget_line'::regclass)
    as replica_identity;
