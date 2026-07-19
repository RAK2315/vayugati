-- Phase 11 hotfix: profile role/ward self-elevation is now blocked.
--
-- Found by manually walking the real hosted Vercel deployment: neither
-- profiles_self_update nor profiles_insert_self (schema.sql) ever
-- restricted WHICH COLUMNS a self-scoped write could touch, only WHICH
-- ROW. Any self-registered citizen could PATCH their own role to 'admin'
-- directly via the REST API. This file proves the new trigger
-- (20260727000000_profile_role_immutability.sql) closes that gap without
-- breaking any legitimate write path.

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
  ('a1111111-1111-1111-1111-111111111111','t140-citizen@x.com'),
  ('a2222222-2222-2222-2222-222222222222','t140-admin@x.com'),
  ('a3333333-3333-3333-3333-333333333333','t140-brandnew@x.com')
on conflict do nothing;

insert into profiles (id, role, ward_id, full_name) values
  ('a1111111-1111-1111-1111-111111111111','citizen',null,'T140 Citizen'),
  ('a2222222-2222-2222-2222-222222222222','admin',null,'T140 Admin')
on conflict (id) do update set role=excluded.role, ward_id=excluded.ward_id, full_name=excluded.full_name;

grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;

\echo ' TEST 141: a citizen cannot self-elevate their own role via UPDATE'
set role authenticated;
select as_user('a1111111-1111-1111-1111-111111111111');
do $$
begin
  begin
    update profiles set role = 'admin' where id = 'a1111111-1111-1111-1111-111111111111';
    raise exception 'TEST 141 FAIL: self role-elevation via UPDATE was not blocked';
  exception when others then
    if sqlerrm like '%cannot change your own role%' then
      raise notice '141 PASS: self role-elevation via UPDATE correctly rejected (%)', sqlerrm;
    else
      raise exception 'TEST 141 FAIL: wrong error: %', sqlerrm;
    end if;
  end;
end $$;
reset role;
select as_service();

\echo ' TEST 142: a citizen cannot self-assign a ward via UPDATE'
set role authenticated;
select as_user('a1111111-1111-1111-1111-111111111111');
do $$
begin
  begin
    update profiles set ward_id = 1 where id = 'a1111111-1111-1111-1111-111111111111';
    raise exception 'TEST 142 FAIL: self ward-assignment via UPDATE was not blocked';
  exception when others then
    if sqlerrm like '%cannot change your own ward assignment%' then
      raise notice '142 PASS: self ward-assignment via UPDATE correctly rejected (%)', sqlerrm;
    else
      raise exception 'TEST 142 FAIL: wrong error: %', sqlerrm;
    end if;
  end;
end $$;
reset role;
select as_service();

\echo ' TEST 143: a citizen CAN still update their own other columns (e.g. full_name)'
set role authenticated;
select as_user('a1111111-1111-1111-1111-111111111111');
update profiles set full_name = 'T140 Citizen Renamed' where id = 'a1111111-1111-1111-1111-111111111111';
do $$
declare v_name text;
begin
  select full_name into v_name from profiles where id = 'a1111111-1111-1111-1111-111111111111';
  if v_name = 'T140 Citizen Renamed' then
    raise notice '143 PASS: non-role/ward self-update still works (full_name updated)';
  else
    raise exception 'TEST 143 FAIL: full_name update did not take effect (got %)', v_name;
  end if;
end $$;
reset role;
select as_service();

\echo ' TEST 144: a brand-new self-registered account cannot insert itself as admin'
set role authenticated;
select as_user('a3333333-3333-3333-3333-333333333333');
do $$
begin
  begin
    insert into profiles (id, role) values ('a3333333-3333-3333-3333-333333333333', 'admin');
    raise exception 'TEST 144 FAIL: self-insert with role=admin was not blocked';
  exception when others then
    if sqlerrm like '%New accounts start as citizen%' then
      raise notice '144 PASS: self-insert with an elevated role correctly rejected (%)', sqlerrm;
    else
      raise exception 'TEST 144 FAIL: wrong error: %', sqlerrm;
    end if;
  end;
