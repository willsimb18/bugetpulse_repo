-- =====================================================================
-- ONE-TIME BACKFILL — run this in the Supabase SQL Editor BEFORE the
-- first GitHub Actions run.
--
-- Why: you already applied 01-07 and 10 by hand. The Actions runner keeps
-- its own ledger in schema_migrations, which starts empty, so its first
-- run would try to apply all of them again. 01 would fail on "type
-- already exists", 03 on "policy already exists", and the run would stop.
--
-- This tells the runner those files are already in. The checksums match
-- the files in db/migrations as shipped; if you edited any of them
-- locally the runner will warn rather than re-run, which is safe.
--
-- Harmless to run twice.
-- =====================================================================

create table if not exists schema_migrations (
  filename    text primary key,
  applied_at  timestamptz not null default now(),
  checksum    text
);

alter table schema_migrations enable row level security;

insert into schema_migrations (filename, checksum) values
  ('01_schema.sql',    'a04ed64251d482d8'),
  ('02_functions.sql', 'da0e5b4456b7b820'),
  ('03_rls.sql',       'b287f577862ae480'),
  ('04_views.sql',     '8ebb9084b38891f4'),
  ('05_admin.sql',     'dacdb8dd914fcb57'),
  ('06_bootstrap.sql', '5cfba2d864a0a617'),
  ('07_manage.sql',    '0abbbff7e3c53097'),
  ('10_debt.sql',      'd3ac1e33109614b9')
on conflict (filename) do nothing;

revoke all on schema_migrations from anon, authenticated;

-- Should list all eight.
select filename, applied_at::date from schema_migrations order by filename;
