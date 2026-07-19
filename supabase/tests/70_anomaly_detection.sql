-- Phase 6: automated pollution anomaly detection + predicted incidents.
-- Run as `authenticated` for every RLS/authorization assertion (a superuser
-- bypasses RLS and would make that half of the suite pass vacuously). The
-- rule-engine fixtures themselves are seeded as superuser, then
-- evaluate_station_pollutant_anomaly is called either with NO authenticated
-- context (auth.uid() null — mirrors the ingest service's service_role
-- caller, which is the real production caller) or as a specific role, per
-- test, to exercise both paths explicitly.
--
-- Isolation note: `evaluate_station_pollutant_anomaly` computes local_excess
-- from the CITY-WIDE average of every OTHER currently-reporting station, by
-- design (plan's own "local excess above city/background baseline"). That
-- means two tests sharing one city_config row would contaminate each
-- other's baselines. Every scenario below therefore gets its OWN dedicated
-- city_config row (with its own background station), not a shared one —
-- deliberate, not an oversight; sharing one Delhi-like city across all these
-- scenarios is exactly what produced flaky, order-dependent results during
-- manual verification of this migration.

create table if not exists t_ids (k text primary key, v bigint);
grant select on t_ids to authenticated;
truncate t_ids;

create or replace function as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p::text, 'role', 'authenticated')::text, false);
end $$;

reset role;

-- ---------- shared profiles (fixed uuids, matching every other test file) ----------
insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111','citizen@x.com'),
  ('22222222-2222-2222-2222-222222222222','officer@x.com'),
  ('66666666-6666-6666-6666-666666666666','officer2@x.com'),
  ('44444444-4444-4444-4444-444444444444','cmd@x.com')
on conflict do nothing;

insert into profiles (id, role, ward_id, full_name) values
  ('11111111-1111-1111-1111-111111111111','citizen',1,'A Citizen'),
  ('22222222-2222-2222-2222-222222222222','field_officer',1,'Officer Singh'),
  ('66666666-6666-6666-6666-666666666666','field_officer',2,'Officer Two'),
  ('44444444-4444-4444-4444-444444444444','commander',null,'Cmdr Rao')
on conflict (id) do update set role=excluded.role, ward_id=excluded.ward_id, full_name=excluded.full_name;

grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant execute on function evaluate_station_pollutant_anomaly(bigint, text) to authenticated;
grant execute on function run_anomaly_detection(text) to authenticated;

-- helper: a fresh, fully-isolated test city + one low background station.
-- Returns nothing; callers pull the new ids back out of city_config/wards/
-- stations by the names they just inserted (matches this suite's existing
-- style of chaining \gset off a preceding insert, not a plpgsql helper).

select 'TEST 41: one isolated high reading does not create an incident' as t;
do $$
declare v_city bigint; v_ward_bg bigint; v_ward bigint; v_station_bg bigint; v_station bigint; v_candidate bigint; v_n int;
begin
  insert into city_config (city_code, name, pollutant_priority, config) values
    ('t41', 'Test City 41', array['pm25','pm10','no2'],
     jsonb_build_object('anomaly_detection', jsonb_build_object(
       'pollutant_thresholds', jsonb_build_object('pm25',90,'pm10',250,'no2',180),
       'persistence_window_readings',3,'persistence_min_count',2,'local_excess_min',20,
       'nearby_station_radius_m',5000,'data_completeness_min',0.5,'data_freshness_max_minutes',180,
       'prediction_horizon_hours',6,'dedup_window_hours',12)))
    returning id into v_city;
  insert into wards (name, city_id) values ('t41-bg', v_city) returning id into v_ward_bg;
  insert into wards (name, city_id) values ('t41-a', v_city) returning id into v_ward;
  insert into stations (ward_id, name, sensor_type, lat, lng) values (v_ward_bg, 't41 bg', 'regulatory', 28.60, 77.05) returning id into v_station_bg;
  insert into stations (ward_id, name, sensor_type, lat, lng) values (v_ward, 't41 station', 'regulatory', 28.70, 77.10) returning id into v_station;
  insert into readings (station_id, ts, pm25) values (v_station_bg, now() - interval '1 hour', 40);
  insert into readings (station_id, ts, pm25) values
    (v_station, now() - interval '1 hour', 200),
    (v_station, now() - interval '2 hour', 60),
    (v_station, now() - interval '3 hour', 55);

  v_candidate := evaluate_station_pollutant_anomaly(v_station, 'pm25');
  select count(*) into v_n from incidents where ward_id = v_ward;
  if (select detection_stage from anomaly_candidates where id = v_candidate) is null
     and (select incident_id from anomaly_candidates where id = v_candidate) is null
     and (select triggered_rules from anomaly_candidates where id = v_candidate) @> '["concentration_threshold"]'::jsonb
     and not (select triggered_rules from anomaly_candidates where id = v_candidate) @> '["persistence"]'::jsonb
     and v_n = 0
  then raise notice '41 PASS: threshold fired but persistence did not — no incident created';
  else raise notice '41 FAIL'; end if;
