-- Test 11: the citizen-verification mission loop under real RLS.
-- Depends on 20_core.sql + 21_workflow_test2.sql having seeded users/incidents.

select 'TEST 11: evidence mission RLS' as t;

reset role;
insert into t_ids (k, v)
select 'mission', id from evidence_missions order by id desc limit 1
on conflict (k) do nothing;

set role authenticated;
do $$
declare v_inc bigint; v_mission bigint; n int;
begin
  select v into v_inc from t_ids where k = 'inc1';

  -- 11a: a CITIZEN must not be able to create a mission (self-assign attack).
  -- Phase 2's `for all` policy allowed this via the assignee carve-out because
  -- INSERT ignores `using`; the Phase 3 split policy is what closes it.
  perform as_user('11111111-1111-1111-1111-111111111111');
  begin
    insert into evidence_missions (incident_id, mission_type, assigned_to, rationale)
    values (v_inc, 'citizen_verification', '11111111-1111-1111-1111-111111111111', 'self-assigned');
    raise notice '11a FAIL: citizen created their own mission';
  exception when others then
    raise notice '11a PASS: citizen cannot create a mission';
  end;

  -- 11b: a COMMANDER can create one, assigned to citizen A.
  perform as_user('44444444-4444-4444-4444-444444444444');
  begin
    insert into evidence_missions (incident_id, mission_type, assigned_to, rationale, public_prompt, status)
    values (v_inc, 'citizen_verification', '11111111-1111-1111-1111-111111111111',
            'INTERNAL: confirm activity before referring to enforcement',
            'Is the pollution you reported still happening?', 'dispatched')
    returning id into v_mission;
    raise notice '11b PASS: commander created a citizen mission';
  exception when others then
    raise notice '11b FAIL: %', sqlerrm; return;
  end;

  -- 11c: citizen B (not the assignee) must not see it via the RPC.
  perform as_user('33333333-3333-3333-3333-333333333333');
  select count(*) into n from list_my_citizen_missions() where mission_id = v_mission;
  if n = 0 then raise notice '11c PASS: unassigned citizen cannot see the mission';
  else raise notice '11c FAIL: mission visible to the wrong citizen'; end if;

  -- 11d: citizen A (the assignee) sees it via the RPC, with the public prompt.
  perform as_user('11111111-1111-1111-1111-111111111111');
  select count(*) into n from list_my_citizen_missions()
   where mission_id = v_mission and public_prompt is not null;
  if n = 1 then raise notice '11d PASS: assignee sees their mission and its public prompt';
  else raise notice '11d FAIL: assignee cannot see their own mission'; end if;

  -- 11e: citizen A can submit the result through the RPC.
  begin
    perform submit_citizen_verification(v_mission, 'confirmed');
    raise notice '11e PASS: assignee submitted their answer';
  exception when others then
    raise notice '11e FAIL: %', sqlerrm;
  end;

  -- 11f: citizen B must not be able to answer someone else's mission.
  perform as_user('33333333-3333-3333-3333-333333333333');
  begin
    perform submit_citizen_verification(v_mission, 'rejected');
    raise notice '11f FAIL: other citizen answered the mission';
  exception when others then
    raise notice '11f PASS: other citizen cannot answer (%)', sqlerrm;
  end;

  -- 11g: the citizen must NOT be able to read the internal rationale, which may
  -- name the authority or enforcement intent. This is the requirement "never
  -- expose sensitive authority or enforcement information", tested at the API
  -- boundary rather than trusting the UI not to render it.
  perform as_user('11111111-1111-1111-1111-111111111111');
  select count(*) into n from evidence_missions where id = v_mission;
  if n = 0 then
    raise notice '11g PASS: citizen has no direct read on evidence_missions (rationale unreachable)';
  else
    raise notice '11g FAIL: citizen can still read the mission row directly';
  end if;

  -- 11h: a citizen answer must NOT officially verify the source.
  if (select source_confidence from incidents where id = v_inc) = 'officially_verified' then
    raise notice '11h FAIL: a citizen answer officially verified the source';
  else
    raise notice '11h PASS: citizen answer did not officially verify the source';
  end if;

  -- 11i: a field officer must still be able to read their own mission fully.
  perform as_user('22222222-2222-2222-2222-222222222222');
  select count(*) into n from evidence_missions where incident_id = v_inc;
  if n > 0 then raise notice '11i PASS: field officer retains full mission access';
  else raise notice '11i FAIL: field officer lost mission access'; end if;
end $$;

reset role;
reset request.jwt.claims;
