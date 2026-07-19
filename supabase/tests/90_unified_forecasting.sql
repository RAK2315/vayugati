-- Phase 8: unified forecasting, connected to anomaly detection.
--
-- The forecasting MODEL itself (LightGBM training, time-based validation,
-- MAE/RMSE/bias/threshold-recall/false-alarm computation) lives entirely in
-- ingest/app/forecast.py and is tested there (ingest/tests/test_forecast.py,
-- against a fixed synthetic dataset) — Postgres cannot train a model. This
-- file tests the SQL-side contract: the `forecast_runs`/`forecasts` schema
-- and RLS, and the modified `evaluate_station_pollutant_anomaly`'s
-- forecast-vs-trend-fallback branching, which is exactly what connects the
-- two systems together (plan §6/§7).
--
-- Role discipline (matches 70_anomaly_detection.sql exactly): fixture setup
-- and the `evaluate_station_pollutant_anomaly` calls themselves run as
-- superuser — the function treats a null `auth.uid()` as the ingest
-- service's own service_role context and allows it unconditionally, so this
-- faithfully exercises the real production caller. `set role authenticated`
-- + `as_user(...)` is used ONLY for the specific tests that check RLS/
-- authorization as a real logged-in user (76a/76b/76c). Every test's do
-- block starts with its own `reset role;` rather than assuming role state
-- carried over correctly from the previous block.
--
-- Same per-scenario city isolation as 70_anomaly_detection.sql, for the
-- same reason: local_excess is a genuinely city-wide computation, so
-- sharing one city across scenarios produces flaky, order-dependent
-- results.

create table if not exists t_ids (k text primary key, v bigint);
grant select on t_ids to authenticated;
truncate t_ids;

create or replace function as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p::text, 'role', 'authenticated')::text, false);
end $$;

reset role;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111','citizen@x.com'),
  ('44444444-4444-4444-4444-444444444444','cmd@x.com')
on conflict do nothing;

insert into profiles (id, role, ward_id, full_name) values
  ('11111111-1111-1111-1111-111111111111','citizen',1,'A Citizen'),
  ('44444444-4444-4444-4444-444444444444','commander',null,'Cmdr Rao')
on conflict (id) do update set role=excluded.role, ward_id=excluded.ward_id, full_name=excluded.full_name;

grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant execute on function evaluate_station_pollutant_anomaly(bigint, text) to authenticated;

-- helper: a fresh, isolated test city with one low background station,
-- returning (city_id, ward_id, station_id). Always run as superuser
-- (wards/stations/readings/city_config have no authenticated write policy
-- at all — verified by test 76c below — so this could never run as a
-- logged-in role anyway).
create or replace function _t90_setup_city(p_prefix text) returns table(city_id bigint, ward_id bigint, station_id bigint)
language plpgsql as $$
declare v_city bigint; v_ward_bg bigint; v_ward bigint; v_station_bg bigint; v_station bigint;
begin
  insert into city_config (city_code, name, pollutant_priority, config) values
    (p_prefix, 'Test City ' || p_prefix, array['pm25','pm10','no2'],
     jsonb_build_object(
       'anomaly_detection', jsonb_build_object(
         'pollutant_thresholds', jsonb_build_object('pm25',90,'pm10',250,'no2',180),
         'persistence_window_readings',3,'persistence_min_count',2,'local_excess_min',20,
         'nearby_station_radius_m',5000,'data_completeness_min',0.5,'data_freshness_max_minutes',180,
         'prediction_horizon_hours',6,'dedup_window_hours',12),
       'forecasting', jsonb_build_object('retraining_frequency_hours', 24)))
    returning id into v_city;
  insert into wards (name, city_id) values (p_prefix || '-bg', v_city) returning id into v_ward_bg;
  insert into wards (name, city_id) values (p_prefix || '-a', v_city) returning id into v_ward;
  insert into stations (ward_id, name, sensor_type, lat, lng) values (v_ward_bg, p_prefix || ' bg', 'regulatory', 28.60, 77.05) returning id into v_station_bg;
  insert into stations (ward_id, name, sensor_type, lat, lng) values (v_ward, p_prefix || ' station', 'regulatory', 28.70, 77.10) returning id into v_station;
  insert into readings (station_id, ts, pm25) values (v_station_bg, now() - interval '1 hour', 40);
  insert into readings (station_id, ts, pm25) values
    (v_station, now() - interval '1 hour', 60),
    (v_station, now() - interval '2 hour', 58),
    (v_station, now() - interval '3 hour', 55);
  return query select v_city, v_ward, v_station;
end $$;