end $$;

select 'TEST 42: persistent valid readings + meaningful local excess creates a detected incident' as t;
do $$
declare v_city bigint; v_ward_bg bigint; v_ward bigint; v_station_bg bigint; v_station bigint; v_candidate bigint;
begin
  insert into city_config (city_code, name, pollutant_priority, config) values
    ('t42', 'Test City 42', array['pm25','pm10','no2'],
     jsonb_build_object('anomaly_detection', jsonb_build_object(
       'pollutant_thresholds', jsonb_build_object('pm25',90,'pm10',250,'no2',180),
       'persistence_window_readings',3,'persistence_min_count',2,'local_excess_min',20,
       'nearby_station_radius_m',5000,'data_completeness_min',0.5,'data_freshness_max_minutes',180,
       'prediction_horizon_hours',6,'dedup_window_hours',12)))
    returning id into v_city;
  insert into wards (name, city_id) values ('t42-bg', v_city) returning id into v_ward_bg;
  insert into wards (name, city_id) values ('t42-a', v_city) returning id into v_ward;
  insert into stations (ward_id, name, sensor_type, lat, lng) values (v_ward_bg, 't42 bg', 'regulatory', 28.60, 77.05) returning id into v_station_bg;
  insert into stations (ward_id, name, sensor_type, lat, lng) values (v_ward, 't42 station', 'regulatory', 28.70, 77.10) returning id into v_station;
  insert into readings (station_id, ts, pm25) values (v_station_bg, now() - interval '1 hour', 40);
  insert into readings (station_id, ts, pm25) values
    (v_station, now() - interval '1 hour', 200),
    (v_station, now() - interval '2 hour', 180),
    (v_station, now() - interval '3 hour', 150);

  v_candidate := evaluate_station_pollutant_anomaly(v_station, 'pm25');
  insert into t_ids (k, v) values ('t42_candidate', v_candidate), ('t42_ward', v_ward), ('t42_city', v_city), ('t42_station', v_station)
    on conflict (k) do update set v = excluded.v;

  if (select detection_stage from anomaly_candidates where id = v_candidate) = 'detected'
     and (select incident_id from anomaly_candidates where id = v_candidate) is not null
     and (select local_excess from anomaly_candidates where id = v_candidate) > 100
  then raise notice '42 PASS: detected stage, incident created, local_excess=%', (select round(local_excess::numeric,1) from anomaly_candidates where id = v_candidate);
  else raise notice '42 FAIL'; end if;

  if exists (
    select 1 from incidents i join anomaly_candidates c on c.incident_id = i.id
    where c.id = v_candidate
      and i.status = 'detected' and i.detection_stage = 'detected'
      and i.detection_method = 'anomaly_persistence_threshold'
      and i.primary_pollutant = 'pm25' and i.source_confidence = 'suspected'
  ) then raise notice '42b PASS: incident row correctly labelled (status/detection_stage/detection_method/primary_pollutant/source_confidence)';
  else raise notice '42b FAIL'; end if;
end $$;

