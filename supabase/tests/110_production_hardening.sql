-- Phase 10: production hardening — the two RPC replay/idempotency bugs
-- found and fixed during this phase's own review, the storage evidence-
-- tamper fix, job-run overlap protection, system health, and feature flags.
--
-- Role discipline: identical to 100_authority_routing_and_dispatch.sql —
-- fixture setup runs as superuser (as_service()), `set role authenticated`
-- + `as_user(...)` only for the specific RLS/authorization assertions.

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
grant execute on function dispatch_intervention_task(bigint, uuid) to authenticated;
grant execute on function transition_task_dispatch(bigint, task_dispatch_status, uuid, text) to authenticated;
grant execute on function system_health_summary() to authenticated;

create or replace function _t110_setup(p_prefix text, p_officer uuid default '22222222-2222-2222-2222-222222222222')
returns table(city_id bigint, ward_id bigint, incident_id bigint)
language plpgsql as $$
declare v_city bigint; v_ward bigint; v_incident bigint;
begin
  insert into city_config (city_code, name) values (p_prefix, 'Test City ' || p_prefix) returning id into v_city;
  insert into wards (name, city_id) values (p_prefix || '-a', v_city) returning id into v_ward;
  update profiles set ward_id = v_ward where id = p_officer;
  insert into incidents (city_id, ward_id, status, detection_method, severity, source_confidence)
    values (v_city, v_ward, 'under_review', 'manual', 'high', 'officially_verified') returning id into v_incident;
  insert into incident_source_hypotheses (incident_id, source_category, probability, is_current)
    values (v_incident, 'construction_dust', 0.9, true);
  return query select v_city, v_ward, v_incident;
end $$;

create or replace function _t110_action(p_incident bigint, p_ward bigint, p_type text default 'inspect')
returns bigint language plpgsql as $$
declare v_action bigint;
begin
  insert into actions (ward_id, incident_id, type, status, custom_reason)
    values (p_ward, p_incident, p_type, 'assigned', 'test fixture, no playbook needed')
    returning id into v_action;
  return v_action;
end $$;

select 'TEST 111: dispatch_intervention_task is replay-safe — a repeat call never regresses status or re-sends a notification' as t;
do $$
declare v_city bigint; v_ward bigint; v_incident bigint; v_action bigint; v_disp bigint;
  v_sent_at_1 timestamptz; v_notif_count_1 int; v_notif_count_2 int;
begin
  reset role;
  select * into v_city, v_ward, v_incident from _t110_setup('t111');
  insert into responsibility_registry (city_id, source_category, ward_id, regulating_authority, responsible_officer, mapping_confidence)
    values (v_city, 'construction_dust', v_ward, 'MCD', '22222222-2222-2222-2222-222222222222', 'verified');
  v_action := _t110_action(v_incident, v_ward);

  perform dispatch_intervention_task(v_action, '44444444-4444-4444-4444-444444444444');
  select id into v_disp from task_dispatches where action_id = v_action and is_current;

  -- progress it well past initial routing
  perform transition_task_dispatch(v_disp, 'acknowledged', '22222222-2222-2222-2222-222222222222', null);
  perform transition_task_dispatch(v_disp, 'accepted', '22222222-2222-2222-2222-222222222222', null);
  perform transition_task_dispatch(v_disp, 'in_progress', '22222222-2222-2222-2222-222222222222', null);

  select sent_at into v_sent_at_1 from task_dispatches where id = v_disp;
  select count(*) into v_notif_count_1 from notifications where task_dispatch_id = v_disp;

  -- a retried/duplicate client call, or a re-run of an automation
  perform dispatch_intervention_task(v_action, '44444444-4444-4444-4444-444444444444');

  if (select status from task_dispatches where id = v_disp) <> 'in_progress' then
    raise exception 'TEST 111a FAIL: repeat dispatch call regressed status to %', (select status from task_dispatches where id = v_disp);
  end if;
  raise notice 'TEST 111a PASS: repeat dispatch call did not regress an in_progress task back to sent';

  if (select sent_at from task_dispatches where id = v_disp) <> v_sent_at_1 then
    raise exception 'TEST 111b FAIL: sent_at was overwritten by a repeat dispatch call';
  end if;
  raise notice 'TEST 111b PASS: sent_at is frozen once a dispatch has actually progressed';

  select count(*) into v_notif_count_2 from notifications where task_dispatch_id = v_disp;
  if v_notif_count_2 <> v_notif_count_1 then
    raise exception 'TEST 111c FAIL: repeat dispatch call created % new notifications', (v_notif_count_2 - v_notif_count_1);
  end if;
  raise notice 'TEST 111c PASS: repeat dispatch call sent zero additional notifications';
