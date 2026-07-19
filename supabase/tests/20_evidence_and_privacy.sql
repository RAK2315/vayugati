-- Tests 7-10, rewritten. Two harness bugs in the first draft, both now fixed:
--   * psql does NOT interpolate :vars inside dollar-quoted blocks -> ids are
--     passed through a real table instead.
--   * test 7's setup SELECT ran under RLS as the wrong user, so it read NULL
--     and "passed" for the wrong reason -> setup now runs as superuser.

create table if not exists t_ids (k text primary key, v bigint);
grant select on t_ids to authenticated;
truncate t_ids;

reset role;
insert into t_ids (k, v)
select 'inc1', min(id) from incidents;
insert into t_ids (k, v)
select 'inc_suspected', id from incidents where source_confidence = 'suspected' order by id desc limit 1;
insert into t_ids (k, v)
select 'report_a', min(id) from reports where reporter_id = '11111111-1111-1111-1111-111111111111';

-- ============ 7. authorisation: cannot link someone else's report ============
select 'TEST 7: a citizen cannot link ANOTHER citizen''s report' as t;
update reports set incident_id = null where id = (select v from t_ids where k = 'report_a');

set role authenticated;
do $$
declare v_other bigint;
begin
  select v into v_other from t_ids where k = 'report_a';
  if v_other is null then raise exception 'harness bug: report_a is null'; end if;

  perform as_user('33333333-3333-3333-3333-333333333333');   -- citizen B
  begin
    perform link_report_to_incident(v_other);
    raise notice '7 FAIL: citizen B linked citizen A''s report (id %)', v_other;
  exception when others then
    raise notice '7 PASS: blocked (%)', sqlerrm;
  end;

  -- and the owner CAN link it
  perform as_user('11111111-1111-1111-1111-111111111111');
  begin
    perform link_report_to_incident(v_other);
    raise notice '7b PASS: owner can link their own report';
  exception when others then
    raise notice '7b FAIL: %', sqlerrm;
  end;
end $$;

-- ============ 8. evidence-level task rules ============
select 'TEST 8: evidence-level task rules' as t;
do $$
declare v_susp bigint; v_corr bigint;
begin
  perform as_user('44444444-4444-4444-4444-444444444444');  -- commander
  select v into v_susp from t_ids where k = 'inc_suspected';
  select v into v_corr from t_ids where k = 'inc1';

  if (select source_confidence from incidents where id = v_susp) <> 'suspected' then
    raise exception 'harness bug: inc_suspected is not suspected';
  end if;
  if (select source_confidence from incidents where id = v_corr) <> 'corroborated' then
    raise exception 'harness bug: inc1 is not corroborated';
  end if;

  -- 8a: action on a SUSPECTED incident must be refused
  begin
    insert into actions (incident_id, ward_id, type, status) values (v_susp, 1, 'inspect', 'assigned');
    raise notice '8a FAIL: action allowed on suspected incident';
  exception when check_violation then raise notice '8a PASS: blocked';
  end;

  -- 8b: inspection on a CORROBORATED incident is allowed
  begin
    insert into actions (incident_id, ward_id, type, status, custom_reason)
      values (v_corr, 1, 'inspect', 'assigned', 'No playbook available for this test fixture');
    raise notice '8b PASS: inspection allowed on corroborated incident';
  exception when others then raise notice '8b FAIL: %', sqlerrm;
  end;

  -- 8c: enforcement on corroborated (not verified) must be refused
  begin
    insert into actions (incident_id, ward_id, type, status) values (v_corr, 1, 'penalty', 'assigned');
    raise notice '8c FAIL: enforcement allowed without official verification';
  exception when check_violation then raise notice '8c PASS: blocked';
  end;

  -- 8d: verified but NO approver must be refused
  update incidents set source_confidence = 'officially_verified' where id = v_corr;
  begin
    insert into actions (incident_id, ward_id, type, status) values (v_corr, 1, 'penalty', 'assigned');
    raise notice '8d FAIL: enforcement allowed with no human approver';
  exception when check_violation then raise notice '8d PASS: blocked';
  end;

  -- 8e: verified + named approver -> allowed
  begin
    insert into actions (incident_id, ward_id, type, status, approved_by, approved_at, approval_level, custom_reason)
    values (v_corr, 1, 'penalty', 'assigned', '44444444-4444-4444-4444-444444444444', now(), 'authorised_legal', 'No enforcement playbook exists for this test fixture');
    raise notice '8e PASS: enforcement allowed with verification + human approver';
  exception when others then raise notice '8e FAIL: %', sqlerrm;
  end;

  -- 8f: legacy report-only action (no incident) unaffected
  begin
    insert into actions (ward_id, type, status) values (1, 'inspect', 'assigned');
    raise notice '8f PASS: legacy non-incident action unaffected';
  exception when others then raise notice '8f FAIL: %', sqlerrm;
  end;

  -- restore
  update incidents set source_confidence = 'corroborated' where id = v_corr;
end $$;

-- ============ 9. citizen timeline privacy ============
select 'TEST 9: citizen sees only public events' as t;
reset role;
insert into incident_events (incident_id, event_type, actor_id, note, is_public)
select v, 'routed', '44444444-4444-4444-4444-444444444444',
       'INTERNAL: routing to enforcement cell, prosecution likely', false
from t_ids where k = 'inc1';

set role authenticated;
select as_user('11111111-1111-1111-1111-111111111111');  -- citizen A, reporter on inc1
select
  case when count(*) filter (where not is_public) = 0
       then 'PASS: no internal events visible to citizen'
       else 'FAIL: internal events leaked' end as privacy,
  count(*) as public_events_visible
from incident_events where incident_id = (select v from t_ids where k = 'inc1');

select case when count(*) = 0 then 'PASS: hypotheses hidden from citizen'
            else 'FAIL: hypotheses visible' end as hypotheses
from incident_source_hypotheses where incident_id = (select v from t_ids where k = 'inc1');

select case when count(*) = 0 then 'PASS: actions hidden from citizen'
            else 'FAIL: enforcement actions visible' end as actions_hidden
from actions where incident_id = (select v from t_ids where k = 'inc1');

-- officer in the ward SHOULD see internal events
select as_user('22222222-2222-2222-2222-222222222222');
select case when count(*) filter (where not is_public) >= 1
            then 'PASS: officer sees internal events'
            else 'FAIL: officer cannot see internal events' end as officer_visibility
from incident_events where incident_id = (select v from t_ids where k = 'inc1');

-- ============ 10. hypothesis counting rule ============
select 'TEST 10: hypothesis probabilities (counting rule)' as t;
select as_user('44444444-4444-4444-4444-444444444444');
select source_category::text, round(probability::numeric, 3) as probability,
       confidence_level::text, model_version
from incident_source_hypotheses
where incident_id = (select v from t_ids where k = 'inc1')
order by probability desc;

reset role;
reset request.jwt.claims;