select 'TEST 43: duplicate detection — a second firing in the same ward updates the SAME incident' as t;
do $$
declare v_ward bigint; v_station bigint; v_first_incident bigint; v_c2 bigint; v_n int;
begin
  select v into v_ward from t_ids where k = 't42_ward';
  select v into v_station from t_ids where k = 't42_station';
  select incident_id into v_first_incident from anomaly_candidates where id = (select v from t_ids where k = 't42_candidate');

  insert into readings (station_id, ts, pm25) values (v_station, now(), 210);
  v_c2 := evaluate_station_pollutant_anomaly(v_station, 'pm25');

  select count(*) into v_n from incidents where ward_id = v_ward and primary_pollutant = 'pm25';
  if v_n = 1 then raise notice '43 PASS: still exactly one incident for this ward+pollutant';
  else raise notice '43 FAIL: % incidents', v_n; end if;

  if (select incident_id from anomaly_candidates where id = v_c2) = v_first_incident
  then raise notice '43b PASS: the second candidate linked to the SAME incident (%), not a new one', v_first_incident;
  else raise notice '43b FAIL'; end if;
end $$;

select 'TEST 44: stale data is suppressed — no incident regardless of how extreme the value looks' as t;
do $$
declare v_city bigint; v_ward_bg bigint; v_ward bigint; v_station_bg bigint; v_station bigint; v_candidate bigint;
begin
  insert into city_config (city_code, name, pollutant_priority, config) values
    ('t44', 'Test City 44', array['pm25','pm10','no2'],
     jsonb_build_object('anomaly_detection', jsonb_build_object(
       'pollutant_thresholds', jsonb_build_object('pm25',90),
       'persistence_window_readings',3,'persistence_min_count',2,'local_excess_min',20,
       'nearby_station_radius_m',5000,'data_completeness_min',0.5,'data_freshness_max_minutes',180,
       'prediction_horizon_hours',6,'dedup_window_hours',12)))
    returning id into v_city;
  insert into wards (name, city_id) values ('t44-bg', v_city) returning id into v_ward_bg;
  insert into wards (name, city_id) values ('t44-a', v_city) returning id into v_ward;
  insert into stations (ward_id, name, sensor_type) values (v_ward_bg, 't44 bg', 'regulatory') returning id into v_station_bg;
  insert into stations (ward_id, name, sensor_type) values (v_ward, 't44 station', 'regulatory') returning id into v_station;
  insert into readings (station_id, ts, pm25) values (v_station_bg, now() - interval '1 hour', 40);
  insert into readings (station_id, ts, pm25) values
    (v_station, now() - interval '10 hour', 200),
    (v_station, now() - interval '11 hour', 190),
    (v_station, now() - interval '12 hour', 180);

  v_candidate := evaluate_station_pollutant_anomaly(v_station, 'pm25');
  if (select suppressed from anomaly_candidates where id = v_candidate)
     and (select suppression_reason from anomaly_candidates where id = v_candidate) like '%offline%'
     and (select incident_id from anomaly_candidates where id = v_candidate) is null
  then raise notice '44 PASS: suppressed for staleness — %', (select suppression_reason from anomaly_candidates where id = v_candidate);
  else raise notice '44 FAIL'; end if;
end $$;