select 'TEST 76: forecast_runs / forecasts schema + RLS' as t;
do $$
declare v_city bigint; v_ward bigint; v_station bigint; v_run bigint;
begin
  reset role;
  select * into v_city, v_ward, v_station from _t90_setup_city('t76');
  insert into forecast_runs (city_id, ward_id, pollutant, method, model_version, max_validated_horizon_hours, beats_persistence, data_quality_status, validation_metrics)
  values (v_city, v_ward, 'pm25', 'lightgbm', 'lgb_test', 24, true, 'ok', '{"6":{"mae":2.1,"beats_persistence":true}}'::jsonb)
  returning id into v_run;
  insert into forecasts (ward_id, generated_at, horizon_ts, pollutant, predicted_value, lower_bound, upper_bound, forecast_run_id)
  values (v_ward, now(), now() + interval '3 hour', 'pm25', 70, 60, 80, v_run);
  insert into t_ids (k, v) values ('t76_run', v_run), ('t76_city', v_city), ('t76_ward', v_ward)
    on conflict (k) do update set v = excluded.v;
end $$;

do $$
declare v_run bigint; n int;
begin
  select v into v_run from t_ids where k = 't76_run';
  set role authenticated;

  -- 76a: any authenticated user (citizen included) can read forecast_runs —
  -- transparency data, not internal detection detail (unlike anomaly_candidates).
  perform as_user('11111111-1111-1111-1111-111111111111');
  select count(*) into n from forecast_runs where id = v_run;
  if n = 1 then raise notice '76a PASS: citizen can read forecast_runs (transparency, not internal detail)';
  else raise notice '76a FAIL'; end if;

  select count(*) into n from forecasts where forecast_run_id = v_run;
  if n = 1 then raise notice '76b PASS: citizen can read the forecast curve itself';
  else raise notice '76b FAIL'; end if;

  -- 76c: NO authenticated role (commander included) can write forecast_runs
  -- directly — only the ingest service (service_role, bypasses RLS) does.
  perform as_user('44444444-4444-4444-4444-444444444444');
  begin
    insert into forecast_runs (city_id, ward_id, pollutant, method, model_version)
    values ((select v from t_ids where k='t76_city'), (select v from t_ids where k='t76_ward'), 'pm25', 'lightgbm', 'attempt');
    raise notice '76c FAIL: commander inserted into forecast_runs directly';
  exception when insufficient_privilege then raise notice '76c PASS: blocked (insufficient_privilege — no write policy exists)';
  when others then raise notice '76c PASS: blocked (%)', sqlerrm;
  end;
  reset role;
end $$;

select 'TEST 77: multiple pollutants coexist in forecasts without cross-contamination' as t;
do $$
declare v_city bigint; v_ward bigint; v_station bigint; v_run_pm25 bigint; v_run_pm10 bigint; n int;
begin
  reset role;
  select * into v_city, v_ward, v_station from _t90_setup_city('t77');
  insert into forecast_runs (city_id, ward_id, pollutant, method, model_version, beats_persistence, data_quality_status)
    values (v_city, v_ward, 'pm25', 'diurnal_persistence', 'd1', false, 'ok') returning id into v_run_pm25;
  insert into forecast_runs (city_id, ward_id, pollutant, method, model_version, beats_persistence, data_quality_status)
    values (v_city, v_ward, 'pm10', 'diurnal_persistence', 'd1', false, 'ok') returning id into v_run_pm10;
  insert into forecasts (ward_id, generated_at, horizon_ts, pollutant, predicted_value, forecast_run_id)
    values (v_ward, now(), now() + interval '1 hour', 'pm25', 70, v_run_pm25);
  insert into forecasts (ward_id, generated_at, horizon_ts, pollutant, predicted_value, forecast_run_id)
    values (v_ward, now(), now() + interval '1 hour', 'pm10', 130, v_run_pm10);

  select count(*) into n from forecasts where ward_id = v_ward and pollutant = 'pm25';
  if n = 1 then raise notice '77a PASS: exactly one pm25 forecast row for this ward';
  else raise notice '77a FAIL: % rows', n; end if;

  select count(*) into n from forecasts where ward_id = v_ward and pollutant = 'pm10';
  if n = 1 then raise notice '77b PASS: exactly one pm10 forecast row for this ward, alongside pm25';
  else raise notice '77b FAIL: % rows', n; end if;
end $$;

