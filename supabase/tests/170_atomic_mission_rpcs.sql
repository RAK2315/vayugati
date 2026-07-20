-- submit_mission_result / submit_field_completion — atomic, idempotent
-- replacements for the non-transactional client-side write sequences.
-- Self-contained fixtures (own incident/profiles/mission/action), not
-- dependent on earlier numbered test files' state.

create or replace function as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p::text, 'role', 'authenticated')::text, false);
end $$;

create or replace function as_service() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{}', false);
end $$;

create table if not exists t_ids (k text primary key, v bigint);
grant select on t_ids to authenticated;

reset role;
select as_service();

insert into auth.users (id, email) values
  ('d1111111-1111-1111-1111-111111111111','t170-officer1@x.com'),
  ('d2222222-2222-2222-2222-222222222222','t170-officer2-wrong-ward@x.com'),
  ('d3333333-3333-3333-3333-333333333333','t170-commander@x.com')
on conflict do nothing;

insert into profiles (id, role, ward_id, full_name) values
  ('d1111111-1111-1111-1111-111111111111','field_officer',1,'T170 Officer 1'),
  ('d2222222-2222-2222-2222-222222222222','field_officer',2,'T170 Officer 2 (wrong ward)'),
  ('d3333333-3333-3333-3333-333333333333','commander',null,'T170 Commander')
on conflict (id) do update set role=excluded.role, ward_id=excluded.ward_id, full_name=excluded.full_name;

grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;

do $$
declare
  v_inc       bigint;
  v_mission_a bigint;
  v_mission_b bigint;
  v_action_a  bigint;
  v_action_b  bigint;
begin
  insert into incidents (ward_id, status, detection_method, source_confidence, summary)
  values (1, 'evidence_gathering', 'manual', 'corroborated', 't170 test incident')
  returning id into v_inc;

  insert into evidence_missions (incident_id, mission_type, status, assigned_to, rationale)
  values (v_inc, 'field_photo', 'dispatched', 'd1111111-1111-1111-1111-111111111111', 't170 mission A')
  returning id into v_mission_a;

  insert into evidence_missions (incident_id, mission_type, status, assigned_to, rationale)
  values (v_inc, 'field_photo', 'dispatched', 'd1111111-1111-1111-1111-111111111111', 't170 mission B')
  returning id into v_mission_b;

  insert into actions (incident_id, ward_id, type, workflow_status, recommended_action, responsible_agency, custom_reason)
  values (v_inc, 1, 'inspect', 'assigned', 'Inspect site', 'MCD', 't170 test fixture, no playbook')
  returning id into v_action_a;

  insert into actions (incident_id, ward_id, type, workflow_status, recommended_action, responsible_agency, custom_reason)
  values (v_inc, 1, 'inspect', 'assigned', 'Inspect site', 'MCD', 't170 test fixture, no playbook')
  returning id into v_action_b;

  insert into t_ids (k, v) values
    ('t170_inc', v_inc), ('t170_mission_a', v_mission_a), ('t170_mission_b', v_mission_b),
    ('t170_action_a', v_action_a), ('t170_action_b', v_action_b)
  on conflict (k) do update set v = excluded.v;
end $$;

\echo ' TEST 171: assigned officer submits a mission result - atomic, all 3 writes land'
set role authenticated;
select as_user('d1111111-1111-1111-1111-111111111111');
do $$
declare
  v_inc bigint; v_mission_a bigint; v_key uuid := 'a0000000-0000-0000-0000-000000000171';
begin
  select v into v_inc from t_ids where k = 't170_inc';
  select v into v_mission_a from t_ids where k = 't170_mission_a';
  perform submit_mission_result(
    p_mission_id => v_mission_a, p_incident_id => v_inc, p_outcome => 'confirmed',
    p_checklist_response => '{"item1":true}'::jsonb, p_idempotency_key => v_key,
    p_lat => 28.6, p_lng => 77.2, p_notes => 'note'
  );
end $$;
reset role;
select as_service();
do $$
declare v_mission_a bigint; v_inc bigint; v_n int;
begin
  select v into v_mission_a from t_ids where k = 't170_mission_a';
  select v into v_inc from t_ids where k = 't170_inc';

  select count(*) into v_n from evidence_missions
   where id = v_mission_a and status = 'completed' and idempotency_key = 'a0000000-0000-0000-0000-000000000171';
  if v_n = 1 then raise notice '171a PASS: mission marked completed with the idempotency key stored';
  else raise exception '171a FAIL: mission not updated as expected'; end if;

  select count(*) into v_n from incident_evidence where payload->>'mission_id' = v_mission_a::text;
  if v_n = 1 then raise notice '171b PASS: exactly one incident_evidence row';
  else raise exception '171b FAIL: expected 1 incident_evidence row, got %', v_n; end if;

  select count(*) into v_n from incident_events
   where incident_id = v_inc and event_type = 'evidence_added' and payload->>'outcome' = 'confirmed';
  if v_n = 1 then raise notice '171c PASS: exactly one incident_events row';
  else raise exception '171c FAIL: expected 1 incident_events row, got %', v_n; end if;