end $$;

select 'TEST 112: completed -> escalated is now a consistently-legal transition' as t;
do $$
declare v_city bigint; v_ward bigint; v_incident bigint; v_action bigint; v_disp bigint; v_blocked boolean := false;
begin
  reset role;
  select * into v_city, v_ward, v_incident from _t110_setup('t112');
  insert into responsibility_registry (city_id, source_category, ward_id, regulating_authority, responsible_officer, mapping_confidence)
    values (v_city, 'construction_dust', v_ward, 'MCD', '22222222-2222-2222-2222-222222222222', 'verified');
  v_action := _t110_action(v_incident, v_ward);
  insert into action_evidence (action_id, evidence_type, captured_by)
    values (v_action, 'photo', '22222222-2222-2222-2222-222222222222');
  perform dispatch_intervention_task(v_action, '44444444-4444-4444-4444-444444444444');
  select id into v_disp from task_dispatches where action_id = v_action and is_current;
  perform transition_task_dispatch(v_disp, 'acknowledged', '22222222-2222-2222-2222-222222222222', null);
  perform transition_task_dispatch(v_disp, 'accepted', '22222222-2222-2222-2222-222222222222', null);
  perform transition_task_dispatch(v_disp, 'in_progress', '22222222-2222-2222-2222-222222222222', null);
  perform transition_task_dispatch(v_disp, 'completed', '22222222-2222-2222-2222-222222222222', null);

  begin
    perform transition_task_dispatch(v_disp, 'escalated', '44444444-4444-4444-4444-444444444444', 'verification overdue');
  exception when others then v_blocked := true;
  end;
  if v_blocked then raise exception 'TEST 112 FAIL: completed -> escalated was rejected'; end if;
  raise notice 'TEST 112 PASS: completed -> escalated is accepted, matching what escalate_stale_task_dispatches itself performs';
end $$;

select 'TEST 113: a rejection/reroute/cancellation reason longer than 2000 chars is refused' as t;
do $$
declare v_city bigint; v_ward bigint; v_incident bigint; v_action bigint; v_disp bigint; v_blocked boolean := false;
begin
  reset role;
  select * into v_city, v_ward, v_incident from _t110_setup('t113');
  insert into responsibility_registry (city_id, source_category, ward_id, regulating_authority, responsible_officer, mapping_confidence)
    values (v_city, 'construction_dust', v_ward, 'MCD', '22222222-2222-2222-2222-222222222222', 'verified');
  v_action := _t110_action(v_incident, v_ward);
  perform dispatch_intervention_task(v_action, '44444444-4444-4444-4444-444444444444');
  select id into v_disp from task_dispatches where action_id = v_action and is_current;

  begin
    perform transition_task_dispatch(v_disp, 'cancelled', '44444444-4444-4444-4444-444444444444', repeat('x', 2001));
  exception when others then v_blocked := true;
  end;
  if not v_blocked then raise exception 'TEST 113 FAIL: an oversized reason was accepted'; end if;
  raise notice 'TEST 113 PASS: an oversized (2001-char) reason was refused';
end $$;

select 'TEST 114: a citizen cannot delete or replace their own uploaded evidence photo (storage tamper fix)' as t;
do $$
declare v_update_allowed boolean; v_delete_allowed boolean;
begin
  reset role;
  select exists(select 1 from pg_policies where tablename = 'objects' and schemaname = 'storage' and policyname = 'report_photos_update') into v_update_allowed;
  select exists(select 1 from pg_policies where tablename = 'objects' and schemaname = 'storage' and policyname = 'report_photos_delete') into v_delete_allowed;
  if coalesce(v_update_allowed, false) or coalesce(v_delete_allowed, false) then
    raise exception 'TEST 114 FAIL: report_photos_update/delete policies still exist';
  end if;
  raise notice 'TEST 114 PASS: report-photos has no update/delete policy — uploads are append-only, like every other evidence table';
end $$;

