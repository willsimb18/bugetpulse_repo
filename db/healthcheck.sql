with checks as (
  select 1 ord, 'Tables with RLS + policies' item,
         count(*) filter (where c.relrowsecurity and pol.n > 0)::text || ' of ' || count(*)::text val,
         (count(*) = count(*) filter (where c.relrowsecurity and pol.n > 0)) ok
  from pg_class c
  join pg_namespace ns on ns.oid = c.relnamespace
  left join lateral (select count(*) n from pg_policy p where p.polrelid = c.oid) pol on true
  -- schema_migrations is migration bookkeeping, not app data. It has RLS
  -- on with no policies by design, so exclude it rather than have the
  -- check report a permanent false alarm.
  where ns.nspname = 'public' and c.relkind = 'r'
    and c.relname <> 'schema_migrations'

  union all select 2, 'Login accounts', count(*)::text, count(*) >= 2 from auth.users
  union all select 3, 'Households',     count(*)::text, count(*) = 1  from household
  union all select 4, 'Profiles linked',count(*)::text, count(*) >= 2 from profile
  union all select 5, 'Earners',        count(*)::text, count(*) >= 1 from earner
  union all select 6, 'Pay periods',    count(*)::text, count(*) >= 1 from budget_period
  union all select 7, 'Pay rates on file', count(*)::text, count(*) >= 1 from wage_rate
  union all select 8, 'Accounts (bills/expenses/debts)', count(*)::text, count(*) >= 1 from account
  union all select 9, 'Budget lines',   count(*)::text, count(*) >= 1 from budget_line
  union all select 10,'Income recorded',count(*)::text, count(*) >= 1 from income
)
select case when ok then 'OK' else 'TODO' end as status, item, val as count
from checks order by ord;
