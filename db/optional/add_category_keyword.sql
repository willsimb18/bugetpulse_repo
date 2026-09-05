-- =====================================================================
-- Teach the suggester a word.
--
-- suggest_category() falls back to category_keyword when it has no
-- history for a name. The table came across from Finance's Keywords with
-- 142 rows; this adds to it.
--
-- Edit the two values in STEP 1 and run the file. It adds the keyword,
-- then re-runs the backfill so anything uncategorised in the current
-- period picks it up straight away.
--
-- Matching is "keyword appears anywhere in the name", case-insensitive,
-- longest match winning. So 'dinner' catches "Dinner out", "Team dinner"
-- and "Anniversary Dinner" — worth a thought before adding a short word
-- that turns up inside longer unrelated ones.
-- =====================================================================

do $$
declare
  -- ================= CONFIGURE — edit these two =================
  v_keyword  text := 'dinner';
  v_category text := 'Food';     -- the category name, as it reads in the app
  -- ==============================================================
  v_hh   uuid;
  v_cat  bigint;
  v_n    int;
begin
  v_hh := coalesce(app_household_id(), (select id from household limit 1));
  if v_hh is null then raise exception 'No household.'; end if;

  if btrim(v_keyword) = '' then
    raise exception 'v_keyword is empty.';
  end if;

  select count(*) into v_n
  from category
  where household_id = v_hh and lower(name) = lower(btrim(v_category));

  if v_n = 0 then
    raise exception
      'No category called "%". Create it first, or check the spelling — '
      'run: select name from category order by name;', v_category;
  end if;
  if v_n > 1 then
    raise exception
      'More than one category called "%". Two categories share that name, '
      'so which one is meant is ambiguous.', v_category;
  end if;

  select id into v_cat
  from category
  where household_id = v_hh and lower(name) = lower(btrim(v_category));

  insert into category_keyword (household_id, keyword, category_id)
  values (v_hh, lower(btrim(v_keyword)), v_cat)
  on conflict (household_id, keyword) do update
    set category_id = excluded.category_id;

  raise notice '"%" now suggests %.', lower(btrim(v_keyword)), v_category;
end $$;


-- ---------------------------------------------------------------------
-- Apply it to anything still uncategorised in the current period.
-- ---------------------------------------------------------------------
do $$
declare v_n int := 0;
begin
  update budget_line l
     set category_id = s.category_id
    from budget_period p,
         lateral suggest_category(l.name) s
   where p.id = l.budget_period_id
     and p.period_start <= current_date and current_date <= p.period_end
     and l.category_id is null
     and s.category_id is not null;
  get diagnostics v_n = row_count;
  raise notice 'Categorised % line(s) with it.', v_n;
end $$;


-- What the suggester now knows, and what is still uncategorised.
select keyword, (select name from category c where c.id = k.category_id) as category
from category_keyword k
where keyword in ('dinner') or keyword ilike '%dinner%'
order by keyword;

select l.name, l.kind, l.amount_due
from budget_line l
join budget_period p on p.id = l.budget_period_id
where p.period_start <= current_date and current_date <= p.period_end
  and l.category_id is null
order by l.name;
