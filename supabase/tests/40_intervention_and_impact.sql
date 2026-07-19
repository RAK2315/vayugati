-- Phase 4: intervention creation, workflow, impact evaluation, closure guard,
-- citizen action verification. Run as `authenticated` (a superuser bypasses RLS
-- and would make this suite pass vacuously) against a fresh schema seeded by
-- 10_report_to_incident.sql-style helpers (this file seeds its own fixtures so
-- it can run standalone via run.sh).

create table if not exists t_ids (k text primary key, v bigint);
grant select on t_ids to authenticated;
truncate t_ids;

create or replace function as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p::text, 'role', 'authenticated')::text, false);
end $$;

reset role;

-- ---------- fixtures ----------
insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111','citizen@x.com'),
  ('22222222-2222-2222-2222-222222222222','officer@x.com'),
  ('44444444-4444-4444-4444-444444444444','cmd@x.com')
on conflict do nothing;

insert into profiles (id, role, ward_id, full_name) values
  ('11111111-1111-1111-1111-111111111111','citizen',1,'A Citizen'),
  ('22222222-2222-2222-2222-222222222222','field_officer',1,'Officer Singh'),
  ('44444444-4444-4444-4444-444444444444','commander',null,'Cmdr Rao')
on conflict (id) do update set role=excluded.role, ward_id=excluded.ward_id, full_name=excluded.full_name;

grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant execute on function record_impact_evaluation(bigint,bigint,double precision,double precision,int,text,double precision,text) to authenticated;
grant execute on function submit_citizen_action_verification(bigint,text) to authenticated;

-- a suspected incident and a corroborated + officially_verified incident
insert into incidents (id, ward_id, status, detection_method, source_confidence, summary)
values
  (9101, 1, 'detected', 'manual', 'suspected', 'suspected incident')
on conflict (id) do update set status='detected', source_confidence='suspected';

insert into incidents (id, ward_id, status, detection_method, source_confidence, summary)
values
  (9102, 1, 'evidence_gathering', 'manual', 'corroborated', 'corroborated incident')
on conflict (id) do update set status='evidence_gathering', source_confidence='corroborated';

insert into reports (id, reporter_id, ward_id, description, incident_id)
values (9201, '11111111-1111-1111-1111-111111111111', 1, 'report on 9102', 9102)
on conflict (id) do update set incident_id = 9102;

set role authenticated;

select 'TEST 12: intervention creation gated by evidence level' as t;
do $$
declare v_action bigint;
begin
  perform as_user('44444444-4444-4444-4444-444444444444');

  -- 12a: suspected incident -> no intervention action
  begin
    insert into actions (incident_id, ward_id, type, workflow_status, recommended_action, responsible_agency)
    values (9101, 1, 'inspect', 'drafted', 'Inspect site', 'MCD');
    raise notice '12a FAIL: intervention created on a suspected incident';
  exception when check_violation then raise notice '12a PASS: blocked on suspected incident';
  end;

  -- 12b: corroborated incident -> inspection allowed, drafted
  begin
    insert into actions (incident_id, ward_id, type, workflow_status, recommended_action, responsible_agency, deadline, expected_verification_hours, custom_reason)
    values (9102, 1, 'inspect', 'drafted', 'Site inspection + dust control notice', 'MCD Zone 3',
            now() + interval '3 days', 72, 'No playbook available for this test fixture')
    returning id into v_action;
    insert into t_ids (k, v) values ('action', v_action) on conflict (k) do update set v = excluded.v;
    raise notice '12b PASS: intervention created on corroborated incident (id %)', v_action;
  exception when others then raise notice '12b FAIL: %', sqlerrm;
  end;

  -- 12c: enforcement without verification blocked (Phase 3 rule still holds)
  begin
    insert into actions (incident_id, ward_id, type, workflow_status) values (9102, 1, 'penalty', 'drafted');
    raise notice '12c FAIL: enforcement allowed on corroborated (not verified) incident';
  exception when check_violation then raise notice '12c PASS: blocked (needs officially_verified)';
  end;
end $$;

select 'TEST 13: action workflow transitions (completed != effective)' as t;
do $$
declare v_action bigint;
begin
  select v into v_action from t_ids where k = 'action';

  -- 13a: officer accepts and starts
  perform as_user('22222222-2222-2222-2222-222222222222');
  update actions set workflow_status = 'assigned', assigned_to = '22222222-2222-2222-2222-222222222222' where id = v_action;
  update actions set workflow_status = 'accepted', accepted_at = now() where id = v_action;
  update actions set workflow_status = 'in_progress', started_at = now() where id = v_action;
  update actions set workflow_status = 'completed', completed_at = now(), source_confirmed = true where id = v_action;
  raise notice '13a PASS: officer advanced drafted -> assigned -> accepted -> in_progress -> completed';

  -- 13b: 'completed' must not itself imply an outcome — it is NOT one of the
  -- outcome enum values, so nothing here claims effectiveness.
  if (select workflow_status from actions where id = v_action) = 'completed' then
    raise notice '13b PASS: action is completed but carries no outcome yet';
  else
    raise notice '13b FAIL: unexpected state %', (select workflow_status from actions where id = v_action);
  end if;

  -- 13c: trying to mark an outcome state directly (no impact eval yet) is blocked.
  begin
    update actions set workflow_status = 'effective' where id = v_action;
    raise notice '13c FAIL: outcome state accepted with no impact_evaluations row';
  exception when check_violation then raise notice '13c PASS: blocked — an impact evaluation must exist first';
  end;