select 'TEST 115: job_runs structurally prevents two overlapping runs of the same job+city' as t;
do $$
declare v_run1 bigint; v_run2 bigint;
begin
  reset role;
  delete from job_runs where job_name = 'anomaly_detection' and city_code = 't115';
  v_run1 := start_job_run('anomaly_detection', 't115');
  if v_run1 is null then raise exception 'TEST 115a FAIL: first run should have started'; end if;
  raise notice 'TEST 115a PASS: first run started (id=%)', v_run1;

  v_run2 := start_job_run('anomaly_detection', 't115');
  if v_run2 is not null then raise exception 'TEST 115b FAIL: a second overlapping run was allowed to start'; end if;
  raise notice 'TEST 115b PASS: a second overlapping run for the same job+city was refused (returned null)';

  perform complete_job_run(v_run1, 4);
  if (select status from job_runs where id = v_run1) <> 'completed' then
    raise exception 'TEST 115c FAIL: run was not marked completed';
  end if;

  -- now that the first run has completed, a new run for the same job+city may start
  v_run2 := start_job_run('anomaly_detection', 't115');
  if v_run2 is null then raise exception 'TEST 115d FAIL: a new run after completion should be allowed'; end if;
  raise notice 'TEST 115d PASS: a new run is allowed once the previous one has completed';
  perform fail_job_run(v_run2, 'synthetic test failure', 'unknown');
  if (select status from job_runs where id = v_run2) <> 'failed' then
    raise exception 'TEST 115e FAIL: run was not marked failed';
  end if;
  raise notice 'TEST 115e PASS: fail_job_run records a failed run with its error message';
end $$;

select 'TEST 116: citizens/officers cannot read job_runs; commander can via system_health_summary' as t;
do $$
declare v_n int;
begin
  reset role;
  set role authenticated;
  perform as_user('11111111-1111-1111-1111-111111111111'); -- citizen
  select count(*) into v_n from job_runs;
  if v_n <> 0 then raise exception 'TEST 116a FAIL: citizen read % job_runs rows directly', v_n; end if;

  perform as_user('44444444-4444-4444-4444-444444444444'); -- commander
  select count(*) into v_n from system_health_summary();
  reset role;
  if v_n = 0 then raise exception 'TEST 116b FAIL: commander got zero rows from system_health_summary'; end if;
  raise notice 'TEST 116 PASS: citizen reads zero job_runs rows directly; commander reads a non-empty health summary via the function';
end $$;

select 'TEST 117: feature flags — disabling operational_dispatch actually blocks dispatch_intervention_task' as t;
do $$
declare v_city bigint; v_ward bigint; v_incident bigint; v_action bigint; v_blocked boolean := false;
begin
  reset role;
  select * into v_city, v_ward, v_incident from _t110_setup('t117');
  insert into responsibility_registry (city_id, source_category, ward_id, regulating_authority, responsible_officer, mapping_confidence)
    values (v_city, 'construction_dust', v_ward, 'MCD', '22222222-2222-2222-2222-222222222222', 'verified');
  v_action := _t110_action(v_incident, v_ward);

  update city_config set config = config || jsonb_build_object('feature_flags', jsonb_build_object('operational_dispatch', false))
  where id = v_city;

  begin
    perform dispatch_intervention_task(v_action, '44444444-4444-4444-4444-444444444444');
  exception when others then v_blocked := true;
  end;
  if not v_blocked then raise exception 'TEST 117a FAIL: dispatch proceeded despite operational_dispatch=false'; end if;
  raise notice 'TEST 117a PASS: dispatch_intervention_task refuses when operational_dispatch is disabled for the city';

  update city_config set config = config || jsonb_build_object('feature_flags', jsonb_build_object('operational_dispatch', true))
  where id = v_city;
  perform dispatch_intervention_task(v_action, '44444444-4444-4444-4444-444444444444');
  if (select status from task_dispatches where action_id = v_action and is_current) is null then
    raise exception 'TEST 117b FAIL: dispatch still refused after re-enabling the flag';
  end if;
  raise notice 'TEST 117b PASS: dispatch proceeds again once the flag is re-enabled';
end $$;