select 'TEST 45: incomplete data is suppressed' as t;
do $$
declare v_city bigint; v_ward_bg bigint; v_ward bigint; v_station_bg bigint; v_station bigint; v_candidate bigint;
begin
  insert into city_config (city_code, name, pollutant_priority, config) values
    ('t45', 'Test City 45', array['pm25','pm10','no2'],
     jsonb_build_object('anomaly_detection', jsonb_build_object(
       'pollutant_thresholds', jsonb_build_object('pm25',90),
       'persistence_window_readings',3,'persistence_min_count',2,'local_excess_min',20,
       'nearby_station_radius_m',5000,'data_completeness_min',0.5,'data_freshness_max_minutes',180,
       'prediction_horizon_hours',6,'dedup_window_hours',12)))
    returning id into v_city;
  insert into wards (name, city_id) values ('t45-bg', v_city) returning id into v_ward_bg;
  insert into wards (name, city_id) values ('t45-a', v_city) returning id into v_ward;
  insert into stations (ward_id, name, sensor_type) values (v_ward_bg, 't45 bg', 'regulatory') returning id into v_station_bg;
  insert into stations (ward_id, name, sensor_type) values (v_ward, 't45 station', 'regulatory') returning id into v_station;
  insert into readings (station_id, ts, pm25) values (v_station_bg, now() - interval '1 hour', 40);
  insert into readings (station_id, ts, pm25) values (v_station, now() - interval '1 hour', 200);

  v_candidate := evaluate_station_pollutant_anomaly(v_station, 'pm25');
  if (select suppressed from anomaly_candidates where id = v_candidate)
     and (select suppression_reason from anomaly_candidates where id = v_candidate) like '%complete%'
     and (select incident_id from anomaly_candidates where id = v_candidate) is null
  then raise notice '45 PASS: suppressed for low completeness — %', (select suppression_reason from anomaly_candidates where id = v_candidate);
  else raise notice '45 FAIL'; end if;
end $$;

select 'TEST 46: regulatory and low-cost/indicative sensors are treated differently' as t;
do $$
declare v_city bigint; v_ward_bg bigint; v_ward bigint; v_station_bg bigint; v_reg bigint; v_ind bigint; v_cr bigint; v_ci bigint;
begin
  insert into city_config (city_code, name, pollutant_priority, config) values
    ('t46', 'Test City 46', array['pm25','pm10','no2'],
     jsonb_build_object('anomaly_detection', jsonb_build_object(
       'pollutant_thresholds', jsonb_build_object('pm25',90),
       'persistence_window_readings',3,'persistence_min_count',2,'local_excess_min',20,
       'nearby_station_radius_m',5000,'data_completeness_min',0.5,'data_freshness_max_minutes',180,
       'prediction_horizon_hours',6,'dedup_window_hours',12)))
    returning id into v_city;
  insert into wards (name, city_id) values ('t46-bg', v_city) returning id into v_ward_bg;
  insert into wards (name, city_id) values ('t46-a', v_city) returning id into v_ward;
  insert into stations (ward_id, name, sensor_type) values (v_ward_bg, 't46 bg', 'regulatory') returning id into v_station_bg;
  insert into stations (ward_id, name, sensor_type) values (v_ward, 't46 reg', 'regulatory') returning id into v_reg;
  insert into stations (ward_id, name, sensor_type) values (v_ward, 't46 ind', 'indicative') returning id into v_ind;
  insert into readings (station_id, ts, pm25) values (v_station_bg, now() - interval '1 hour', 40);
  insert into readings (station_id, ts, pm25) values
    (v_reg, now() - interval '1 hour', 200), (v_reg, now() - interval '2 hour', 190), (v_reg, now() - interval '3 hour', 180),
    (v_ind, now() - interval '1 hour', 200), (v_ind, now() - interval '2 hour', 190), (v_ind, now() - interval '3 hour', 180);

  v_cr := evaluate_station_pollutant_anomaly(v_reg, 'pm25');
  v_ci := evaluate_station_pollutant_anomaly(v_ind, 'pm25');

  if (select confidence from anomaly_candidates where id = v_cr) > (select confidence from anomaly_candidates where id = v_ci)
  then raise notice '46 PASS: regulatory confidence (%) > indicative confidence (%)',
    (select confidence from anomaly_candidates where id = v_cr), (select confidence from anomaly_candidates where id = v_ci);
  else raise notice '46 FAIL'; end if;

  if (select sensor_quality from anomaly_candidates where id = v_cr) = 'regulatory'
     and (select sensor_quality from anomaly_candidates where id = v_ci) = 'indicative'
  then raise notice '46b PASS: sensor_quality snapshot recorded correctly on each candidate';
  else raise notice '46b FAIL'; end if;
end $$;