end $$;

select 'TEST 14: impact evaluation — before/after, inconclusive on missing data' as t;
do $$
declare v_action bigint; v_out text;
begin
  select v into v_action from t_ids where k = 'action';
  perform as_user('44444444-4444-4444-4444-444444444444');  -- commander (impact_evaluations_write is commander/admin only)

  -- 14a: a field officer must NOT be able to record an evaluation.
  perform as_user('22222222-2222-2222-2222-222222222222');
  begin
    perform record_impact_evaluation(9102, v_action, 120, 60, 48, 'Station A', 0.9, null);
    raise notice '14a FAIL: field officer recorded an impact evaluation';
  exception when others then raise notice '14a PASS: blocked (%)', sqlerrm;
  end;

  -- 14b: missing "after" value -> inconclusive, action moves to 'inconclusive'
  perform as_user('44444444-4444-4444-4444-444444444444');
  select record_impact_evaluation(9102, v_action, 120, null, 48, 'Station A', 0.9, 'no post-action reading available') into v_out;
  if v_out = 'inconclusive' then raise notice '14b PASS: missing after-value yields inconclusive';
  else raise notice '14b FAIL: got %', v_out; end if;

  if (select workflow_status from actions where id = v_action) = 'inconclusive' then
    raise notice '14b2 PASS: action reflects inconclusive outcome';
  else raise notice '14b2 FAIL: action workflow_status = %', (select workflow_status from actions where id = v_action); end if;

  -- 14c: low completeness -> inconclusive even with real numbers
  select record_impact_evaluation(9102, v_action, 120, 40, 48, 'Station A', 0.3, 'sparse readings') into v_out;
  if v_out = 'inconclusive' then raise notice '14c PASS: low data completeness yields inconclusive despite a large apparent drop';
  else raise notice '14c FAIL: got %', v_out; end if;

  -- 14d: a real >=40% drop with good completeness -> effective
  select record_impact_evaluation(9102, v_action, 120, 60, 48, 'Station A', 0.95, 'good coverage') into v_out;
  if v_out = 'effective' then raise notice '14d PASS: 50%% drop with good data -> effective';
  else raise notice '14d FAIL: got %', v_out; end if;

  -- 14e: a rise in pollutant -> ineffective, never "effective"
  select record_impact_evaluation(9102, v_action, 100, 130, 48, 'Station A', 0.95, 'pollution rose') into v_out;
  if v_out = 'ineffective' then raise notice '14e PASS: an increase is never labelled effective';
  else raise notice '14e FAIL: got %', v_out; end if;

  -- 14f: incident moved to 'verifying', never auto-closed
  if (select status from incidents where id = 9102) = 'verifying' then
    raise notice '14f PASS: incident moved to verifying, not auto-closed';
  else raise notice '14f FAIL: incident status = %', (select status from incidents where id = 9102); end if;
end $$;

select 'TEST 15: closure guard — cannot close on a photo alone' as t;
do $$
declare v_action2 bigint;
begin
  perform as_user('44444444-4444-4444-4444-444444444444');

  -- a second action on 9102, completed, but with NO impact evaluation
  insert into actions (incident_id, ward_id, type, workflow_status, completed_at, custom_reason)
  values (9102, 1, 'sprinkle', 'completed', now(), 'No playbook available for this test fixture')
  returning id into v_action2;

  begin
    update incidents set status = 'closed' where id = 9102;
    raise notice '15a FAIL: incident closed while a completed action has no impact evaluation';
  exception when check_violation then raise notice '15a PASS: closure blocked pending impact evaluation';
  end;

  -- once evaluated (even inconclusively), closure is allowed
  perform record_impact_evaluation(9102, v_action2, null, null, 24, 'Station A', 0.9, 'no before reading captured');
  update incidents set status = 'closed', closed_at = now() where id = 9102;
  if (select status from incidents where id = 9102) = 'closed' then
    raise notice '15b PASS: closure allowed once every completed action has an evaluation';
  else raise notice '15b FAIL: incident did not close'; end if;
end $$;