end $$;

\echo ' TEST 172: replaying the SAME idempotency key is a true no-op'
set role authenticated;
select as_user('d1111111-1111-1111-1111-111111111111');
do $$
declare
  v_inc bigint; v_mission_a bigint; v_key uuid := 'a0000000-0000-0000-0000-000000000171';
begin
  select v into v_inc from t_ids where k = 't170_inc';
  select v into v_mission_a from t_ids where k = 't170_mission_a';
  perform submit_mission_result(
    p_mission_id => v_mission_a, p_incident_id => v_inc, p_outcome => 'confirmed',
    p_checklist_response => '{"item1":true}'::jsonb, p_idempotency_key => v_key,
    p_lat => 28.6, p_lng => 77.2, p_notes => 'note'
  );
end $$;
reset role;
select as_service();
do $$
declare v_mission_a bigint; v_inc bigint; v_n int;
begin
  select v into v_mission_a from t_ids where k = 't170_mission_a';
  select v into v_inc from t_ids where k = 't170_inc';

  select count(*) into v_n from incident_evidence where payload->>'mission_id' = v_mission_a::text;
  if v_n = 1 then raise notice '172a PASS: replay did not duplicate incident_evidence';
  else raise exception '172a FAIL: expected still 1 row after replay, got %', v_n; end if;

  select count(*) into v_n from incident_events where incident_id = v_inc and event_type = 'evidence_added';
  if v_n = 1 then raise notice '172b PASS: replay did not duplicate incident_events';
  else raise exception '172b FAIL: expected still 1 row after replay, got %', v_n; end if;
end $$;

\echo ' TEST 173: an officer who is not the assignee is refused (fresh mission, not yet closed)'
set role authenticated;
select as_user('d2222222-2222-2222-2222-222222222222');
do $$
declare v_inc bigint; v_mission_b bigint;
begin
  select v into v_inc from t_ids where k = 't170_inc';
  select v into v_mission_b from t_ids where k = 't170_mission_b';
  begin
    perform submit_mission_result(
      p_mission_id => v_mission_b, p_incident_id => v_inc, p_outcome => 'confirmed',
      p_checklist_response => '{}'::jsonb, p_idempotency_key => gen_random_uuid()
    );
    raise exception '173 FAIL: a non-assignee officer submitted a mission result';
  exception when insufficient_privilege then
    raise notice '173 PASS: non-assignee correctly refused (insufficient_privilege)';
  end;
end $$;
reset role;
select as_service();

\echo ' TEST 174: a DIFFERENT idempotency key on an already-closed mission is refused'
set role authenticated;
select as_user('d1111111-1111-1111-1111-111111111111');
do $$
declare v_inc bigint; v_mission_a bigint;
begin
  select v into v_inc from t_ids where k = 't170_inc';
  select v into v_mission_a from t_ids where k = 't170_mission_a';
  begin
    perform submit_mission_result(
      p_mission_id => v_mission_a, p_incident_id => v_inc, p_outcome => 'rejected',
      p_checklist_response => '{}'::jsonb, p_idempotency_key => gen_random_uuid()
    );
    raise exception '174 FAIL: reopened an already-closed mission with a different key';
  exception when check_violation then
    raise notice '174 PASS: already-closed mission correctly refused for a non-matching key';
  end;
end $$;
reset role;
select as_service();

\echo ' TEST 175: ward-matched officer submits a field completion - atomic, all writes land'
set role authenticated;
select as_user('d1111111-1111-1111-1111-111111111111');
do $$
declare
  v_inc bigint; v_action_a bigint; v_key uuid := 'b0000000-0000-0000-0000-000000000175';
begin
  select v into v_inc from t_ids where k = 't170_inc';
  select v into v_action_a from t_ids where k = 't170_action_a';
  perform submit_field_completion(
    p_action_id => v_action_a, p_incident_id => v_inc, p_action_performed => 'Inspected and issued notice',
    p_photo_urls => array['https://example.com/p1.jpg', 'https://example.com/p2.jpg'],
    p_checklist_response => '{"item1":true}'::jsonb, p_idempotency_key => v_key,
    p_source_confirmed => true, p_started_at => now(), p_completed_at => now(),
    p_lat => 28.6, p_lng => 77.2
  );