select 'TEST 47: predicted stage — trending toward the threshold, not yet crossing it' as t;
do $$
declare v_city bigint; v_ward_bg bigint; v_ward bigint; v_station_bg bigint; v_station bigint; v_candidate bigint;
begin
  insert into city_config (city_code, name, pollutant_priority, config) values
    ('t47', 'Test City 47', array['pm25','pm10','no2'],
     jsonb_build_object('anomaly_detection', jsonb_build_object(
       'pollutant_thresholds', jsonb_build_object('pm25',90),
       'persistence_window_readings',3,'persistence_min_count',2,'local_excess_min',20,
       'nearby_station_radius_m',5000,'data_completeness_min',0.5,'data_freshness_max_minutes',180,
       'prediction_horizon_hours',6,'dedup_window_hours',12)))
    returning id into v_city;
  insert into wards (name, city_id) values ('t47-bg', v_city) returning id into v_ward_bg;
  insert into wards (name, city_id) values ('t47-a', v_city) returning id into v_ward;
  insert into stations (ward_id, name, sensor_type) values (v_ward_bg, 't47 bg', 'regulatory') returning id into v_station_bg;
  insert into stations (ward_id, name, sensor_type) values (v_ward, 't47 station', 'regulatory') returning id into v_station;
  insert into readings (station_id, ts, pm25) values (v_station_bg, now() - interval '1 hour', 40);
  insert into readings (station_id, ts, pm25) values
    (v_station, now() - interval '1 hour', 70),
    (v_station, now() - interval '2 hour', 55),
    (v_station, now() - interval '3 hour', 40);

  v_candidate := evaluate_station_pollutant_anomaly(v_station, 'pm25');
  insert into t_ids (k, v) values ('t47_candidate', v_candidate) on conflict (k) do update set v = excluded.v;

  if (select detection_stage from anomaly_candidates where id = v_candidate) = 'predicted'
     and (select projected_crossing_at from anomaly_candidates where id = v_candidate) is not null
     and (select incident_id from anomaly_candidates where id = v_candidate) is not null
  then raise notice '47 PASS: predicted stage, crossing projected at %', (select projected_crossing_at from anomaly_candidates where id = v_candidate);
  else raise notice '47 FAIL: stage=%', (select detection_stage from anomaly_candidates where id = v_candidate); end if;

  if (select detection_stage from incidents where id = (select incident_id from anomaly_candidates where id = v_candidate)) = 'predicted'
  then raise notice '47b PASS: the incident itself is labelled predicted';
  else raise notice '47b FAIL'; end if;
end $$;

select 'TEST 48: thresholds are city-configurable' as t;
do $$
declare v_city bigint; v_ward_bg bigint; v_ward bigint; v_station_bg bigint; v_station bigint; v_candidate bigint;
begin
  insert into city_config (city_code, name, pollutant_priority, config) values
    ('t48', 'Test City 48', array['pm25','pm10','no2'],
     jsonb_build_object('anomaly_detection', jsonb_build_object(
       'pollutant_thresholds', jsonb_build_object('pm25', 20),  -- deliberately far below the Delhi default (90)
       'persistence_window_readings',3,'persistence_min_count',2,'local_excess_min',5,
       'nearby_station_radius_m',5000,'data_completeness_min',0.5,'data_freshness_max_minutes',180,
       'prediction_horizon_hours',6,'dedup_window_hours',12)))
    returning id into v_city;
  insert into wards (name, city_id) values ('t48-bg', v_city) returning id into v_ward_bg;
  insert into wards (name, city_id) values ('t48-a', v_city) returning id into v_ward;
  insert into stations (ward_id, name, sensor_type) values (v_ward_bg, 't48 bg', 'regulatory') returning id into v_station_bg;
  insert into stations (ward_id, name, sensor_type) values (v_ward, 't48 station', 'regulatory') returning id into v_station;
  insert into readings (station_id, ts, pm25) values (v_station_bg, now() - interval '1 hour', 5);
  insert into readings (station_id, ts, pm25) values
    (v_station, now() - interval '1 hour', 30), (v_station, now() - interval '2 hour', 28), (v_station, now() - interval '3 hour', 25);

  v_candidate := evaluate_station_pollutant_anomaly(v_station, 'pm25');
  if (select threshold_used from anomaly_candidates where id = v_candidate) = 20
     and (select detection_stage from anomaly_candidates where id = v_candidate) = 'detected'
  then raise notice '48 PASS: this city''s own configured threshold (20) was used — a reading that would never fire on Delhi''s default (90) fired here';
  else raise notice '48 FAIL: threshold_used=%, stage=%', (select threshold_used from anomaly_candidates where id = v_candidate), (select detection_stage from anomaly_candidates where id = v_candidate); end if;