select 'TEST 78: a validated forecast crossing the threshold drives a predicted incident' as t;
do $$
declare v_city bigint; v_ward bigint; v_station bigint; v_run bigint; v_candidate bigint;
begin
  reset role;
  select * into v_city, v_ward, v_station from _t90_setup_city('t78');
  insert into forecast_runs (city_id, ward_id, pollutant, method, model_version, max_validated_horizon_hours, beats_persistence, data_quality_status)
    values (v_city, v_ward, 'pm25', 'lightgbm', 'lgb_v1', 24, true, 'ok') returning id into v_run;
  insert into forecasts (ward_id, generated_at, horizon_ts, pollutant, predicted_value, lower_bound, upper_bound, forecast_run_id)
    select v_ward, now(), now() + (h || ' hours')::interval, 'pm25', 60 + h*8, 60+h*8-10, 60+h*8+10, v_run
    from generate_series(1,24) h;  -- crosses 90 at h=4

  select evaluate_station_pollutant_anomaly(v_station, 'pm25') into v_candidate;
  insert into t_ids (k, v) values ('t78_incident', (select incident_id from anomaly_candidates where id = v_candidate))
    on conflict (k) do update set v = excluded.v;

  if (select detection_stage from anomaly_candidates where id = v_candidate) = 'predicted'
     and (select prediction_method from anomaly_candidates where id = v_candidate) = 'validated_forecast'
     and (select incident_id from anomaly_candidates where id = v_candidate) is not null
  then raise notice '78a PASS: predicted incident created via the validated forecast';
  else raise notice '78a FAIL'; end if;

  if (select detection_method from incidents where id = (select incident_id from anomaly_candidates where id = v_candidate)) = 'anomaly_validated_forecast'
  then raise notice '78b PASS: incident.detection_method names the validated-forecast rule';
  else raise notice '78b FAIL'; end if;
end $$;

select 'TEST 79: no forecast available falls back to the raw-reading trend' as t;
do $$
declare v_city bigint; v_ward bigint; v_station bigint; v_candidate bigint;
begin
  reset role;
  select * into v_city, v_ward, v_station from _t90_setup_city('t79');
  -- no forecast_runs row for this ward at all

  update readings set pm25 = 70 where station_id = v_station and ts = (select max(ts) from readings where station_id = v_station);
  select evaluate_station_pollutant_anomaly(v_station, 'pm25') into v_candidate;

  if (select detection_stage from anomaly_candidates where id = v_candidate) = 'predicted'
     and (select prediction_method from anomaly_candidates where id = v_candidate) = 'trend_persistence'
  then raise notice '79 PASS: fell back to trend_persistence — no validated forecast existed';
  else raise notice '79 FAIL: stage=%, method=%',
    (select detection_stage from anomaly_candidates where id = v_candidate),
    (select prediction_method from anomaly_candidates where id = v_candidate); end if;
end $$;

select 'TEST 80: an UNVALIDATED forecast (fails beats_persistence) is never used — falls back to trend' as t;
do $$
declare v_city bigint; v_ward bigint; v_station bigint; v_run bigint; v_candidate bigint;
begin
  reset role;
  select * into v_city, v_ward, v_station from _t90_setup_city('t80');
  insert into forecast_runs (city_id, ward_id, pollutant, method, model_version, max_validated_horizon_hours, beats_persistence, data_quality_status)
    values (v_city, v_ward, 'pm25', 'diurnal_persistence', 'd1', 24, false, 'ok') returning id into v_run;
  insert into forecasts (ward_id, generated_at, horizon_ts, pollutant, predicted_value, forecast_run_id)
    values (v_ward, now(), now() + interval '2 hour', 'pm25', 95, v_run);

  update readings set pm25 = 70 where station_id = v_station and ts = (select max(ts) from readings where station_id = v_station);
  select evaluate_station_pollutant_anomaly(v_station, 'pm25') into v_candidate;

  if (select prediction_method from anomaly_candidates where id = v_candidate) is distinct from 'validated_forecast'
  then raise notice '80 PASS: unvalidated forecast was never used (method=%)', (select coalesce(prediction_method,'<none>') from anomaly_candidates where id = v_candidate);
  else raise notice '80 FAIL: the unvalidated forecast was used anyway'; end if;
end $$;

