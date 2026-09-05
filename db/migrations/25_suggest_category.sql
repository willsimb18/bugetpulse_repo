-- =====================================================================
-- 25 — Suggest a category for a one-off expense.
--
-- The one-off form sent p_category_id => null every time, so every
-- expense added by hand landed uncategorised — and then showed as
-- "Uncategorised" in the donut and in the category column beside it.
--
-- category_keyword has held 142 rows since the import and nothing has
-- ever read them. They came from Finance's Keywords table, which is
-- exactly this: a word, and the category it implies.
--
-- Two sources, best first, because they are not equally trustworthy:
--
--   history  the same expense name has been used before and was filed
--            somewhere. That is a decision already made, so it wins.
--   keyword  a keyword appears in the name. A guess, and said as one.
--
-- Returns at most one row. No match returns nothing rather than a null
-- category, so the caller can tell "no idea" from "deliberately none".
-- =====================================================================

create or replace function suggest_category(p_name text)
returns table (
  category_id   bigint,
  category_name text,
  source        text,
  matched_on    text
)
language plpgsql stable security invoker
set search_path = public, pg_temp as $$
declare
  hh uuid;
  nm text := lower(btrim(coalesce(p_name, '')));
begin
  if nm = '' then return; end if;
  hh := coalesce(app_household_id(), (select id from household limit 1));
  if hh is null then return; end if;

  -- 1. Filed under something before, under this exact name.
  return query
  select c.id,
         case when c.parent_id is null then c.name
              else parent.name || ' / ' || c.name end,
         'history'::text,
         l.name
  from budget_line l
  join category c        on c.id = l.category_id
  left join category parent on parent.id = c.parent_id
  where l.household_id = hh
    and lower(btrim(l.name)) = nm
    and l.category_id is not null
  order by l.due_date desc, l.id desc
  limit 1;

  if found then return; end if;

  -- 2. A keyword appears in the name. Longest match first — "car wash"
  --    beats "car" — then whatever priority says.
  --
  --    position() rather than LIKE: a keyword containing % or _ would
  --    otherwise be read as a pattern and match far too much.
  return query
  select c.id,
         case when c.parent_id is null then c.name
              else parent.name || ' / ' || c.name end,
         'keyword'::text,
         k.keyword
  from category_keyword k
  join category c        on c.id = k.category_id
  left join category parent on parent.id = c.parent_id
  where k.household_id = hh
    and btrim(k.keyword) <> ''
    and position(lower(btrim(k.keyword)) in nm) > 0
  order by length(btrim(k.keyword)) desc, k.priority desc, k.id
  limit 1;
end $$;

revoke execute on function suggest_category(text) from public, anon;
grant  execute on function suggest_category(text) to authenticated;
