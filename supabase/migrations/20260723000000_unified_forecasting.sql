-- ============================================================
-- unified_forecasting — additive migration (Phase 8, vertical slice)
--
-- One trusted forecasting pipeline, connected to anomaly detection:
--
--   * `forecast_runs` (new table) — the validation record for ONE ward +
--     pollutant + generation: which method actually produced it
--     (lightgbm vs. diurnal_persistence), the training period, per-horizon
--     validation metrics (MAE/RMSE/bias/threshold recall/false-alarm rate),
--     data completeness, and whether it beat the persistence baseline —
--     "a model must not be marked production-ready unless it beats
--     persistence" is a stored fact (`beats_persistence`), not a claim.
--   * `forecasts` gains additive columns: `pollutant` (defaults to 'pm25' —
--     every existing row already IS a pm25 forecast, so this backfills
--     correctly with zero ambiguity), `predicted_value`/`lower_bound`/
--     `upper_bound` (generic — works for any pollutant), `forecast_run_id`
--     (links a curve point back to its validation record). The legacy
--     `pm25_pred` column is UNTOUCHED and still populated for pm25 rows —
--     `fetchForecast`/`fetchAllForecasts`/`ForecastChart` keep working
--     exactly as before, byte-for-byte.
--   * `anomaly_candidates` gains `prediction_method` — "clearly record
--     which method created the prediction... never silently mix forecast
--     methods" (plan §6) is a queryable column, not just a code path.
--   * `evaluate_station_pollutant_anomaly` (Phase 6, `create or replace`d a
--     second time): the 'predicted' branch now checks for a validated,
--     fresh `forecast_runs` row FIRST. If one exists and its own forecast
--     curve crosses the configured threshold within the validated horizon,
--     THAT is the predicted-incident signal (`prediction_method =
--     'validated_forecast'`) — the raw-reading trend projection is not
--     consulted at all in that case, so the two methods can never disagree
--     silently. Only when no validated forecast exists does the ORIGINAL
--     Phase 6 trend-projection logic run, now explicitly labelled
--     `prediction_method = 'trend_persistence'`. Neither path is new
--     enforcement risk: 'detected' stage (already crossing, sensor-driven)
--     is completely unchanged by this migration, and the pre-existing
--     evidence-level gate (suspected → refused) still applies to whatever
--     incident results either way.
--
-- No existing table, column, row, or policy is altered or dropped. No
-- existing forecast-reading code path (`web/src/lib/data.ts`'s
-- `fetchForecast`/`fetchAllForecasts`, `ForecastChart.tsx`) changes
-- behaviour — they are updated in this pass ONLY to keep filtering to
-- `pollutant = 'pm25'` explicitly, now that the same table can also hold
-- pm10/no2 rows (see web/src/lib/data.ts).
--
-- Idempotent: safe to re-run and safe via `supabase db push`.
-- See docs/DATA_MODEL.md and docs/DATA_QUALITY_AND_SCIENCE.md.
-- ============================================================

-- ---------- forecast_runs: the validation record for one generation ----------
create table if not exists forecast_runs (
  id                            bigserial primary key,
  city_id                       int references city_config(id),
  ward_id                       int not null references wards(id) on delete cascade,
  pollutant                     text not null check (pollutant in ('pm25', 'pm10', 'no2', 'so2', 'co', 'o3')),
  -- Which method ACTUALLY produced this run's predictions — set after the
  -- model-vs-persistence comparison, never claimed in advance.
  method                        text not null check (method in ('lightgbm', 'diurnal_persistence')),
  model_version                 text not null,
  generated_at                  timestamptz not null default now(),
  training_period_start         timestamptz,
  training_period_end           timestamptz,
  training_rows                 int,
  data_completeness             double precision check (data_completeness is null or (data_completeness between 0 and 1)),
  data_quality_status           text not null default 'ok' check (data_quality_status in ('ok', 'insufficient_data', 'stale_inputs')),
  -- Per-horizon breakdown: {"6": {"mae":.., "rmse":.., "bias":.., "threshold_recall":.., "false_alarm_rate":.., "beats_persistence": true}, "12": {...}, "24": {...}, "48": {...}}
  validation_metrics            jsonb not null default '{}'::jsonb,
  -- The largest horizon where the model beat persistence at every horizon
  -- up to and including it (monotonic and conservative on purpose — plan's
  -- own "48h only if validation is acceptable").
  max_validated_horizon_hours   int,
  beats_persistence             boolean not null default false,
  created_at                    timestamptz not null default now()
);
create index if not exists forecast_runs_ward_pollutant_idx on forecast_runs (ward_id, pollutant, generated_at desc);