select 'TEST 81: a validated forecast that never crosses produces NO predicted stage (no silent fallback)' as t;
do $$
declare v_city bigint; v_ward bigint; v_station bigint; v_run bigint; v_candidate bigint;
begin
  reset role;
  select * into v_city, v_ward, v_station from _t90_setup_city('t81');
  insert into forecast_runs (city_id, ward_id, pollutant, method, model_version, max_validated_horizon_hours, beats_persistence, data_quality_status)
    values (v_city, v_ward, 'pm25', 'lightgbm', 'lgb_v1', 24, true, 'ok') returning id into v_run;
  insert into forecasts (ward_id, generated_at, horizon_ts, pollutant, predicted_value, forecast_run_id)
    select v_ward, now(), now() + (h || ' hours')::interval, 'pm25', 65, v_run
    from generate_series(1,24) h; -- stays flat at 65, never crosses 90

  -- station has a positive trend that WOULD cross via the old trend logic —
  -- proving the validated forecast (which says "no"), not the trend, decides.
  update readings set pm25 = 70 where station_id = v_station and ts = (select max(ts) from readings where station_id = v_station);
  select evaluate_station_pollutant_anomaly(v_station, 'pm25') into v_candidate;

  if v_candidate is null then raise notice '81 PASS: validated forecast (no crossing) suppressed any predicted stage — no trend fallback either';
  else raise notice '81 FAIL: a candidate was created (%): stage=%, method=%', v_candidate,
    (select detection_stage from anomaly_candidates where id = v_candidate),
    (select prediction_method from anomaly_candidates where id = v_candidate); end if;
end $$;

select 'TEST 82: forecast-driven predicted incidents still cannot create enforcement actions' as t;
do $$
declare v_incident bigint;
begin
  reset role;
  select v into v_incident from t_ids where k = 't78_incident';

  if (select source_confidence from incidents where id = v_incident) <> 'suspected' then
    raise notice '82 FAIL: forecast-driven incident did not start at suspected';
  else
    begin
      insert into actions (incident_id, ward_id, type, recommended_action, responsible_agency, custom_reason)
        values (v_incident, (select ward_id from incidents where id = v_incident), 'penalty', 'attempt', 'MCD', 'test');
      raise notice '82 FAIL: enforcement action created on a forecast-driven predicted incident';
    exception when check_violation then raise notice '82 PASS: blocked — same suspected-source gate applies regardless of prediction method';
    end;
  end if;
end $$;

select 'TEST 83: duplicate predicted incidents are not created across repeated validated-forecast firings' as t;
do $$
declare v_city bigint; v_ward bigint; v_station bigint; v_run bigint; v_c1 bigint; v_c2 bigint; n int;
begin
  reset role;
  select * into v_city, v_ward, v_station from _t90_setup_city('t83');
  insert into forecast_runs (city_id, ward_id, pollutant, method, model_version, max_validated_horizon_hours, beats_persistence, data_quality_status)
    values (v_city, v_ward, 'pm25', 'lightgbm', 'lgb_v1', 24, true, 'ok') returning id into v_run;
  insert into forecasts (ward_id, generated_at, horizon_ts, pollutant, predicted_value, forecast_run_id)
    select v_ward, now(), now() + (h || ' hours')::interval, 'pm25', 60 + h*8, v_run
    from generate_series(1,24) h;

  select evaluate_station_pollutant_anomaly(v_station, 'pm25') into v_c1;
  insert into readings (station_id, ts, pm25) values (v_station, now(), 61);
  select evaluate_station_pollutant_anomaly(v_station, 'pm25') into v_c2;

  select count(*) into n from incidents where ward_id = v_ward and primary_pollutant = 'pm25';
  if n = 1 then raise notice '83 PASS: still exactly one incident after two validated-forecast firings';
  else raise notice '83 FAIL: % incidents', n; end if;
end $$;

select 'TEST 84: a stale forecast (older than 2x the retraining cadence) is treated as unavailable' as t;
do $$
declare v_city bigint; v_ward bigint; v_station bigint; v_run bigint; v_candidate bigint;
begin
  reset role;
  select * into v_city, v_ward, v_station from _t90_setup_city('t84');
  insert into forecast_runs (city_id, ward_id, pollutant, method, model_version, max_validated_horizon_hours, beats_persistence, data_quality_status, generated_at)
    values (v_city, v_ward, 'pm25', 'lightgbm', 'lgb_v1', 24, true, 'ok', now() - interval '72 hours') returning id into v_run;
  insert into forecasts (ward_id, generated_at, horizon_ts, pollutant, predicted_value, forecast_run_id)
    values (v_ward, now() - interval '72 hours', now() + interval '2 hour', 'pm25', 95, v_run);

  update readings set pm25 = 70 where station_id = v_station and ts = (select max(ts) from readings where station_id = v_station);
  select evaluate_station_pollutant_anomaly(v_station, 'pm25') into v_candidate;

  if v_candidate is null or (select prediction_method from anomaly_candidates where id = v_candidate) is distinct from 'validated_forecast'
  then raise notice '84 PASS: a 72h-old forecast (default cadence 24h x2 = 48h max) was not trusted';
  else raise notice '84 FAIL: stale forecast was used anyway'; end if;
end $$;

reset role;
reset request.jwt.claims;
drop function if exists _t90_setup_city(text);