select 'TEST 118: feature flags default to enabled for a city that never configured an opinion' as t;
do $$
declare v_enabled boolean; v_city int;
begin
  reset role;
  insert into city_config (city_code, name) values ('t118', 'Test City t118') returning id into v_city;
  select city_feature_enabled(v_city, 'anomaly_detection', true) into v_enabled;
  if not v_enabled then raise exception 'TEST 118 FAIL: an unconfigured city defaulted to disabled'; end if;
  raise notice 'TEST 118 PASS: a city with no feature_flags key at all uses the caller-supplied default (never silently off)';
end $$;

select 'TEST 119: every SECURITY DEFINER function in this schema pins search_path (automated, not a hardcoded name list)' as t;
do $$
declare v_bad text[];
begin
  reset role;
  -- Introspects pg_proc directly rather than checking a hand-maintained
  -- list of function names — this test automatically covers any FUTURE
  -- security definer function too, catching a search_path-hijacking
  -- vulnerability the moment a migration introduces one, not just the ones
  -- known about at the time this test was written.
  select array_agg(p.proname) into v_bad
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.prosecdef = true
    and (p.proconfig is null or not exists (
      select 1 from unnest(p.proconfig) c where c like 'search_path=%'
    ));

  if v_bad is not null and array_length(v_bad, 1) > 0 then
    raise exception 'TEST 119 FAIL: SECURITY DEFINER function(s) without a pinned search_path: %', v_bad;
  end if;
  raise notice 'TEST 119 PASS: every SECURITY DEFINER function in public pins search_path (search_path-hijacking is not possible)';
end $$;

select 'TEST 120: one city''s corrupted config cannot take down another city''s anomaly-detection batch' as t;
do $$
declare v_healthy_city bigint; v_healthy_ward bigint; v_healthy_station bigint;
        v_broken_city bigint; v_broken_ward bigint; v_broken_station bigint;
        v_results int;
begin
  reset role;
  insert into city_config (city_code, name, pollutant_priority, config) values
    ('t120h', 'Healthy City', array['pm25'],
     jsonb_build_object('anomaly_detection', jsonb_build_object(
       'pollutant_thresholds', jsonb_build_object('pm25', 90),
       'persistence_window_readings', 3, 'persistence_min_count', 2, 'local_excess_min', 20,
       'nearby_station_radius_m', 5000, 'data_completeness_min', 0.5, 'data_freshness_max_minutes', 180,
       'prediction_horizon_hours', 6, 'dedup_window_hours', 12)))
    returning id into v_healthy_city;
  insert into wards (name, city_id) values ('t120h-a', v_healthy_city) returning id into v_healthy_ward;
  insert into stations (ward_id, name, sensor_type) values (v_healthy_ward, 't120h station', 'regulatory') returning id into v_healthy_station;
  insert into readings (station_id, ts, pm25) values (v_healthy_station, now() - interval '1 hour', 30);

  -- a city whose anomaly_detection config is corrupted (pollutant_thresholds.pm25
  -- is a non-numeric string) — evaluate_station_pollutant_anomaly's own
  -- `(...)::double precision` cast will raise for this one specifically.
  insert into city_config (city_code, name, pollutant_priority, config) values
    ('t120b', 'Broken City', array['pm25'],
     jsonb_build_object('anomaly_detection', jsonb_build_object(
       'pollutant_thresholds', jsonb_build_object('pm25', 'not_a_number'),
       'persistence_window_readings', 3, 'persistence_min_count', 2, 'local_excess_min', 20,
       'nearby_station_radius_m', 5000, 'data_completeness_min', 0.5, 'data_freshness_max_minutes', 180,
       'prediction_horizon_hours', 6, 'dedup_window_hours', 12)))
    returning id into v_broken_city;
  insert into wards (name, city_id) values ('t120b-a', v_broken_city) returning id into v_broken_ward;
  insert into stations (ward_id, name, sensor_type) values (v_broken_ward, 't120b station', 'regulatory') returning id into v_broken_station;
  insert into readings (station_id, ts, pm25) values (v_broken_station, now() - interval '1 hour', 30);

  -- no p_city_code filter: one call spans BOTH cities, exactly the real
  -- cron's own call shape (run_anomaly_detection() with no argument).
  select count(*) into v_results from run_anomaly_detection() where station_id = v_healthy_station;
  if v_results = 0 then
    raise exception 'TEST 120 FAIL: the healthy city''s station produced no result — the broken city''s failure took the whole batch down';
  end if;
  raise notice 'TEST 120 PASS: the healthy city''s station still produced a result despite the other city''s config being broken (per-iteration isolation)';
end $$;