alter table forecast_runs enable row level security;
-- Same posture as forecasts_read (schema.sql): any authenticated user — this
-- is transparency data (model accuracy), not internal detection detail, and
-- showing it broadly is the actual mechanism behind "never present a
-- forecast as a guaranteed outcome" (plan §8) rather than hiding the doubt.
drop policy if exists forecast_runs_read on forecast_runs;
create policy forecast_runs_read on forecast_runs for select using (auth.role() = 'authenticated');
-- No write policy, deliberately — exactly like forecasts/readings/weather:
-- only the ingest service (service_role, bypasses RLS) ever writes here.

-- ---------- forecasts: additive columns for multi-pollutant + uncertainty ----------
alter table forecasts add column if not exists pollutant text not null default 'pm25'
  check (pollutant in ('pm25', 'pm10', 'no2', 'so2', 'co', 'o3'));
alter table forecasts add column if not exists predicted_value double precision;
alter table forecasts add column if not exists lower_bound double precision;
alter table forecasts add column if not exists upper_bound double precision;
alter table forecasts add column if not exists forecast_run_id bigint references forecast_runs(id) on delete set null;
create index if not exists forecasts_pollutant_idx on forecasts (ward_id, pollutant, horizon_ts);

-- ---------- anomaly_candidates: which prediction method fired ----------
alter table anomaly_candidates add column if not exists prediction_method text
  check (prediction_method is null or prediction_method in ('validated_forecast', 'trend_persistence'));

-- ============================================================
-- evaluate_station_pollutant_anomaly — Phase 6 function, extended (create or
-- replace, 2nd definition). Everything EXCEPT the 'predicted'-stage branch
-- is byte-for-byte unchanged from Phase 6; reproduced here in full because
-- Postgres has no way to patch one branch of an existing function body.
-- ============================================================
create or replace function evaluate_station_pollutant_anomaly(
  p_station_id bigint,
  p_pollutant  text
) returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_caller_role                user_role;
  v_station                    stations%rowtype;
  v_ward                       wards%rowtype;
  v_city_id                    int;
  v_config                     jsonb;

  -- city-configurable parameters, with documented fallbacks
  v_threshold                  double precision;
  v_persistence_window         int;
  v_persistence_min_count      int;
  v_local_excess_min           double precision;
  v_nearby_radius_m            double precision;
  v_completeness_min           double precision;
  v_freshness_max_minutes      double precision;
  v_horizon_hours               double precision;
  v_dedup_window_hours          double precision;
  v_implausible_max             double precision;

  -- readings window (most recent first)
  v_latest_ts                   timestamptz;
  v_current                     double precision;
  v_valid_count                 int;
  v_persistence_count           int;
  v_earliest_ts                 timestamptz;
  v_earliest_value              double precision;
  v_rate_of_increase            double precision;

  v_city_baseline                double precision;
  v_baseline_value                double precision;
  v_local_excess                  double precision;
  v_nearby_diff                  double precision;

  v_freshness_minutes            double precision;
  v_completeness                 double precision;

  v_suppressed                   boolean := false;
  v_suppression_reason           text;

  v_stage                        incident_detection_stage;
  v_crossing_prob                double precision;
  v_projected_crossing_at        timestamptz;
  v_triggered                    jsonb := '[]'::jsonb;
  v_confidence                   double precision;
  v_quality_multiplier           double precision;
  v_prediction_method             text;

  -- Phase 8: validated-forecast lookup for the predicted branch
  v_forecast_run                 forecast_runs%rowtype;
  v_forecast_horizon_ts           timestamptz;
  v_forecast_predicted_value      double precision;
  v_forecast_lower_bound          double precision;
  v_forecast_upper_bound          double precision;
  v_forecast_hours_to_cross       double precision;

  v_candidate_id                  bigint;
  v_incident_id                   bigint;