end $$;
reset role;
select as_service();

\echo ' TEST 145: a brand-new self-registered account cannot insert itself with a ward already set'
set role authenticated;
select as_user('a3333333-3333-3333-3333-333333333333');
do $$
begin
  begin
    insert into profiles (id, ward_id) values ('a3333333-3333-3333-3333-333333333333', 1);
    raise exception 'TEST 145 FAIL: self-insert with ward_id set was not blocked';
  exception when others then
    if sqlerrm like '%Ward assignment is set by an administrator%' then
      raise notice '145 PASS: self-insert with a ward already set correctly rejected (%)', sqlerrm;
    else
      raise exception 'TEST 145 FAIL: wrong error: %', sqlerrm;
    end if;
  end;
end $$;
reset role;
select as_service();

\echo ' TEST 146: the real signup path (id only, default role) still succeeds'
set role authenticated;
select as_user('a3333333-3333-3333-3333-333333333333');
insert into profiles (id) values ('a3333333-3333-3333-3333-333333333333');
do $$
declare v_role user_role;
begin
  select role into v_role from profiles where id = 'a3333333-3333-3333-3333-333333333333';
  if v_role = 'citizen' then
    raise notice '146 PASS: real signup path (id only) still creates a citizen profile';
  else
    raise exception 'TEST 146 FAIL: expected citizen, got %', v_role;
  end if;
end $$;
reset role;
select as_service();

\echo ' TEST 147: an existing admin may still change their own role/ward (no regression)'
set role authenticated;
select as_user('a2222222-2222-2222-2222-222222222222');
update profiles set ward_id = 1 where id = 'a2222222-2222-2222-2222-222222222222';
do $$
declare v_ward int;
begin
  select ward_id into v_ward from profiles where id = 'a2222222-2222-2222-2222-222222222222';
  if v_ward = 1 then
    raise notice '147 PASS: an existing admin can still change their own ward_id';
  else
    raise exception 'TEST 147 FAIL: admin self-update of ward_id did not take effect';
  end if;
end $$;
reset role;
select as_service();

\echo ' TEST 148: the service_role (backend) connection is completely unaffected'
update profiles set role = 'field_officer', ward_id = 1 where id = 'a1111111-1111-1111-1111-111111111111';
do $$
declare v_role user_role;
begin
  select role into v_role from profiles where id = 'a1111111-1111-1111-1111-111111111111';
  if v_role = 'field_officer' then
    raise notice '148 PASS: service_role backend context can still set role/ward freely (real onboarding path)';
  else
    raise exception 'TEST 148 FAIL: service_role write did not take effect';
  end if;
end $$;

\echo ' TEST 149: a superuser fixture updating a different users row is unaffected, even with a stale impersonated auth.uid() left over from an earlier as_user() call'
-- Reproduces exactly the scenario that first broke 110_production_hardening.sql
-- TEST 117: an earlier as_user() call in the same session (never followed by
-- as_service()) leaves request.jwt.claims pointing at some other user —
-- reset role alone does NOT clear it (a known, documented gotcha in this
-- test suite). A backend fixture then updates a DIFFERENT user's row while
-- superuser (RLS bypassed) — this must succeed, since it is not a
-- self-referential write, regardless of the stale auth.uid().
select as_user('a1111111-1111-1111-1111-111111111111'); -- citizen, non-admin
reset role; -- superuser again, but request.jwt.claims is still set to the citizen above
update profiles set ward_id = 1 where id = 'a2222222-2222-2222-2222-222222222222'; -- a DIFFERENT row
do $$
declare v_ward int;
begin
  select ward_id into v_ward from profiles where id = 'a2222222-2222-2222-2222-222222222222';
  if v_ward = 1 then
    raise notice '149 PASS: updating a different row succeeds even with a stale non-admin auth.uid() left over';
  else
    raise exception 'TEST 149 FAIL: cross-user superuser fixture update was incorrectly blocked';
  end if;
end $$;
select as_service();

\echo 'All profile-role-immutability tests passed.'
