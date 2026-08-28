# Setting up BudgetPulse on your iMac

Everything below is copy-paste into **Terminal** (⌘-Space, type "Terminal").

---

## 1. Install Node

Check whether you already have it:

```bash
node -v
```

If that prints `v20.x` or higher, skip ahead. Otherwise install Homebrew, then Node:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install node
node -v
```

On Apple Silicon, Homebrew will tell you to add itself to your PATH — run the two `echo`/`eval` lines it prints, then reopen Terminal.

---

## 2. Create the Supabase project

1. Go to **supabase.com** → sign up → **New project**.
2. Name it `budgetpulse`. Region: **East US (North Virginia)** — closest to Florida.
3. Set a database password. Put it in your password manager; you'll need it for the migration.
4. Wait ~2 minutes for it to provision.

**Upgrade to Pro ($25/mo).** The free tier pauses a project after 7 days idle, so an app you open every other Friday would be asleep every time you reach for it. Pro also gives point-in-time recovery.

---

## 3. Run the SQL

Supabase → **SQL Editor** → New query. Paste and run each file in order, one at a time:

```
01_schema.sql
02_functions.sql
03_rls.sql
04_views.sql
05_admin.sql
```

Each should finish with no errors. Then `06_bootstrap.sql`. Edit the six values at the top (two emails, two names, household name, anchor date) and Run. It looks your logins up by email, so there are no UUIDs to copy. Safe to run again if you want to change a name.

Also turn on:
- **Database → Extensions →** enable `pg_cron` (for the nightly refresh)
- **Database → Replication →** enable realtime on `budget_line` (so your screens sync)
- **Authentication → Sign In / Providers →** turn **off** "Allow new users to sign up"

---

## 4. Get the two keys

Supabase → **Project Settings** → **API**. Two values:

| On that page | Goes into |
|---|---|
| **Project URL** | `VITE_SUPABASE_URL` |
| **anon / public** key | `VITE_SUPABASE_ANON_KEY` |

There's also a `service_role` key on that page. **Don't use it here.** It bypasses every security rule in `03_rls.sql`, and anything named `VITE_*` gets compiled into the JavaScript your browser downloads — so it would be public. The anon key is designed to be public; row-level security is what protects the data.

---

## 5. Run the app

```bash
cd ~/Downloads/app
npm install
cp .env.example .env
open -e .env          # paste the two values, save, close
npm run dev
```

Open **http://localhost:5173** and sign in with the email/password you created in step 3.

---

## 6. Put it online so your wife can use it

Local only works on your iMac. To get it on her phone:

```bash
npm install -g vercel
vercel login
vercel --prod
```

Vercel asks a few questions — accept the defaults. When it finishes it prints a URL.

Then add the env vars there:

```bash
vercel env add VITE_SUPABASE_URL production
vercel env add VITE_SUPABASE_ANON_KEY production
vercel --prod
```

Send her the URL. On her iPhone: open it in Safari → **Share** → **Add to Home Screen**. It launches like a normal app, no App Store involved. Same on your iMac in Chrome: the install icon appears in the address bar.

---

## 7. Migrate your SQL Server data

```bash
pip3 install pyodbc "psycopg[binary]"

export MSSQL_CONN='DRIVER={ODBC Driver 18 for SQL Server};SERVER=<your-server>;DATABASE=Finance;UID=<user>;PWD=<pass>;TrustServerCertificate=yes'
export SUPABASE_DB_URL='postgresql://postgres:<db-password>@db.<ref>.supabase.co:5432/postgres'
export HOUSEHOLD_ID='<the uuid from step 3>'

python3 migrate.py --dry-run     # reads and transforms, writes nothing
python3 migrate.py               # loads
```

`--dry-run` prints what it would insert and rolls back. Look at the `budget_line_unresolved` count — anything above 0 means some `Budget` rows point at a Bill or Expense that no longer exists.

The ODBC driver, if you don't have it:
```bash
brew tap microsoft/mssql-release https://github.com/Microsoft/homebrew-mssql-release
brew install msodbcsql18
```

---

## Common snags

**"Missing VITE_SUPABASE_URL"** — `.env` isn't saved, or it's in the wrong folder. It goes next to `package.json`.

**Signed in but "not linked to a household"** — the `profile` row for that user is missing, or its UUID doesn't match. Re-check step 3 of `06_bootstrap.sql`.

**Login works, screens are empty** — no pay periods yet. Run `generate_budget_periods`, then `refresh_household_amounts`.

**Changes don't appear on the other person's screen** — realtime isn't enabled on `budget_line`.

**Your wife sees "permission denied" on something** — that's working as intended. Members mark things paid; owners change amounts. Change her `profile.role` to `owner` if you want her to have full control.