begin
  if p_pollutant not in ('pm25', 'pm10', 'no2', 'so2', 'co', 'o3') then
    raise exception 'Unsupported pollutant "%"', p_pollutant;
  end if;

  -- ---- authorisation ----
  if auth.uid() is not null then
    select role into v_caller_role from profiles where id = auth.uid();
    if coalesce(v_caller_role, 'citizen') not in ('commander', 'admin') then
      raise exception 'Only a commander or admin may run anomaly detection.'
        using errcode = 'insufficient_privilege';
    end if;
  end if;
  -- auth.uid() is null for the ingest service's service_role connection,
  -- which already bypasses RLS entirely — this function's own guard is not
  -- what protects that path; the service key itself is.

  select * into v_station from stations where id = p_station_id;
  if not found then
    raise exception 'Station % not found', p_station_id;
  end if;
  if v_station.ward_id is not null then
    select * into v_ward from wards where id = v_station.ward_id;
    v_city_id := v_ward.city_id;
  end if;

  select coalesce(config, '{}'::jsonb) into v_config from city_config where id = v_city_id;
  v_config := coalesce(v_config -> 'anomaly_detection', '{}'::jsonb);

  v_threshold := coalesce(
    (v_config -> 'pollutant_thresholds' ->> p_pollutant)::double precision,
    -- documented fallbacks — CPCB "Poor" AQI-category entry points; pm25/pm10
    -- match this repo's OWN aqi.py breakpoint table directly (not re-guessed).
    -- so2/co/o3 are rougher approximations — flagged in
    -- docs/DATA_QUALITY_AND_SCIENCE.md as needing a domain-expert review.
    case p_pollutant
      when 'pm25' then 90
      when 'pm10' then 250
      when 'no2'  then 180
      when 'so2'  then 380
      when 'co'   then 4000
      when 'o3'   then 180
    end
  );
  v_persistence_window    := coalesce((v_config ->> 'persistence_window_readings')::int, 3);
  v_persistence_min_count := coalesce((v_config ->> 'persistence_min_count')::int, 2);
  v_local_excess_min      := coalesce((v_config ->> 'local_excess_min')::double precision, 20);
  v_nearby_radius_m       := coalesce((v_config ->> 'nearby_station_radius_m')::double precision, 5000);
  v_completeness_min      := coalesce((v_config ->> 'data_completeness_min')::double precision, 0.5);
  v_freshness_max_minutes := coalesce((v_config ->> 'data_freshness_max_minutes')::double precision, 180);
  v_horizon_hours         := coalesce((v_config ->> 'prediction_horizon_hours')::double precision, 6);
  v_dedup_window_hours     := coalesce((v_config ->> 'dedup_window_hours')::double precision, 12);

  -- Sanity ceiling per pollutant: catches sensor faults / unit errors, not a
  -- health threshold. Generous on purpose — this only rejects impossible
  -- values, never plausible-but-extreme ones.
  v_implausible_max := case p_pollutant
    when 'pm25' then 1000 when 'pm10' then 1500 when 'no2' then 2000
    when 'so2' then 2000 when 'co' then 50000 when 'o3' then 1000
  end;

  -- ---- pull the recent readings window for this station+pollutant ----
  with raw as (
    select ts,
      case p_pollutant
        when 'pm25' then pm25 when 'pm10' then pm10 when 'no2' then no2
        when 'so2' then so2 when 'co' then co when 'o3' then o3
      end as val
    from readings
    where station_id = p_station_id
    order by ts desc
    limit greatest(v_persistence_window * 4, 12)
  ),
  valid as (
    select ts, val from raw
    where val is not null and val >= 0 and val <= v_implausible_max
    order by ts desc
    limit v_persistence_window
  )
  select
    (select max(ts) from raw),
    (select val from valid order by ts desc limit 1),
    (select count(*) from valid),
    (select count(*) from valid where val >= v_threshold),
    (select min(ts) from valid),
    (select val from valid order by ts asc limit 1)
  into v_latest_ts, v_current, v_valid_count, v_persistence_count, v_earliest_ts, v_earliest_value;

  if v_latest_ts is null then
    return null;
  end if;

  v_freshness_minutes := extract(epoch from (now() - v_latest_ts)) / 60.0;
  v_completeness := v_valid_count::double precision / v_persistence_window;

  if v_earliest_ts is not null and v_earliest_ts < v_latest_ts and v_current is not null and v_earliest_value is not null then
    v_rate_of_increase := (v_current - v_earliest_value)
      / greatest(extract(epoch from (v_latest_ts - v_earliest_ts)) / 3600.0, 0.1);
  end if;

  -- ---- Phase 8: look up a validated, fresh forecast for this ward+pollutant
  -- BEFORE the leading gate — a validated forecast crossing the threshold is
  -- itself a legitimate leading signal, even when the CURRENT reading is
  -- comfortably below it (that is the entire point of forecasting ahead). ----
  select fr.* into v_forecast_run
  from forecast_runs fr
  where fr.ward_id = v_station.ward_id and fr.pollutant = p_pollutant
    and fr.beats_persistence
    and fr.data_quality_status = 'ok'
    and fr.max_validated_horizon_hours is not null
    -- "fall back... only when the model is unavailable": a forecast older
    -- than twice the configured retraining cadence is treated as
    -- unavailable, not silently trusted forever.
    and fr.generated_at >= now() - make_interval(
          hours => coalesce((v_config -> 'forecasting' ->> 'retraining_frequency_hours')::int, 24) * 2
        )
  order by fr.generated_at desc
  limit 1;

  if v_forecast_run.id is not null then
    select f.horizon_ts, f.predicted_value, f.lower_bound, f.upper_bound
    into v_forecast_horizon_ts, v_forecast_predicted_value, v_forecast_lower_bound, v_forecast_upper_bound
    from forecasts f
    where f.forecast_run_id = v_forecast_run.id
      and f.horizon_ts > now()
      and f.horizon_ts <= v_forecast_run.generated_at + make_interval(hours => v_forecast_run.max_validated_horizon_hours)
      and f.predicted_value >= v_threshold
    order by f.horizon_ts asc
    limit 1;
  end if;

  -- ---- leading gate: is there anything here worth evaluating at all? ----
  -- Either already over threshold (sensor), a validated forecast crossing
  -- ahead, or (only when no validated forecast exists at all) a raw-reading
  -- trend projected to cross within the horizon.
  if v_current is null or (
    v_current < v_threshold
    and v_forecast_horizon_ts is null
    and not (
      v_forecast_run.id is null  -- trend fallback only applies when no validated forecast exists
      and v_rate_of_increase is not null and v_rate_of_increase > 0
      and (v_threshold - v_current) / v_rate_of_increase <= v_horizon_hours
    )
  ) then
    return null;
  end if;

  -- ---- local excess: vs. the city's OTHER stations' current average ----
  select avg(val) into v_city_baseline
  from (
    select distinct on (s.id)
      case p_pollutant
        when 'pm25' then r.pm25 when 'pm10' then r.pm10 when 'no2' then r.no2
        when 'so2' then r.so2 when 'co' then r.co when 'o3' then r.o3
      end as val
    from stations s
    join wards w on w.id = s.ward_id
    join readings r on r.station_id = s.id
    where s.id <> p_station_id
      and (v_city_id is null or w.city_id = v_city_id)
      and r.ts >= now() - make_interval(mins => v_freshness_max_minutes::int)
    order by s.id, r.ts desc
  ) other_latest
  where val is not null;

  if v_city_baseline is not null then
    v_baseline_value := v_city_baseline;
    v_local_excess := v_current - v_city_baseline;
  end if;

  -- ---- nearby-station diff: same idea, radius-limited (haversine, same
  -- equirectangular approximation link_report_to_incident already uses) ----
  if v_station.lat is not null and v_station.lng is not null then
    select avg(val) into v_nearby_diff
    from (
      select distinct on (s.id)
        case p_pollutant
          when 'pm25' then r.pm25 when 'pm10' then r.pm10 when 'no2' then r.no2
          when 'so2' then r.so2 when 'co' then r.co when 'o3' then r.o3
        end as val
      from stations s
      join readings r on r.station_id = s.id
      where s.id <> p_station_id
        and s.lat is not null and s.lng is not null
        and r.ts >= now() - make_interval(mins => v_freshness_max_minutes::int)
        and 6371000 * sqrt(
              pow(radians(s.lat - v_station.lat), 2) +
              pow(radians(s.lng - v_station.lng) * cos(radians((s.lat + v_station.lat) / 2)), 2)
            ) <= v_nearby_radius_m
      order by s.id, r.ts desc
    ) nearby
    where val is not null;

    if v_nearby_diff is not null then
      v_nearby_diff := v_current - v_nearby_diff;
    end if;
  end if;

  -- ---- data-quality gate (readings) ----
  if v_freshness_minutes > v_freshness_max_minutes then
    v_suppressed := true;
    v_suppression_reason := format(
      'Latest reading is %s minutes old (max allowed %s) — station may be offline.',
      round(v_freshness_minutes), v_freshness_max_minutes
    );
  elsif v_completeness < v_completeness_min then
    v_suppressed := true;
    v_suppression_reason := format(
      'Only %s of %s expected readings were valid (%s%% complete, minimum %s%%).',
      v_valid_count, v_persistence_window,
      round((v_completeness * 100)::numeric, 0), round((v_completeness_min * 100)::numeric, 0)
    );
  end if;

  -- ---- rule evaluation (only meaningful when NOT suppressed) ----
  if not v_suppressed then
    if v_current >= v_threshold then
      v_triggered := v_triggered || '"concentration_threshold"'::jsonb;
    end if;
    if v_persistence_count >= v_persistence_min_count then
      v_triggered := v_triggered || '"persistence"'::jsonb;
    end if;
    if v_local_excess is not null and v_local_excess >= v_local_excess_min then
      v_triggered := v_triggered || '"local_excess"'::jsonb;
    end if;

    if v_current >= v_threshold and v_persistence_count >= v_persistence_min_count
       and v_local_excess is not null and v_local_excess >= v_local_excess_min then
      -- 'detected': sensor-driven, unchanged by Phase 8 — the forecast is
      -- never consulted once the pollutant has genuinely already crossed.
      v_stage := 'detected';
      v_crossing_prob := 1.0;

    elsif v_current < v_threshold and v_forecast_horizon_ts is not null
       and v_local_excess is not null and v_local_excess >= v_local_excess_min then
      -- Phase 8: validated forecast crosses the threshold ahead. The raw-
      -- reading trend is NOT consulted here — exactly one method decides.
      v_triggered := v_triggered || '"validated_forecast_crossing"'::jsonb;
      v_stage := 'predicted';
      v_prediction_method := 'validated_forecast';
      v_projected_crossing_at := v_forecast_horizon_ts;
      v_forecast_hours_to_cross := greatest(extract(epoch from (v_forecast_horizon_ts - now())) / 3600.0, 0);
      -- Uncertainty-aware confidence: if even the model's conservative lower
      -- bound already crosses, the projection is as sure as this system
      -- ever states anything; otherwise it decays with how far out the
      -- point-estimate crossing sits within the validated horizon.
      v_crossing_prob := case
        when v_forecast_lower_bound is not null and v_forecast_lower_bound >= v_threshold then 1.0
        else greatest(0, least(1, 1 - v_forecast_hours_to_cross / greatest(v_forecast_run.max_validated_horizon_hours, 1)))
      end;

    elsif v_current < v_threshold and v_forecast_run.id is null
       and v_rate_of_increase is not null and v_rate_of_increase > 0
       and v_local_excess is not null and v_local_excess >= v_local_excess_min then
      -- Phase 6 original trend projection — the FALLBACK, only reached when
      -- no validated forecast exists for this ward+pollutant at all.
      declare v_hours_to_cross double precision := (v_threshold - v_current) / v_rate_of_increase;
      begin
        if v_hours_to_cross <= v_horizon_hours then
          v_triggered := v_triggered || '"trend_projection"'::jsonb;
          v_stage := 'predicted';
          v_prediction_method := 'trend_persistence';
          v_crossing_prob := greatest(0, least(1, 1 - v_hours_to_cross / v_horizon_hours));
          v_projected_crossing_at := now() + make_interval(hours => v_hours_to_cross::int, mins => ((v_hours_to_cross - floor(v_hours_to_cross)) * 60)::int);
        end if;
      end;
    end if;
  end if;

  -- ---- confidence: a stated, documented weighted score, never an ML output
  -- itself — even when a validated ML forecast fed v_crossing_prob above,
  -- THIS combination is still a transparent formula, not a model output. ----
  v_quality_multiplier := case v_station.sensor_type
    when 'regulatory' then 1.0
    when 'indicative' then 0.7
    when 'low_cost' then 0.6
    else 0.5
  end;
  v_confidence := least(1.0, greatest(0.0,
    (
      0.3 * (case when v_current >= v_threshold then 1 else 0 end)
      + 0.3 * (least(v_persistence_count, v_persistence_min_count)::double precision / greatest(v_persistence_min_count, 1))
      + 0.2 * (case when v_local_excess is not null and v_local_excess >= v_local_excess_min then 1 else 0 end)
      + 0.2 * coalesce(v_crossing_prob, 0)
    ) * v_quality_multiplier
  ));

  -- ---- store the candidate ----
  insert into anomaly_candidates (
    city_id, ward_id, station_id, pollutant, detection_stage,
    current_concentration, baseline_value, local_excess, rate_of_increase,
    persistence_count, nearby_station_diff, threshold_crossing_probability,
    projected_crossing_at, data_freshness_minutes, data_completeness,
    sensor_quality, threshold_used, triggered_rules, confidence,
    suppressed, suppression_reason, prediction_method
  ) values (
    v_city_id, v_station.ward_id, p_station_id, p_pollutant, v_stage,
    v_current, v_baseline_value, v_local_excess, v_rate_of_increase,
    v_persistence_count, v_nearby_diff, v_crossing_prob,
    v_projected_crossing_at, v_freshness_minutes, v_completeness,
    v_station.sensor_type, v_threshold, v_triggered, v_confidence,
    v_suppressed, v_suppression_reason, v_prediction_method
  ) returning id into v_candidate_id;

  if v_suppressed then
    return v_candidate_id;
  end if;

  if v_stage is null then
    return v_candidate_id;
  end if;

  -- ---- deduplication + create-or-update (plan §6/§7, unchanged from
  -- Phase 6 apart from the method-aware note text below) ----
  if v_station.ward_id is not null then
    perform pg_advisory_xact_lock(hashtext('incident_ward_' || v_station.ward_id));

    select i.id into v_incident_id
    from incidents i
    where i.status <> 'closed'
      and i.ward_id = v_station.ward_id
      and (i.primary_pollutant is null or i.primary_pollutant = p_pollutant)
      and i.updated_at >= now() - make_interval(hours => v_dedup_window_hours::int)
    order by i.updated_at desc
    limit 1;

    if v_incident_id is not null then
      if (select detection_stage from incidents where id = v_incident_id) is not null then
        update incidents set
          detection_stage = case
            when (select detection_stage from incidents where id = v_incident_id) = 'confirmed' then 'confirmed'
            when v_stage = 'detected' then 'detected'
            else (select detection_stage from incidents where id = v_incident_id)
          end,
          local_excess = coalesce(v_local_excess, local_excess),
          updated_at = now()
        where id = v_incident_id;

        insert into incident_events (incident_id, event_type, actor_id, note, is_public, payload)
        values (
          v_incident_id, 'predicted_incident_updated', null,
          format('New %s reading corroborates this incident (%s, stage %s, method %s).',
                 p_pollutant, round(v_current::numeric, 1), v_stage, coalesce(v_prediction_method, 'sensor')),
          false,
          jsonb_build_object('anomaly_candidate_id', v_candidate_id, 'pollutant', p_pollutant, 'detection_stage', v_stage, 'prediction_method', v_prediction_method)
        );
      else
        insert into incident_evidence (incident_id, evidence_type, reading_id, supports, confidence, payload, collected_at)
        values (
          v_incident_id, 'sensor', null, true, v_confidence,
          jsonb_build_object('anomaly_candidate_id', v_candidate_id, 'pollutant', p_pollutant, 'concentration', v_current),
          now()
        );
        insert into incident_events (incident_id, event_type, actor_id, note, is_public, payload)
        values (
          v_incident_id, 'evidence_added', null,
          format('Monitoring data corroborates this incident: %s at %s.', p_pollutant, round(v_current::numeric, 1)),
          true,
          jsonb_build_object('anomaly_candidate_id', v_candidate_id, 'pollutant', p_pollutant)
        );
      end if;
    else
      insert into incidents (
        city_id, ward_id, status, detection_method, detection_stage,
        source_confidence, primary_pollutant, lat, lng, local_excess, summary
      ) values (
        v_city_id, v_station.ward_id, 'detected',
        case
          when v_stage = 'detected' then 'anomaly_persistence_threshold'
          when v_prediction_method = 'validated_forecast' then 'anomaly_validated_forecast'
          else 'anomaly_trend_projection'
        end,
        v_stage, 'suspected', p_pollutant, v_station.lat, v_station.lng, v_local_excess,
        format('Automatically %s: %s reading of %s at %s (threshold %s)%s.',
               case v_stage when 'detected' then 'detected' else 'predicted' end,
               upper(p_pollutant), round(v_current::numeric, 1), v_station.name, round(v_threshold::numeric, 1),
               case when v_prediction_method = 'validated_forecast' then ', via the validated forecast' else '' end)
      )
      returning id into v_incident_id;

      insert into incident_events (incident_id, event_type, actor_id, note, is_public, payload)
      values (
        v_incident_id,
        'predicted_incident_created',
        null,
        format('Automatically %s from monitoring data.', case v_stage when 'detected' then 'detected' else 'predicted' end),
        true,
        -- deliberately omits station_id/anomaly_candidate_id from the PUBLIC
        -- payload — see Phase 6's own note on this. prediction_method is as
        -- benign as detection_stage, already public since Phase 6.
        jsonb_build_object('pollutant', p_pollutant, 'detection_stage', v_stage, 'prediction_method', v_prediction_method)
      );
    end if;

    update anomaly_candidates set incident_id = v_incident_id where id = v_candidate_id;
  end if;

  return v_candidate_id;
end $$;

revoke all on function evaluate_station_pollutant_anomaly(bigint, text) from public;
grant execute on function evaluate_station_pollutant_anomaly(bigint, text) to authenticated;

-- ============================================================
-- Seed: Delhi's forecasting configuration (plan's "seed Delhi configuration
-- only"). Merged into the existing config jsonb, safe to re-run — same
-- guarded pattern Phase 6/7 already established.
-- ============================================================
update city_config
set config = config || jsonb_build_object(
  'forecasting', jsonb_build_object(
    'enabled_pollutants', jsonb_build_array('pm25', 'pm10', 'no2'),
    'horizons_hours', jsonb_build_array(6, 12, 24, 48),
    -- "beats persistence" requires at least this much MAE improvement,
    -- guarding against a model that wins by a statistically meaningless
    -- margin being called production-ready.
    'min_mae_improvement_pct', 5,
    'confidence_threshold', 0.5,
    'fallback_method', 'trend_persistence',
    'retraining_frequency_hours', 24
  )
)
where city_code = 'delhi'
  and not (config ? 'forecasting');