end $$;

select 'TEST 49: predicted/detected incidents cannot create enforcement actions' as t;
do $$
declare v_incident bigint; v_n int;
begin
  select incident_id into v_incident from anomaly_candidates where id = (select v from t_ids where k = 't42_candidate');

  select count(*) into v_n from actions where incident_id = v_incident;
  if v_n = 0 then raise notice '49a PASS: the detection engine itself never created an actions row';
  else raise notice '49a FAIL: % actions row(s) already exist', v_n; end if;

  perform as_user('44444444-4444-4444-4444-444444444444');
  set role authenticated;
  begin
    insert into actions (incident_id, ward_id, type, recommended_action, responsible_agency, custom_reason)
      values (v_incident, (select ward_id from incidents where id = v_incident), 'penalty', 'Enforcement attempt', 'MCD', 'testing');
    raise notice '49b FAIL: enforcement action created on a freshly auto-detected (suspected) incident';
  exception when check_violation then raise notice '49b PASS: blocked — a freshly auto-detected incident starts at suspected, same evidence-level gate as any other incident';
  end;
  reset role;
end $$;

select 'TEST 50: local excess is calculated correctly (current minus the city-wide background average)' as t;
do $$
declare v_candidate bigint; v_current double precision; v_baseline double precision; v_excess double precision;
begin
  v_candidate := (select v from t_ids where k = 't42_candidate');
  select current_concentration, baseline_value, local_excess
    into v_current, v_baseline, v_excess
    from anomaly_candidates where id = v_candidate;
  if abs(v_excess - (v_current - v_baseline)) < 0.001
  then raise notice '50 PASS: local_excess (%) = current (%) - baseline (%)', round(v_excess::numeric,1), round(v_current::numeric,1), round(v_baseline::numeric,1);
  else raise notice '50 FAIL'; end if;
end $$;

select 'TEST 51: RLS — citizens have zero read on anomaly_candidates; field officers are ward-scoped' as t;
do $$
declare v_ward bigint; v_officer_ward bigint; n int;
begin
  select v into v_ward from t_ids where k = 't42_ward';

  -- give officer2 (fixture: ward 2) a station+candidate in THEIR OWN ward so
  -- the "same ward succeeds" half of this test is a genuine positive case,
  -- not just an absence-of-access check.
  insert into stations (ward_id, name, sensor_type) values (2, 't51 officer2 station', 'regulatory') returning ward_id into v_officer_ward;
  insert into anomaly_candidates (ward_id, pollutant, current_concentration, triggered_rules)
    values (v_officer_ward, 'pm25', 100, '["concentration_threshold"]'::jsonb);

  set role authenticated;
  perform as_user('11111111-1111-1111-1111-111111111111');
  select count(*) into n from anomaly_candidates where ward_id = v_ward;
  if n = 0 then raise notice '51a PASS: citizen has zero read on anomaly_candidates (internal detection detail)';
  else raise notice '51a FAIL: citizen read % row(s)', n; end if;

  perform as_user('22222222-2222-2222-2222-222222222222');
  select count(*) into n from anomaly_candidates where ward_id = v_ward;
  if n = 0 then raise notice '51b PASS: field officer (ward 1) cannot read another ward''s anomaly candidates';
  else raise notice '51b FAIL: officer read % row(s) outside their ward', n; end if;

  perform as_user('66666666-6666-6666-6666-666666666666');
  select count(*) into n from anomaly_candidates where ward_id = v_officer_ward;
  if n > 0 then raise notice '51d PASS: field officer (ward 2) can read their OWN ward''s anomaly candidates';
  else raise notice '51d FAIL'; end if;

  perform as_user('44444444-4444-4444-4444-444444444444');
  select count(*) into n from anomaly_candidates where ward_id = v_ward;
  if n > 0 then raise notice '51c PASS: commander can read anomaly candidates for any ward (% row(s))', n;
  else raise notice '51c FAIL'; end if;
  reset role;
