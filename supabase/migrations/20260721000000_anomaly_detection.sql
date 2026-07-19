-- ============================================================
-- anomaly_detection — additive migration (Phase 6, vertical slice)
--
-- Automated, rule-based (no ML) pollution anomaly detection from monitoring
-- data, and predicted/detected incident creation from it. Nothing here is
-- destructive:
--
--   * one new enum (incident_detection_stage), two new nullable columns on
--     incidents (detection_stage, merged_into_incident_id), one new column
--     on stations (sensor_type, NOT NULL with a default that matches every
--     currently-seeded station's real type — DPCC/CPCB government monitors
--     ARE regulatory-grade, so this is not a guessed value)
--   * one new table, anomaly_candidates — the rule engine's structured
--     output (plan's "store: triggered rules, input values, baseline
--     values, confidence, detection timestamp, data-quality summary")
--   * two new security-definer functions that do the actual work
--
-- Architecture, and why it lives here rather than in ingest/ Python:
-- every OTHER business rule in this codebase (evidence-level gates,
-- report/recurrence matching, impact-outcome computation) lives in a single
-- SQL function so it is (a) atomic — the plan's own requirement 6 says
-- "use a server-side atomic function... do not use browser read-then-write
-- logic" — and (b) testable via the same disposable-Postgres harness every
-- other rule already uses. The anomaly rules need a time-series WINDOW over
-- `readings` (rate of increase, persistence, local excess, nearby-station
-- diff) — a natural fit for SQL window/aggregate queries, and one this
-- migration's own tests exercise with seeded, fixed sample readings exactly
-- like every prior phase's tests do. `ingest/app/anomaly_detection.py` is
-- the thin Python wiring that calls `run_anomaly_detection()` on the
-- existing APScheduler cron, after ingest+intel — it contains no rule
-- logic of its own, mirroring how classify.py calls out to Claude rather
-- than reimplementing anything.
--
-- Never fires from one isolated reading (plan's own explicit requirement):
-- `evaluate_station_pollutant_anomaly` requires PERSISTENCE (>= 2 valid
-- readings meeting the threshold, city-configurable) before a candidate can
-- reach `detection_stage = 'detected'` and create/update an incident. A
-- single high reading produces, at most, a stored (non-suppressed,
-- non-incident-linked) candidate row with `triggered_rules` showing
-- exactly which criteria did and did not fire — verified directly by test
-- 41 below.
--
-- City-configurable (plan's own explicit requirement): every threshold,
-- window, radius and horizon is read from `city_config.config ->
-- 'anomaly_detection'`, with documented SQL-level fallbacks used only when
-- a city has not configured a value. No Delhi-specific station id or
-- number is hardcoded in this file's FUNCTIONS — only in the SEED DATA at
-- the bottom, which is explicitly Delhi's own configuration, not a code
-- path. See docs/DATA_QUALITY_AND_SCIENCE.md for the scientific basis (and
-- honest limitations) of the seeded default thresholds.
--
-- Idempotent: safe to re-run and safe via `supabase db push`.
-- See docs/DATA_MODEL.md and docs/ROLE_WORKFLOWS.md.
-- ============================================================

-- ---------- enum ----------
do $$ begin
  create type incident_detection_stage as enum ('predicted', 'detected', 'confirmed');
exception when duplicate_object then null;
end $$;

-- ---------- stations: sensor classification (plan's data-quality requirement) ----------
-- Defaults to 'regulatory' because every currently-seeded Delhi station IS a
-- DPCC/CPCB government monitor (see ingest/stations.yaml) — not a guess, the
-- real current fact. A future low-cost sensor network would insert its
-- stations with sensor_type = 'indicative' or 'low_cost' explicitly.
alter table stations add column if not exists sensor_type text not null default 'regulatory'
  check (sensor_type in ('regulatory', 'indicative', 'low_cost', 'unknown'));

-- ---------- incidents: detection-maturity label + merge traceability ----------
-- `detection_stage` is deliberately ORTHOGONAL to `status` (workflow position)
-- and `source_confidence` (evidence about the SOURCE) — it answers a third,
-- separate question: "how mature is the detection itself?" Null for every
-- incident that did NOT originate from automated detection (citizen report,
-- manual command entry) — this column only ever means something for a
-- sensor-detected incident, exactly like `classification` is null until
-- evidence allows it to be set.
alter table incidents add column if not exists detection_stage incident_detection_stage;
-- Command's "merge with an existing incident" action (plan §7) — mirrors
-- Phase 5.1's recurrence_of_incident_id/resulting_incident_id pairing: this
-- predicted incident points to the real incident it was folded into.
alter table incidents add column if not exists merged_into_incident_id bigint references incidents(id);
create index if not exists incidents_detection_stage_idx on incidents (detection_stage) where detection_stage is not null;
create index if not exists incidents_merged_into_idx on incidents (merged_into_incident_id) where merged_into_incident_id is not null;

-- ---------- anomaly_candidates: the rule engine's structured output ----------
create table if not exists anomaly_candidates (
  id                              bigserial primary key,
  city_id                         int references city_config(id),
  ward_id                         int references wards(id) on delete set null,
  station_id                      int references stations(id) on delete set null,
  pollutant                       text not null check (pollutant in ('pm25', 'pm10', 'no2', 'so2', 'co', 'o3')),
  incident_id                     bigint references incidents(id) on delete set null,
  -- null = evaluated, did not qualify as either predicted or detected (e.g. the
  -- suppressed-by-data-quality case, or a leading signal fired but persistence
  -- did not — see test 41, "one isolated high reading does not create an incident").
  detection_stage                 incident_detection_stage,
  current_concentration           double precision,
  baseline_value                  double precision,
  local_excess                    double precision,
  rate_of_increase                double precision,        -- concentration units per hour
  persistence_count                int,
  nearby_station_diff             double precision,        -- null when no other station is within radius — never fabricated
  threshold_crossing_probability  double precision check (threshold_crossing_probability is null or (threshold_crossing_probability between 0 and 1)),
  projected_crossing_at           timestamptz,              -- null once already crossed (detected) or not trending toward it
  data_freshness_minutes          double precision,
  data_completeness               double precision check (data_completeness is null or (data_completeness between 0 and 1)),
  sensor_quality                  text,                     -- snapshot of stations.sensor_type at detection time
  threshold_used                  double precision,
  triggered_rules                 jsonb not null default '[]'::jsonb,
  confidence                      double precision check (confidence is null or (confidence between 0 and 1)),
  suppressed                      boolean not null default false,
  suppression_reason               text,
  detected_at                     timestamptz not null default now(),
  created_at                      timestamptz not null default now()
);
create index if not exists anomaly_candidates_ward_pollutant_idx on anomaly_candidates (ward_id, pollutant, detected_at desc);
create index if not exists anomaly_candidates_incident_idx on anomaly_candidates (incident_id);
create index if not exists anomaly_candidates_station_idx on anomaly_candidates (station_id, pollutant, detected_at desc);

alter table anomaly_candidates enable row level security;

-- Read: commander/admin (all), field_officer (own ward). Citizens have NO
-- direct read at all — "internal detection details" (plan §8/§11): raw
-- sensor signals, thresholds and confidence scores are not citizen-facing,
-- mirroring evidence_missions/intervention_playbooks/actions.
drop policy if exists anomaly_candidates_read on anomaly_candidates;
create policy anomaly_candidates_read on anomaly_candidates for select using (
  auth_role() in ('commander', 'admin')
  or (auth_role() = 'field_officer' and ward_id = auth_ward())
);
-- Write: commander/admin only, for manual correction/inspection. The actual
-- detection writes go through evaluate_station_pollutant_anomaly, which is
-- SECURITY DEFINER and so is unaffected by this policy either way.
drop policy if exists anomaly_candidates_write on anomaly_candidates;
create policy anomaly_candidates_write on anomaly_candidates for all using (
  auth_role() in ('commander', 'admin')
) with check (
  auth_role() in ('commander', 'admin')
);

-- ============================================================
-- evaluate_station_pollutant_anomaly — the rule engine, for ONE station and
-- ONE pollutant. Returns the anomaly_candidates.id it wrote, or null when
-- nothing was worth recording at all (no leading signal fired).
--
-- Signals computed (plan §2), all from `readings` for this station:
--   current_concentration, rate_of_increase, persistence (>= 2 valid
--   readings at/above threshold), local_excess (vs. the city's OTHER
--   stations' current average for the same pollutant), nearby_station_diff
--   (vs. stations within the configured radius specifically), threshold-
--   crossing probability (1.0 once persisted; a stated linear projection
--   when only trending), data freshness, data completeness, sensor quality.
--
-- Data-quality gate (plan §3), applied BEFORE any incident is touched:
--   invalid readings (negative or implausible) are excluded from every
--   signal; stale data (latest reading older than the configured max) and
--   incomplete data (fewer valid readings than the configured minimum
--   fraction of the window) SUPPRESS the candidate — it is stored (so the
--   suppression itself is auditable) but `suppressed = true` and
--   `incident_id` stays null, no matter how extreme the raw value looked.
--
-- Rule (plan §4, its own literal example): a candidate reaches
-- `detection_stage = 'detected'` only when concentration exceeds the
-- threshold AND persistence >= the configured minimum count AND local
-- excess is meaningful AND data quality passed. A candidate reaches
-- `detection_stage = 'predicted'` when it is not yet crossing but a simple,
-- stated linear trend projects a crossing within the configured horizon.
-- Anything short of that (e.g. one high reading with no persistence yet)
-- is stored with detection_stage left null and NO incident is created —
-- this is the literal mechanism behind "never create an incident from one
-- isolated reading alone."
--
-- security definer: this is a system operation (the ingest service, or a
-- commander manually triggering detection), never a citizen or field
-- officer action — a plain RLS policy would either have to allow it far
-- too broadly or not at all. The internal check below is the actual guard:
-- an authenticated caller must be commander/admin; an unauthenticated
-- (service_role) caller — which already bypasses RLS entirely — is allowed
-- through, since that IS the intended production caller (the ingest cron).
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
  -- Pull more raw rows than the window needs so invalid-value filtering
  -- doesn't starve it, then take the most recent `v_persistence_window`
  -- VALID ones. `v_valid_count` (out of the window) drives completeness;
  -- `v_latest_ts` (from the RAW pull, valid or not) drives freshness — a
  -- station that is emitting garbage is still "reporting", just invalidly.
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
    -- no readings at all for this station+pollutant — nothing to evaluate,
    -- not even a suppressed candidate (there is no signal to suppress).
    return null;
  end if;

  v_freshness_minutes := extract(epoch from (now() - v_latest_ts)) / 60.0;
  v_completeness := v_valid_count::double precision / v_persistence_window;

  if v_earliest_ts is not null and v_earliest_ts < v_latest_ts and v_current is not null and v_earliest_value is not null then
    v_rate_of_increase := (v_current - v_earliest_value)
      / greatest(extract(epoch from (v_latest_ts - v_earliest_ts)) / 3600.0, 0.1);
  end if;

  -- ---- leading gate: is there anything here worth evaluating at all? ----
  -- Either already over threshold, or (with a positive trend) projected to
  -- cross it within the horizon. Anything else is not a candidate — most
  -- readings, most of the time, correctly produce no row at all.
  if v_current is null or (
    v_current < v_threshold
    and not (v_rate_of_increase is not null and v_rate_of_increase > 0
             and (v_threshold - v_current) / v_rate_of_increase <= v_horizon_hours)
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

  -- ---- data-quality gate ----
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
      v_stage := 'detected';
      v_crossing_prob := 1.0;
    elsif v_current < v_threshold and v_rate_of_increase is not null and v_rate_of_increase > 0
       and v_local_excess is not null and v_local_excess >= v_local_excess_min then
      declare v_hours_to_cross double precision := (v_threshold - v_current) / v_rate_of_increase;
      begin
        if v_hours_to_cross <= v_horizon_hours then
          v_triggered := v_triggered || '"trend_projection"'::jsonb;
          v_stage := 'predicted';
          v_crossing_prob := greatest(0, least(1, 1 - v_hours_to_cross / v_horizon_hours));
          v_projected_crossing_at := now() + make_interval(hours => v_hours_to_cross::int, mins => ((v_hours_to_cross - floor(v_hours_to_cross)) * 60)::int);
        end if;
      end;
    end if;
  end if;

  -- ---- confidence: a stated, documented weighted score, never an ML output ----
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

  -- ---- store the candidate (always — this IS the "anomaly candidate
  -- created" / "anomaly suppressed by data-quality rule" audit event, plan
  -- §10. `incident_events.incident_id` is NOT NULL and no incident exists
  -- yet at this point, so the insert-only candidate row itself is the
  -- immutable record — this is the audit trail, suppressed or not,
  -- incident-worthy or not; the only field ever touched after insert is the
  -- incident_id backlink once/if an incident is created below) ----
  insert into anomaly_candidates (
    city_id, ward_id, station_id, pollutant, detection_stage,
    current_concentration, baseline_value, local_excess, rate_of_increase,
    persistence_count, nearby_station_diff, threshold_crossing_probability,
    projected_crossing_at, data_freshness_minutes, data_completeness,
    sensor_quality, threshold_used, triggered_rules, confidence,
    suppressed, suppression_reason
  ) values (
    v_city_id, v_station.ward_id, p_station_id, p_pollutant, v_stage,
    v_current, v_baseline_value, v_local_excess, v_rate_of_increase,
    v_persistence_count, v_nearby_diff, v_crossing_prob,
    v_projected_crossing_at, v_freshness_minutes, v_completeness,
    v_station.sensor_type, v_threshold, v_triggered, v_confidence,
    v_suppressed, v_suppression_reason
  ) returning id into v_candidate_id;

  if v_suppressed then
    -- Suppression is auditable at the candidate level (suppressed +
    -- suppression_reason, both immutable once written — nothing here ever
    -- UPDATEs a candidate row). No incident_events row is possible yet
    -- because incident_events.incident_id is NOT NULL and no incident
    -- exists (nor should one) for a suppressed candidate.
    return v_candidate_id;
  end if;

  if v_stage is null then
    -- Leading signal fired but the full rule did not (e.g. persistence not
    -- yet met) — exactly "one isolated high reading". Candidate stored,
    -- fully auditable, but no incident.
    return v_candidate_id;
  end if;

  -- ---- deduplication + create-or-update (plan §6) ----
  -- Same advisory-lock namespace `link_report_to_incident` uses for the same
  -- ward, so a citizen report and an anomaly firing for the same ward cannot
  -- race each other into two separate incidents for the same real event.
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
      -- Only upgrade detection_stage for an incident that ITSELF originated
      -- from automated detection (detection_stage already set) — a
      -- citizen-reported or manually-created incident's origin is never
      -- silently relabelled as "predicted"/"detected" by a later sensor
      -- signal; it is only ever corroborated (incident_evidence + event).
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
          format('New %s reading corroborates this incident (%s, stage %s).', p_pollutant, round(v_current::numeric, 1), v_stage),
          false,
          jsonb_build_object('anomaly_candidate_id', v_candidate_id, 'pollutant', p_pollutant, 'detection_stage', v_stage)
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
        case v_stage when 'detected' then 'anomaly_persistence_threshold' else 'anomaly_trend_projection' end,
        v_stage, 'suspected', p_pollutant, v_station.lat, v_station.lng, v_local_excess,
        format('Automatically %s: %s reading of %s at %s (threshold %s).',
               case v_stage when 'detected' then 'detected' else 'predicted' end,
               upper(p_pollutant), round(v_current::numeric, 1), v_station.name, round(v_threshold::numeric, 1))
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
        -- payload — a citizen whose own report later links to this incident
        -- can see this event, and those are internal references with no
        -- citizen-facing meaning. pollutant/detection_stage are as benign as
        -- what the citizen already reported themselves.
        jsonb_build_object('pollutant', p_pollutant, 'detection_stage', v_stage)
      );
    end if;

    update anomaly_candidates set incident_id = v_incident_id where id = v_candidate_id;
  end if;

  return v_candidate_id;
end $$;

revoke all on function evaluate_station_pollutant_anomaly(bigint, text) from public;
grant execute on function evaluate_station_pollutant_anomaly(bigint, text) to authenticated;

-- ============================================================
-- run_anomaly_detection — the bulk driver: every active station in a city
-- (or every city when p_city_code is null), for every pollutant in that
-- city's OWN configured priority list (city_config.pollutant_priority —
-- defaults to pm25/pm10/no2, plan's own priority order; a city may add
-- so2/co/o3 without any code change). This is what ingest/ calls on its
-- existing cron; it is also the "run detection now" surface a commander's
-- session could call directly for the same auth reasons documented above.
-- ============================================================
create or replace function run_anomaly_detection(p_city_code text default null)
returns table (station_id bigint, pollutant text, candidate_id bigint)
language plpgsql security definer set search_path = public as $$
declare
  v_caller_role user_role;
  r record;
  v_cid bigint;
begin
  if auth.uid() is not null then
    select role into v_caller_role from profiles where id = auth.uid();
    if coalesce(v_caller_role, 'citizen') not in ('commander', 'admin') then
      raise exception 'Only a commander or admin may run anomaly detection.'
        using errcode = 'insufficient_privilege';
    end if;
  end if;

  for r in
    select s.id as station_id, unnest(c.pollutant_priority) as pollutant
    from stations s
    join wards w on w.id = s.ward_id
    join city_config c on c.id = w.city_id
    where c.is_active
      and (p_city_code is null or c.city_code = p_city_code)
  loop
    station_id := r.station_id;
    pollutant := r.pollutant;
    candidate_id := evaluate_station_pollutant_anomaly(r.station_id, r.pollutant);
    return next;
  end loop;
end $$;

revoke all on function run_anomaly_detection(text) from public;
grant execute on function run_anomaly_detection(text) to authenticated;

-- ============================================================
-- Seed: Delhi's own anomaly-detection configuration (plan's "seed Delhi
-- configuration for testing"). Merged into the existing config jsonb rather
-- than overwritten, so this is safe to re-run and safe alongside any other
-- key a future migration adds to the same column.
-- ============================================================
update city_config
set config = config || jsonb_build_object(
  'anomaly_detection', jsonb_build_object(
    'pollutant_thresholds', jsonb_build_object(
      'pm25', 90, 'pm10', 250, 'no2', 180, 'so2', 380, 'co', 4000, 'o3', 180
    ),
    'persistence_window_readings', 3,
    'persistence_min_count', 2,
    'local_excess_min', 20,
    'nearby_station_radius_m', 5000,
    'data_completeness_min', 0.5,
    'data_freshness_max_minutes', 180,
    'prediction_horizon_hours', 6,
    'dedup_window_hours', 12
  )
)
where city_code = 'delhi'
  and not (config ? 'anomaly_detection');
