-- =====================================================================
-- 26 — Prefer a keyword that STARTS the name.
--
-- The keyword branch matched anywhere in the name, so a short word turned
-- up inside longer unrelated ones: 'car' catching "Carpet cleaning",
-- 'dinner' catching things that merely mention one. What people mean when
-- they name an expense is almost always at the front — "Dinner out",
-- "Dinner with the Smiths" — so a keyword at the start is a far stronger
-- signal than the same keyword buried mid-string.
--
-- Prefix matches now outrank contains matches. Within each, the longest
-- keyword still wins, then priority.
--
-- Contains is kept as the lower rank rather than dropped. The 142
-- keywords that came from Finance were written for matching against
-- transaction descriptions, where the word is rarely first; removing it
-- outright would have quietly stopped most of them ever firing. Say the
-- word and the `or position(...)` becomes a strict prefix.
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

  -- 2. A keyword. One that starts the name beats one merely inside it;
  --    then the longest; then priority.
  --
  --    left(nm, length(k)) = k rather than LIKE k || '%': a keyword
  --    containing % or _ would otherwise be read as a pattern.
  return query
  select c.id,
         case when c.parent_id is null then c.name
              else parent.name || ' / ' || c.name end,
         case when left(nm, length(btrim(lower(k.keyword)))) = btrim(lower(k.keyword))
              then 'keyword (starts with)' else 'keyword' end::text,
         k.keyword
  from category_keyword k
  join category c        on c.id = k.category_id
  left join category parent on parent.id = c.parent_id
  where k.household_id = hh
    and btrim(k.keyword) <> ''
    and position(lower(btrim(k.keyword)) in nm) > 0
  order by
    (left(nm, length(btrim(lower(k.keyword)))) = btrim(lower(k.keyword))) desc,
    length(btrim(k.keyword)) desc,
    k.priority desc,
    k.id
  limit 1;
end $$;

revoke execute on function suggest_category(text) from public, anon;
grant  execute on function suggest_category(text) to authenticated;