select 'TEST 16: reopen after recurrence' as t;
do $$
begin
  perform as_user('44444444-4444-4444-4444-444444444444');
  update incidents set status = 'evidence_gathering', updated_at = now() where id = 9102 and status = 'closed';
  if (select status from incidents where id = 9102) = 'evidence_gathering' then
    raise notice '16a PASS: closed incident can reopen';
  else raise notice '16a FAIL'; end if;

  update actions set workflow_status = 'reopened' where incident_id = 9102 and workflow_status = 'ineffective';
  insert into incident_events (incident_id, event_type, actor_id, note, is_public, payload)
  values (9102, 'status_changed', '44444444-4444-4444-4444-444444444444', 'Problem recurred; incident reopened.', true, '{"reopen":true}');
  raise notice '16b PASS: reopen recorded in incident_events';
end $$;

select 'TEST 17: citizen action verification — supports only, never sets outcome' as t;
do $$
declare v_before_outcome text; v_after_outcome text;
begin
  select outcome::text into v_before_outcome from impact_evaluations where incident_id = 9102 order by id desc limit 1;

  -- 17a: citizen NOT linked to this incident cannot verify it.
  -- Unlink as superuser: a citizen's own UPDATE of reports.incident_id is
  -- silently a 0-row no-op under RLS (the same Phase 3 finding), so doing the
  -- unlink "as the citizen" would leave the report linked and the test would
  -- pass for the wrong reason.
  reset role;
  update reports set incident_id = null where id = 9201;
  set role authenticated;
  perform as_user('11111111-1111-1111-1111-111111111111');
  begin
    perform submit_citizen_action_verification(9102, 'completed');
    raise notice '17a FAIL: unlinked citizen could verify the action';
  exception when others then raise notice '17a PASS: blocked (%)', sqlerrm;
  end;

  -- relink and retry
  reset role;
  update reports set incident_id = 9102 where id = 9201;
  set role authenticated;
  perform as_user('11111111-1111-1111-1111-111111111111');

  begin
    perform submit_citizen_action_verification(9102, 'problem_returned');
    raise notice '17b PASS: linked citizen recorded an action verification';
  exception when others then raise notice '17b FAIL: %', sqlerrm;
  end;

  -- 17c: citizen answer must NOT change the impact_evaluations outcome
  select outcome::text into v_after_outcome from impact_evaluations where incident_id = 9102 order by id desc limit 1;
  if v_after_outcome = v_before_outcome then
    raise notice '17c PASS: citizen verification did not alter the recorded outcome (%)', v_after_outcome;
  else raise notice '17c FAIL: outcome changed from % to %', v_before_outcome, v_after_outcome; end if;
end $$;

select 'TEST 18: citizen cannot read internal enforcement / action detail' as t;
do $$
declare n int;
begin
  perform as_user('11111111-1111-1111-1111-111111111111');

  select count(*) into n from actions where incident_id = 9102;
  if n = 0 then raise notice '18a PASS: citizen has zero read on actions (no enforcement/agency detail exposed)';
  else raise notice '18a FAIL: citizen can read % action row(s)', n; end if;

  select count(*) into n from action_evidence ae join actions a on a.id = ae.action_id where a.incident_id = 9102;
  if n = 0 then raise notice '18b PASS: citizen has zero read on action_evidence';
  else raise notice '18b FAIL: citizen can read % action_evidence row(s)', n; end if;

  -- impact_evaluations ARE visible to the citizen — INTENTIONAL, not a gap.
  -- This is the Phase 2 policy, unchanged: an environmental outcome (effective /
  -- ineffective / inconclusive) is what plan §11/§15 asks citizens to be able to
  -- track ("verify whether the intervention worked"). It carries no agency name,
  -- approver, or enforcement rationale — those live on `actions`, which citizens
  -- cannot read at all (18a).
  select count(*) into n from impact_evaluations where incident_id = 9102;
  if n > 0 then raise notice '18c PASS (by design): citizen can read the impact outcome (% rows) — no enforcement detail included', n;
  else raise notice '18c FAIL: citizen cannot see the outcome of an incident linked to their own report'; end if;
end $$;

select 'TEST 19: field officer action_evidence RLS' as t;
do $$
declare v_action bigint; n int;
begin
  select v into v_action from t_ids where k = 'action';

  -- own ward: officer can write action_evidence
  perform as_user('22222222-2222-2222-2222-222222222222');
  begin
    insert into action_evidence (action_id, evidence_type, payload, captured_by)
    values (v_action, 'gps', '{"lat":28.85,"lng":77.09}'::jsonb, '22222222-2222-2222-2222-222222222222');
    raise notice '19a PASS: field officer recorded action_evidence in their own ward';
  exception when others then raise notice '19a FAIL: %', sqlerrm;
  end;

  select count(*) into n from action_evidence where action_id = v_action;
  if n > 0 then raise notice '19b PASS: officer can read their own action_evidence (% rows)', n;
  else raise notice '19b FAIL: officer cannot read action_evidence'; end if;
end $$;

reset role;
reset request.jwt.claims;
