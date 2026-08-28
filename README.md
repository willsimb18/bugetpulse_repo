# BudgetPulse

Household budget for two people. React PWA on Supabase.

Pushing to `main` applies database migrations and deploys the app. You should not need to open the Supabase SQL Editor again after setup.

```
app/                    the PWA
db/migrations/          numbered SQL, applied in order, each exactly once
db/optional/            starter data + the SQL Server importer (run by hand)
db/migrate.sh           the runner
db/healthcheck.sql      one query that reports setup state
.github/workflows/      migrate on push, build check on PR
```

---

## One-time setup

### 0. Backfill the migration ledger (only if you already ran SQL by hand)

If you applied `01`–`07` and `10` in the Supabase SQL Editor, the runner's
ledger is empty and its first run would try to apply them again — failing
on `type "frequency" already exists`. Run this once, in the SQL Editor:

    db/optional/00_backfill_migrations.sql

Skip it on a brand-new Supabase project.

### 1. Push the code

On github.com → **New repository** → name it `budgetpulse` → **Private**. Don't add a README; you already have one.

Then, in the folder holding `app/` and `db/`:

```bash
git init
git add .
git commit -m "BudgetPulse: app and database"
git branch -M main
git remote add origin https://github.com/willsimb18/bugetpulse_repo.git
git push -u origin main
```

If git asks for a password, GitHub wants a **personal access token**, not your account password: github.com → Settings → Developer settings → Personal access tokens → Fine-grained → give it access to this one repo with Contents: read and write. Paste the token where it asks for a password.

### 2. Give Actions your database connection string

Supabase → Project Settings → **Database** → Connection string → **Session pooler** (IPv4-friendly; the direct connection often isn't reachable from CI). Swap `[YOUR-PASSWORD]` for your real database password.

GitHub → your repo → **Settings** → Secrets and variables → **Actions** → New repository secret:

- Name: `SUPABASE_DB_URL`
- Value: the full `postgresql://...` string

This secret is write-only — nobody, including you, can read it back afterwards. It is not the anon key and must never appear in `app/`.

### 3. Connect Vercel

vercel.com → Add New → **Project** → import the repo.

- Root Directory: `app`
- Framework: Vite (auto-detected)

Environment Variables:

| Name | Value |
|---|---|
| `VITE_SUPABASE_URL` | Supabase → Settings → API → Project URL |
| `VITE_SUPABASE_ANON_KEY` | Supabase → Settings → API → anon / public key |

Deploy. Every push to `main` rebuilds automatically. **No Node needed on your Mac.**

---

## After that

To change the database, add a file to `db/migrations/` and push:

```bash
git add db/migrations/11_whatever.sql
git commit -m "Add whatever"
git push
```

Actions → "Apply database migrations" shows what ran, and prints the health check at the end.

### Rules that keep this safe

**Never edit a migration that has already run.** The runner records a checksum per file; if an applied file changes it warns and refuses to re-run, because re-running is how two environments silently drift apart. Add a new numbered file instead.

**Numbers only go up.** `11`, `12`, `13`… Files apply in filename order.

**Each file runs in a single transaction.** A failure rolls that file back and stops the run, so you never end up half-migrated.

### Running things by hand

The two files in `db/optional/` are deliberately outside the migration path — one is example data, the other needs your on-prem SQL Server:

```bash
# starter data, to see the app working before migrating for real
psql "$SUPABASE_DB_URL" -f db/optional/09_seed_example.sql

# import from the old Finance database
export MSSQL_CONN='DRIVER={ODBC Driver 18 for SQL Server};SERVER=...;DATABASE=Finance;UID=...;PWD=...;TrustServerCertificate=yes'
export HOUSEHOLD_ID='<from the health check>'
python3 db/optional/import_from_sqlserver.py --dry-run
```

### Checking state at any time

```bash
psql "$SUPABASE_DB_URL" -f db/healthcheck.sql
```

Or just look at the tail of the last Actions run.

---

## What is where

| Thing | File |
|---|---|
| Tables, enums, constraints | `db/migrations/01_schema.sql` |
| Pay periods, materialization, mark-paid | `02_functions.sql` |
| Row-level security | `03_rls.sql` |
| Reporting views | `04_views.sql` |
| Raises, bill changes, corrections, funding | `05_admin.sql` |
| Household + calendar bootstrap | `06_bootstrap.sql` |
| Creating bills/debts, permission hardening | `07_manage.sql` |
| Debt balances from statements | `10_debt.sql` |

## Secrets, in one place

| Secret | Lives in | Never in |
|---|---|---|
| Database password / `SUPABASE_DB_URL` | GitHub Actions secret | the repo, `app/`, any `VITE_*` |
| `service_role` key | nowhere — not needed | anywhere at all |
| anon key | Vercel env var | fine to be public; RLS is the protection |

Anything named `VITE_*` is compiled into the JavaScript the browser downloads. Treat it as public.