end $$;

select 'TEST 52: only a commander/admin (or an unauthenticated service context) may run detection' as t;
do $$
declare v_city bigint; v_ward bigint; v_station bigint;
begin
  insert into city_config (city_code, name, pollutant_priority, config) values
    ('t52', 'Test City 52', array['pm25'], '{}'::jsonb) returning id into v_city;
  insert into wards (name, city_id) values ('t52-a', v_city) returning id into v_ward;
  insert into stations (ward_id, name, sensor_type) values (v_ward, 't52 station', 'regulatory') returning id into v_station;

  set role authenticated;
  perform as_user('11111111-1111-1111-1111-111111111111');
  begin
    perform evaluate_station_pollutant_anomaly(v_station, 'pm25');
    raise notice '52a FAIL: citizen ran anomaly detection';
  exception when insufficient_privilege then raise notice '52a PASS: blocked (citizen)';
  end;

  perform as_user('22222222-2222-2222-2222-222222222222');
  begin
    perform evaluate_station_pollutant_anomaly(v_station, 'pm25');
    raise notice '52b FAIL: field officer ran anomaly detection';
  exception when insufficient_privilege then raise notice '52b PASS: blocked (field officer)';
  end;

  perform as_user('44444444-4444-4444-4444-444444444444');
  begin
    perform evaluate_station_pollutant_anomaly(v_station, 'pm25');
    raise notice '52c PASS: commander can run detection directly';
  exception when others then raise notice '52c FAIL: %', sqlerrm;
  end;
  reset role;
end $$;

select 'TEST 53: command can promote a predicted/detected incident to confirmed' as t;
do $$
declare v_incident bigint;
begin
  select incident_id into v_incident from anomaly_candidates where id = (select v from t_ids where k = 't42_candidate');

  set role authenticated;
  perform as_user('44444444-4444-4444-4444-444444444444');
  update incidents set detection_stage = 'confirmed', updated_at = now() where id = v_incident;
  insert into incident_events (incident_id, event_type, actor_id, note, is_public, payload)
    values (v_incident, 'promoted_to_active', '44444444-4444-4444-4444-444444444444', 'Confirmed by command as a genuine pollution event.', true, '{"detection_stage":"confirmed"}');
  reset role;

  if (select detection_stage from incidents where id = v_incident) = 'confirmed'
  then raise notice '53 PASS: incident promoted to confirmed';
  else raise notice '53 FAIL'; end if;
end $$;

select 'TEST 54: command can dismiss a predicted incident as a data anomaly' as t;
do $$
declare v_incident bigint;
begin
  select incident_id into v_incident from anomaly_candidates where id = (select v from t_ids where k = 't47_candidate');

  set role authenticated;
  perform as_user('44444444-4444-4444-4444-444444444444');
  update incidents set status = 'closed', closed_at = now(), updated_at = now() where id = v_incident;
  insert into incident_events (incident_id, event_type, actor_id, note, is_public, payload)
    values (v_incident, 'predicted_incident_dismissed', '44444444-4444-4444-4444-444444444444', 'Reviewed and closed: determined to be a data anomaly.', true, '{"decision":"dismissed"}');
  reset role;

  if (select status from incidents where id = v_incident) = 'closed'
     and exists (select 1 from incident_events where incident_id = v_incident and event_type = 'predicted_incident_dismissed')
  then raise notice '54 PASS: incident dismissed and the dismissal is auditable';
  else raise notice '54 FAIL'; end if;
end $$;

