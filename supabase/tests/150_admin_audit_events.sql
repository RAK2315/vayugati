-- Phase 11: admin_audit_events — immutable administrative audit trail for
-- field-officer onboarding/deactivation (supabase/scripts/onboard_field_officer.py).

create table if not exists t_ids (k text primary key, v bigint);
grant select on t_ids to authenticated;
truncate t_ids;

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
  ('b1111111-1111-1111-1111-111111111111','t150-citizen@x.com'),
  ('b2222222-2222-2222-2222-222222222222','t150-commander@x.com')
on conflict do nothing;

insert into profiles (id, role, ward_id, full_name) values
  ('b1111111-1111-1111-1111-111111111111','citizen',null,'T150 Citizen'),
  ('b2222222-2222-2222-2222-222222222222','commander',null,'T150 Commander')
on conflict (id) do update set role=excluded.role, ward_id=excluded.ward_id, full_name=excluded.full_name;

grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;

\echo ' TEST 151: service_role can write an admin_audit_events row (the onboarding scripts own write path)'
insert into admin_audit_events (event_type, actor, target_email, city_id, ward_id, details)
values ('field_officer_onboarded', 'test fixture', 't150-officer@example.com', null, null, '{"name":"Test Officer"}'::jsonb);
do $$
declare v_count int;
begin
  select count(*) into v_count from admin_audit_events where target_email = 't150-officer@example.com';
  if v_count = 1 then
    raise notice '151 PASS: service_role write succeeded, exactly one row';
  else
    raise exception 'TEST 151 FAIL: expected 1 row, got %', v_count;
  end if;
end $$;

\echo ' TEST 152: commander/admin can read admin_audit_events; citizen cannot'
set role authenticated;
select as_user('b2222222-2222-2222-2222-222222222222'); -- commander
do $$
declare v_count int;
begin
  select count(*) into v_count from admin_audit_events;
  if v_count >= 1 then
    raise notice '152a PASS: commander reads a non-empty admin_audit_events';
  else
    raise exception 'TEST 152a FAIL: commander read 0 rows';
  end if;
end $$;
reset role;
select as_service();

set role authenticated;
select as_user('b1111111-1111-1111-1111-111111111111'); -- citizen
do $$
declare v_count int;
begin
  select count(*) into v_count from admin_audit_events;
  if v_count = 0 then
    raise notice '152b PASS: citizen reads zero admin_audit_events rows';
  else
    raise exception 'TEST 152b FAIL: citizen read % rows', v_count;
  end if;
end $$;
reset role;
select as_service();

\echo ' TEST 153: no authenticated role can write admin_audit_events directly (service_role/script is the only write path)'
set role authenticated;
select as_user('b2222222-2222-2222-2222-222222222222'); -- commander
do $$
begin
  begin
    insert into admin_audit_events (event_type, actor, target_email)
    values ('field_officer_onboarded', 'direct commander attempt', 'should-fail@example.com');
    raise exception 'TEST 153 FAIL: a direct authenticated INSERT succeeded';
  exception when insufficient_privilege then
    raise notice '153 PASS: direct authenticated INSERT correctly refused (insufficient_privilege)';
  end;
end $$;
reset role;
select as_service();

\echo ' TEST 154: admin_audit_events has no update/delete policy at all — rows are immutable once written'
select 1 from pg_policies where tablename = 'admin_audit_events' and cmd in ('UPDATE', 'DELETE');
do $$
declare v_count int;
begin
  select count(*) into v_count from pg_policies where tablename = 'admin_audit_events' and cmd in ('UPDATE', 'DELETE');
  if v_count = 0 then
    raise notice '154 PASS: no update/delete policy exists on admin_audit_events — genuinely append-only';
  else
    raise exception 'TEST 154 FAIL: found % update/delete polic(y/ies) on admin_audit_events', v_count;
  end if;
end $$;

\echo 'All admin_audit_events tests passed.'
