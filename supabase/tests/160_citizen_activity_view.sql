-- 5-tab build (Citizens page): list_citizen_report_activity() — commander/admin-only
-- aggregate of who has reported what, since profiles_self_read doesn't let
-- commander read other citizens' full_name directly.

create or replace function as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p::text, 'role', 'authenticated')::text, false);
end $$;

create or replace function as_service() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{}', false);
end $$;

reset role;
select as_service();

insert into auth.users (id, email) values
  ('c1111111-1111-1111-1111-111111111111','t160-citizen@x.com'),
  ('c2222222-2222-2222-2222-222222222222','t160-commander@x.com'),
  ('c3333333-3333-3333-3333-333333333333','t160-officer@x.com')
on conflict do nothing;

insert into profiles (id, role, ward_id, full_name) values
  ('c1111111-1111-1111-1111-111111111111','citizen',null,'T160 Citizen'),
  ('c2222222-2222-2222-2222-222222222222','commander',null,'T160 Commander'),
  ('c3333333-3333-3333-3333-333333333333','field_officer',null,'T160 Officer')
on conflict (id) do update set role=excluded.role, ward_id=excluded.ward_id, full_name=excluded.full_name;

grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;

insert into reports (reporter_id, ward_id, description, status)
values
  ('c1111111-1111-1111-1111-111111111111', null, 't160 report one', 'submitted'),
  ('c1111111-1111-1111-1111-111111111111', null, 't160 report two', 'submitted');

\echo ' TEST 161: commander sees an aggregated row for the citizen with the right report_count'
set role authenticated;
select as_user('c2222222-2222-2222-2222-222222222222'); -- commander
do $$
declare v_count bigint;
begin
  select report_count into v_count
  from list_citizen_report_activity()
  where reporter_id = 'c1111111-1111-1111-1111-111111111111';
  if v_count = 2 then
    raise notice '161 PASS: commander sees report_count=2 for the test citizen';
  else
    raise exception 'TEST 161 FAIL: expected report_count=2, got %', v_count;
  end if;
end $$;
reset role;
select as_service();

\echo ' TEST 162: citizen calling list_citizen_report_activity() gets zero rows (not an error - the inline role check just excludes them)'
set role authenticated;
select as_user('c1111111-1111-1111-1111-111111111111'); -- citizen
do $$
declare v_count int;
begin
  select count(*) into v_count from list_citizen_report_activity();
  if v_count = 0 then
    raise notice '162 PASS: citizen reads zero rows from list_citizen_report_activity()';
  else
    raise exception 'TEST 162 FAIL: citizen read % rows', v_count;
  end if;
end $$;
reset role;
select as_service();

\echo ' TEST 163: field_officer calling list_citizen_report_activity() also gets zero rows'
set role authenticated;
select as_user('c3333333-3333-3333-3333-333333333333'); -- field_officer
do $$
declare v_count int;
begin
  select count(*) into v_count from list_citizen_report_activity();
  if v_count = 0 then
    raise notice '163 PASS: field_officer reads zero rows from list_citizen_report_activity()';
  else
    raise exception 'TEST 163 FAIL: field_officer read % rows', v_count;
  end if;
end $$;
reset role;
select as_service();

\echo 'All citizen_activity_view tests passed.'