select 'TEST 55: run_anomaly_detection iterates every station × the city''s own pollutant_priority list' as t;
do $$
declare v_city bigint; v_ward bigint; v_s1 bigint; v_s2 bigint; v_n int;
begin
  insert into city_config (city_code, name, pollutant_priority, config) values
    ('t55', 'Test City 55', array['pm25','no2'],
     jsonb_build_object('anomaly_detection', jsonb_build_object(
       'pollutant_thresholds', jsonb_build_object('pm25',900,'no2',900), -- unreachable thresholds: this test only checks COVERAGE, not firing
       'persistence_window_readings',3,'persistence_min_count',2,'local_excess_min',20,
       'nearby_station_radius_m',5000,'data_completeness_min',0.5,'data_freshness_max_minutes',180,
       'prediction_horizon_hours',6,'dedup_window_hours',12)))
    returning id into v_city;
  insert into wards (name, city_id) values ('t55-a', v_city) returning id into v_ward;
  insert into stations (ward_id, name, sensor_type) values (v_ward, 't55 s1', 'regulatory') returning id into v_s1;
  insert into stations (ward_id, name, sensor_type) values (v_ward, 't55 s2', 'regulatory') returning id into v_s2;
  insert into readings (station_id, ts, pm25, no2) values (v_s1, now(), 10, 10), (v_s2, now(), 10, 10);

  set role authenticated;
  perform as_user('44444444-4444-4444-4444-444444444444');
  select count(*) into v_n from run_anomaly_detection('t55');
  reset role;

  -- 2 stations x 2 configured pollutants (pm25, no2 — NOT so2/co/o3, which this
  -- test city never listed in pollutant_priority) = 4 evaluations.
  if v_n = 4 then raise notice '55 PASS: evaluated exactly 2 stations x 2 priority pollutants (%)', v_n;
  else raise notice '55 FAIL: got % evaluations', v_n; end if;
end $$;

select 'TEST 56: merging a predicted incident into an existing one is auditable both ways' as t;
do $$
declare v_city bigint; v_ward bigint; v_station bigint; v_source bigint; v_target bigint; v_n int;
begin
  insert into city_config (city_code, name, pollutant_priority, config) values ('t56', 'Test City 56', array['pm25'], '{}'::jsonb) returning id into v_city;
  insert into wards (name, city_id) values ('t56-a', v_city) returning id into v_ward;
  insert into stations (ward_id, name, sensor_type) values (v_ward, 't56 station', 'regulatory') returning id into v_station;
  insert into incidents (ward_id, status, detection_method, source_confidence, primary_pollutant, summary)
    values (v_ward, 'evidence_gathering', 'manual', 'suspected', 'pm25', 'existing nearby incident') returning id into v_target;
  insert into incidents (ward_id, status, detection_method, detection_stage, source_confidence, primary_pollutant, summary)
    values (v_ward, 'detected', 'anomaly_persistence_threshold', 'detected', 'suspected', 'pm25', 'predicted duplicate of the above') returning id into v_source;

  set role authenticated;
  perform as_user('44444444-4444-4444-4444-444444444444');
  insert into incident_evidence (incident_id, evidence_type, supports, payload, collected_by)
    values (v_target, 'sensor', true, jsonb_build_object('source_incident_id', v_source), '44444444-4444-4444-4444-444444444444');
  update incidents set status = 'closed', closed_at = now(), merged_into_incident_id = v_target, updated_at = now() where id = v_source;
  insert into incident_events (incident_id, event_type, actor_id, note, is_public, payload)
    values (v_source, 'predicted_incident_merged', '44444444-4444-4444-4444-444444444444', format('Merged into incident #%s.', v_target), true, jsonb_build_object('merged_into_incident_id', v_target));
  reset role;

  if (select merged_into_incident_id from incidents where id = v_source) = v_target
  then raise notice '56 PASS: source incident traces to the merge target';
  else raise notice '56 FAIL'; end if;

  select count(*) into v_n from incident_evidence where incident_id = v_target and evidence_type = 'sensor';
  if v_n = 1 then raise notice '56b PASS: target incident gained corroborating sensor evidence';
  else raise notice '56b FAIL'; end if;
end $$;

reset role;
reset request.jwt.claims;
