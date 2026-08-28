#!/usr/bin/env bash
# Apply any migration in db/migrations that hasn't been applied yet.
#
# Tracks what has run in a schema_migrations table, so this is safe to run
# on every push. Files are applied in filename order, each in its own
# transaction — a failure rolls that file back and stops, rather than
# leaving the database half-migrated.
set -euo pipefail

: "${SUPABASE_DB_URL:?SUPABASE_DB_URL is not set}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/migrations"

psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -q <<'SQL'
create table if not exists schema_migrations (
  filename    text primary key,
  applied_at  timestamptz not null default now(),
  checksum    text
);

-- RLS on with no policies: no client can read a row even if SELECT is
-- granted. The matching REVOKE runs at the END of this script, because
-- 03_rls.sql issues `grant select on all tables in schema public`, which
-- would otherwise re-grant it right after we took it away.
alter table schema_migrations enable row level security;
SQL

applied=0
skipped=0

for f in "$DIR"/*.sql; do
  name="$(basename "$f")"
  sum="$(sha256sum "$f" | cut -c1-16)"

  prev="$(psql "$SUPABASE_DB_URL" -tAc \
    "select checksum from schema_migrations where filename = '$name'")"

  if [ -n "$prev" ]; then
    if [ "$prev" != "$sum" ]; then
      # Editing an applied migration is a silent way to get environments
      # out of step. Add a new file instead.
      echo "::warning::$name changed after being applied ($prev -> $sum). Not re-running."
    fi
    skipped=$((skipped + 1))
    continue
  fi

  echo "--> applying $name"
  psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 --single-transaction -q -f "$f"
  psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -q -c \
    "insert into schema_migrations (filename, checksum) values ('$name', '$sum')"
  applied=$((applied + 1))
done

# Runs last, after any migration that may have issued a blanket grant.
psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -q <<'SQL'
revoke all on schema_migrations from anon, authenticated;
SQL

echo
echo "applied $applied, already up to date $skipped"