end $$;
reset role;
select as_service();
do $$
declare v_action_a bigint; v_inc bigint; v_n int;
begin
  select v into v_action_a from t_ids where k = 't170_action_a';
  select v into v_inc from t_ids where k = 't170_inc';

  select count(*) into v_n from actions
   where id = v_action_a and workflow_status = 'completed' and idempotency_key = 'b0000000-0000-0000-0000-000000000175';
  if v_n = 1 then raise notice '175a PASS: action marked completed with the idempotency key stored';
  else raise exception '175a FAIL: action not updated as expected'; end if;

  -- gps + checklist + 2 photos + timestamp = 5 rows
  select count(*) into v_n from action_evidence where action_id = v_action_a;
  if v_n = 5 then raise notice '175b PASS: exactly 5 action_evidence rows (gps, checklist, 2 photos, timestamp)';
  else raise exception '175b FAIL: expected 5 action_evidence rows, got %', v_n; end if;

  select count(*) into v_n from incident_events
   where incident_id = v_inc and event_type = 'action_completed' and payload->>'action_id' = v_action_a::text;
  if v_n = 1 then raise notice '175c PASS: exactly one action_completed incident_events row';
  else raise exception '175c FAIL: expected 1 row, got %', v_n; end if;
end $$;

\echo ' TEST 176: replaying the SAME idempotency key for a field completion is a true no-op'
set role authenticated;
select as_user('d1111111-1111-1111-1111-111111111111');
do $$
declare
  v_inc bigint; v_action_a bigint; v_key uuid := 'b0000000-0000-0000-0000-000000000175';
begin
  select v into v_inc from t_ids where k = 't170_inc';
  select v into v_action_a from t_ids where k = 't170_action_a';
  perform submit_field_completion(
    p_action_id => v_action_a, p_incident_id => v_inc, p_action_performed => 'Inspected and issued notice',
    p_photo_urls => array['https://example.com/p1.jpg', 'https://example.com/p2.jpg'],
    p_checklist_response => '{"item1":true}'::jsonb, p_idempotency_key => v_key,
    p_source_confirmed => true, p_started_at => now(), p_completed_at => now(),
    p_lat => 28.6, p_lng => 77.2
  );
end $$;
reset role;
select as_service();
do $$
declare v_action_a bigint; v_n int;
begin
  select v into v_action_a from t_ids where k = 't170_action_a';
  select count(*) into v_n from action_evidence where action_id = v_action_a;
  if v_n = 5 then raise notice '176 PASS: replay did not duplicate action_evidence rows';
  else raise exception '176 FAIL: expected still 5 rows after replay, got %', v_n; end if;
end $$;

\echo ' TEST 177: a wrong-ward officer is refused (fresh action, not yet closed)'
set role authenticated;
select as_user('d2222222-2222-2222-2222-222222222222');
do $$
declare v_inc bigint; v_action_b bigint;
begin
  select v into v_inc from t_ids where k = 't170_inc';
  select v into v_action_b from t_ids where k = 't170_action_b';
  begin
    perform submit_field_completion(
      p_action_id => v_action_b, p_incident_id => v_inc, p_action_performed => 'x',
      p_photo_urls => array[]::text[], p_checklist_response => '{}'::jsonb, p_idempotency_key => gen_random_uuid(),
      p_source_confirmed => true, p_started_at => now(), p_completed_at => now()
    );
    raise exception '177 FAIL: a wrong-ward officer submitted a field completion';
  exception when insufficient_privilege then
    raise notice '177 PASS: wrong-ward officer correctly refused (insufficient_privilege)';
  end;
end $$;
reset role;
select as_service();

\echo ' TEST 178: a DIFFERENT idempotency key on an already-completed action is refused'
set role authenticated;
select as_user('d1111111-1111-1111-1111-111111111111');
do $$
declare v_inc bigint; v_action_a bigint;
begin
  select v into v_inc from t_ids where k = 't170_inc';
  select v into v_action_a from t_ids where k = 't170_action_a';
  begin
    perform submit_field_completion(
      p_action_id => v_action_a, p_incident_id => v_inc, p_action_performed => 'x',
      p_photo_urls => array[]::text[], p_checklist_response => '{}'::jsonb, p_idempotency_key => gen_random_uuid(),
      p_source_confirmed => true, p_started_at => now(), p_completed_at => now()
    );
    raise exception '178 FAIL: reopened an already-completed action with a different key';
  exception when check_violation then
    raise notice '178 PASS: already-completed action correctly refused for a non-matching key';
  end;
end $$;
reset role;
select as_service();

reset role;
reset request.jwt.claims;

\echo 'All atomic_mission_rpcs tests passed.'
