-- =====================================================================
-- 24 — Change which category an account belongs to.
--
-- Nothing could. create_account takes a category, and after that the only
-- way to move an account was to edit the row by hand — which the app has
-- no path to, and which would leave the budget lines already sitting in
-- open periods still carrying the old one.
--
-- Those lines matter: budget_line.category_id is copied from the account
-- at materialisation, and the Budget tab's category column, its grouping
-- and the donut all read the LINE, not the account. Changing only the
-- account would leave this period grouped the old way and the next one
-- grouped the new way, with nothing on screen explaining the difference.
--
-- So open unpaid lines follow the account. Paid lines and closed periods
-- do not — a bill that was paid under "Utilities" was paid under
-- "Utilities", and re-filing history to match a decision made later
-- would quietly change what past periods say they were spent on.
-- =====================================================================

create or replace function set_account_category(
  p_account_id  bigint,
  p_category_id bigint default null
) returns account
language plpgsql security invoker
set search_path = public, pg_temp as $$
declare
  rec account;
  hh  uuid;
  n   int := 0;
begin
  perform require_owner();

  select household_id into hh from account where id = p_account_id;
  if hh is null then
    raise exception 'account % not found or not visible', p_account_id;
  end if;

  -- A category from another household would pass the FK and fail RLS in
  -- a much less obvious place later.
  if p_category_id is not null
     and not exists (select 1 from category
                      where id = p_category_id and household_id = hh) then
    raise exception 'category % is not in this household', p_category_id;
  end if;

  update account
     set category_id = p_category_id
   where id = p_account_id
   returning * into rec;

  update budget_line l
     set category_id = p_category_id
    from budget_period p
   where l.budget_period_id = p.id
     and l.account_id = p_account_id
     and l.status in ('scheduled', 'skipped')
     and l.amount_paid = 0
     and not p.is_closed
     and p.period_end >= current_date;
  get diagnostics n = row_count;

  raise notice 'Category set; % open line(s) followed.', n;
  return rec;
end $$;

revoke execute on function set_account_category(bigint, bigint) from public, anon;
grant  execute on function set_account_category(bigint, bigint) to authenticated;
