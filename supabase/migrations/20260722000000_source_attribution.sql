-- ============================================================
-- source_attribution — additive migration (Phase 7, vertical slice)
--
-- Transparent, rule-based (no ML) probable-source attribution for every open
-- incident, using ONLY evidence that genuinely exists in this repository:
-- pollutant readings, PM10/PM2.5 ratio, wind direction (attributions),
-- responsibility_registry (known source locations, city/ward scoped),
-- linked citizen reports, evidence-mission/field-inspection outcomes, and
-- the anomaly-detection engine's own local-excess/multi-station signals.
-- Never invents live traffic, satellite, construction-operation or
-- industrial telemetry — where that evidence category does not exist, this
-- migration records it as MISSING, not as zero-and-silent.
--
-- Nothing here is destructive:
--   * three new enum labels appended to the EXISTING `source_category` enum
--     (`regional_transport`, `mixed`, `unresolved`) rather than a second,
--     parallel category type — `source_category` is already reused
--     deliberately across wards/reports/hypotheses/registry/playbooks (see
--     docs/DATA_MODEL.md's own "a second category enum would just be
--     drift" note); the pre-existing 7 labels (including `vehicular` and
--     `industrial`) are UNCHANGED, so classify.py, the Phase 5 playbook
--     seed and every existing report/hypothesis row keep working exactly
--     as before. This migration's own attribution config carries a
--     `category_labels` alias map so the UI can show the plan's literal
--     `traffic_emissions` / `industrial_combustion` wording without
--     renaming the underlying enum value — see the seed block at the
--     bottom and docs/DATA_MODEL.md's Phase 7 section for the full
--     rationale.
--   * new nullable columns on `incidents` (classification_source/
--     classification_set_by/classification_note/classification_updated_at)
--     and on `incident_source_hypotheses` (evidence_scores/
--     supporting_evidence/contradicting_evidence/missing_evidence/
--     data_quality_note/is_current/review_status/reviewed_by/reviewed_at/
--     review_note)
--   * one new partial unique index enforcing "no duplicate CURRENT
--     hypothesis per (incident, category)" — backfilled safely first so a
--     pre-existing duplicate cannot break the migration
--   * two new security-definer functions
--     (calculate_incident_source_attribution / run_incident_source_attribution)
--     and one new read-only function (get_incident_responsible_authority)
--   * no existing table, column, row, policy or function is dropped or
--     narrowed
--
-- Idempotent: safe to re-run.
--
-- IMPORTANT (Phase 11 correction): the three new `source_category` enum
-- labels this migration relies on (`regional_transport`, `mixed`,
-- `unresolved`) are added by the EARLIER migration
-- 20260721500000_source_attribution_enum.sql, not by this file. They used
-- to be added here, but `supabase db push` applies each migration file
-- inside its own single transaction, and Postgres refuses to use a newly
-- added enum value until that transaction has committed — even later in
-- the same transaction. Splitting the `alter type` statements into their
-- own, earlier-committed migration is what makes this file safe under
-- `supabase db push`; see that file's own header for the full story.
-- See docs/DATA_MODEL.md, docs/DATA_QUALITY_AND_SCIENCE.md and
-- docs/ROLE_WORKFLOWS.md for the full mechanism, scoring weights and
-- honest scientific limitations.
-- ============================================================

-- ---------- incidents: local-vs-regional classification provenance ----------
-- `classification` itself (local/mixed/regional/uncertain) already existed
-- (Phase 2). What was missing: any record of WHO/WHAT set it, so a model
-- recalculation could silently clobber a human's own judgement. Null
-- `classification_source` (every pre-existing row) is treated as "not yet
-- human-confirmed" — the attribution engine may set/update it freely until
-- a human explicitly takes it over.
alter table incidents add column if not exists classification_source text
  check (classification_source is null or classification_source in ('model', 'human'));
alter table incidents add column if not exists classification_set_by uuid references profiles(id);
alter table incidents add column if not exists classification_note text;
alter table incidents add column if not exists classification_updated_at timestamptz;

-- ---------- incident_source_hypotheses: the richer, auditable output ----------
alter table incident_source_hypotheses add column if not exists evidence_scores jsonb not null default '{}'::jsonb;
alter table incident_source_hypotheses add column if not exists supporting_evidence jsonb not null default '[]'::jsonb;
alter table incident_source_hypotheses add column if not exists contradicting_evidence jsonb not null default '[]'::jsonb;
alter table incident_source_hypotheses add column if not exists missing_evidence jsonb not null default '[]'::jsonb;
alter table incident_source_hypotheses add column if not exists data_quality_note text;
-- Marks the currently-live calculation for a (incident, category) pair.
-- Older calculations are kept (is_current = false) as the versioned audit
-- history the plan requires — nothing here is ever DELETEd.
alter table incident_source_hypotheses add column if not exists is_current boolean not null default true;
-- A command reviewer's own disposition on ONE hypothesis row — deliberately
-- separate from `confidence_level` (the evidence-strength enum this repo
-- already uses everywhere else): a rejection/unresolved mark is a human
-- judgement call, not itself new evidence.
alter table incident_source_hypotheses add column if not exists review_status text not null default 'pending'
  check (review_status in ('pending', 'confirmed_corroborated', 'marked_unresolved', 'rejected'));
alter table incident_source_hypotheses add column if not exists reviewed_by uuid references profiles(id);
alter table incident_source_hypotheses add column if not exists reviewed_at timestamptz;
alter table incident_source_hypotheses add column if not exists review_note text;

-- Backfill BEFORE the unique index: any pre-existing rows for the same
-- (incident_id, source_category) — e.g. link_report_to_incident's own
-- report_vote_v1 rows plus a possible manual entry — keep only the most
-- recently computed one as "current". Safe to re-run (a no-op once caught up).
with ranked as (
  select id, row_number() over (
    partition by incident_id, source_category
    order by computed_at desc, id desc
  ) as rn
  from incident_source_hypotheses
)
update incident_source_hypotheses h set is_current = false
from ranked where ranked.id = h.id and ranked.rn > 1 and h.is_current;

-- Structural guarantee for "avoid duplicate hypotheses" (plan §6): at most
-- one CURRENT row per (incident, category). A recalculation must retire the
-- old row (is_current = false) before inserting a new one, never both live
-- at once.
create unique index if not exists incident_hypotheses_current_uq
  on incident_source_hypotheses (incident_id, source_category) where is_current;

create index if not exists incident_hypotheses_review_idx
  on incident_source_hypotheses (incident_id, review_status) where is_current;

-- ============================================================
-- calculate_incident_source_attribution — evaluate ONE incident.
--
-- Every weight/threshold/window below is read from
-- `city_config.config -> 'attribution'`, with documented SQL fallbacks used
-- only when a city has not configured a value (mirrors
-- evaluate_station_pollutant_anomaly's own pattern exactly). See
-- docs/DATA_QUALITY_AND_SCIENCE.md for the scientific basis and honest
-- limitations of every one of these numbers.
--
-- Evidence used (plan §2), and ONLY this — nothing here fabricates a
-- signal that has no real data behind it:
--   * PM2.5/PM10/NO2/SO2/CO(/O3) — latest reading for the incident's ward
--   * PM10:PM2.5 ratio — dust signature (does not itself prove dust)
--   * wind direction — `attributions` (existing wind-rose table), only when
--     fresh; a stale/missing row is recorded as MISSING, never guessed
--   * `responsibility_registry` — the only "known source location" data
--     this repo has; there are no per-asset coordinates, so proximity is
--     ward-level (present in this ward / present city-wide / absent), not
--     a metric distance — stated as a limitation, not silently upgraded
--   * linked citizen reports (`reports.ai_category`) and citizen
--     verification answers (`evidence_missions` outcomes) — ONE report or
--     answer never corroborates a source (plan §4); TWO OR MORE
--     independent reporters add real, if partial, corroborating evidence
--   * field-inspection/photo evidence (`incident_evidence`), mapped back to
--     a category via the originating mission's `mission_type` — a coarse,
--     documented mapping (there is no per-evidence category tag)
--   * the anomaly-detection engine's own `local_excess` and a city-wide
--     "how many other stations are also elevated right now" fraction —
--     the genuine, already-computed basis for "regional vs local"
--   * previous incidents at the same location are NOT separately modelled
--     in this pass — `responsibility_registry`/`wards.dominant_source`
--     already carry the closest thing this schema has to "known history
--     for this place"; a true incident-recurrence-pattern feature is
--     future work, stated here rather than invented
--
-- Deliberately NOT used, because it does not exist as real, configured
-- data in this repository: live traffic counts, satellite imagery,
-- construction-permit/operating-hours telemetry, industrial-operation
-- telemetry. Their absence is recorded in `missing_evidence`.
--
-- Confidence levels reuse the EXISTING `source_confidence_level` enum
-- (suspected/corroborated/officially_verified) rather than a new one:
--   * every model-computed row starts at (or stays at) `suspected`
--   * `corroborated` requires BOTH an environmental signal (pollutant
--     signature, wind/GIS alignment, or a strong regional pattern) AND
--     citizen or field evidence — never citizen evidence alone
--   * `officially_verified` is NEVER set by this function — plan §5: that
--     requires authorised field confirmation or official telemetry, which
--     only ever happens through the existing evidence-mission "confirmed"
--     officer flow (Phase 3), untouched by this migration
--   * a category whose CURRENT row is already `officially_verified` is
--     never touched by this function again — plan §6's "never overwrite
--     an authorised verified finding with a weaker model result"
--
-- security definer, mirroring evaluate_station_pollutant_anomaly exactly:
-- an authenticated caller must be commander/admin; an unauthenticated
-- (service_role) caller — the ingest cron — is allowed through, since that
-- already bypasses RLS regardless.
-- ============================================================
create or replace function calculate_incident_source_attribution(
  p_incident_id bigint,
  p_force boolean default false
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_caller_role user_role;
  v_incident incidents%rowtype;
  v_city_id int;
  v_city_cfg jsonb;
  v_anomaly_cfg jsonb;
  v_pollutant_thresholds jsonb;
  v_cfg jsonb;

  -- config, with documented fallbacks
  v_categories text[];
  v_weights jsonb;
  v_dust_ratio_min double precision;
  v_wind_score double precision;
  v_wind_max_age_hours double precision;
  v_gis_ward_score double precision;
  v_gis_city_score double precision;
  v_rush_windows jsonb;
  v_rush_score double precision;
  v_offpeak_score double precision;
  v_citizen_partial_n int;
  v_citizen_full_n int;
  v_citizen_partial_score double precision;
  v_citizen_full_score double precision;
  v_citizen_verif_boost double precision;
  v_field_score_const double precision;
  v_regional_excess_max double precision;
  v_regional_station_frac double precision;
  v_regional_score_const double precision;
  v_regional_penalty_factor double precision;
  v_readings_fresh_hours double precision;
  v_confidence_threshold double precision;
  v_ambiguity_gap double precision;
  v_min_total double precision;
  v_recalc_hours double precision;
  v_corrob_env_min double precision;

  -- ward-level facts (computed once, shared by every category)
  v_pm25 double precision; v_pm10 double precision; v_no2 double precision;
  v_so2 double precision; v_co double precision; v_o3 double precision;
  v_readings_ts timestamptz;
  v_has_readings boolean := false;
  v_wind_dir text; v_wind_ts timestamptz; v_has_wind boolean := false;
  v_has_registry boolean := false;
  v_has_citizen_evidence boolean := false;
  v_has_field_evidence boolean := false;
  v_local_hour int;
  v_missing_signal_count int := 0;
  v_dq_note text;
  v_unresolved_missing text[];

  -- regional signal
  v_local_excess double precision;
  v_elevated_fraction double precision;
  v_regional_signal double precision := 0;

  -- protected (already officially_verified) categories
  v_protected_categories text[] := array[]::text[];

  -- per-category working variables
  v_cat text;
  v_sig double precision; v_wind double precision; v_gis double precision;
  v_temporal double precision; v_citizen double precision; v_field double precision;
  v_regional double precision; v_contra double precision; v_dq_penalty double precision;
  v_raw double precision;
  v_missing text[]; v_supporting text[]; v_contradicting text[];
  v_registry_ward_hit boolean; v_registry_city_hit boolean;
  v_distinct_reporters int;
  v_citizen_verified_confirm boolean;
  v_field_hit boolean; v_field_contra boolean;

  -- accumulated per-category maps (avoids losing per-category state between
  -- the scoring loop and the insert loop)
  v_raw_scores jsonb := '{}'::jsonb;
  v_evidence_scores jsonb := '{}'::jsonb;
  v_supporting_map jsonb := '{}'::jsonb;
  v_contradicting_map jsonb := '{}'::jsonb;
  v_missing_map jsonb := '{}'::jsonb;
  v_total_raw double precision := 0;

  v_prob double precision;
  v_top1_cat text; v_top1_prob double precision := -1;
  v_top2_cat text; v_top2_prob double precision := -1;
  v_ambiguous boolean := false;

  v_now timestamptz := now();
  v_calc_version text := 'attribution_rule_engine_v1';
begin
  select * into v_incident from incidents where id = p_incident_id;
  if not found then
    raise exception 'Incident % not found', p_incident_id;
  end if;

  -- ---- authorisation (mirrors evaluate_station_pollutant_anomaly) ----
  if auth.uid() is not null then
    select role into v_caller_role from profiles where id = auth.uid();
    if coalesce(v_caller_role, 'citizen') not in ('commander', 'admin') then
      raise exception 'Only a commander or admin may run source attribution.'
        using errcode = 'insufficient_privilege';
    end if;
  end if;

  v_city_id := coalesce(v_incident.city_id, (select city_id from wards where id = v_incident.ward_id));

  select coalesce(config, '{}'::jsonb) into v_city_cfg from city_config where id = v_city_id;
  v_anomaly_cfg := coalesce(v_city_cfg -> 'anomaly_detection', '{}'::jsonb);
  -- Reuses the SAME pollutant thresholds anomaly detection already reads,
  -- rather than a second, potentially-inconsistent "elevated" table.
  v_pollutant_thresholds := coalesce(v_anomaly_cfg -> 'pollutant_thresholds', '{}'::jsonb);
  v_cfg := coalesce(v_city_cfg -> 'attribution', '{}'::jsonb);

  v_categories := coalesce(
    (select array_agg(x) from jsonb_array_elements_text(coalesce(v_cfg -> 'source_categories', '[]'::jsonb)) x),
    array['road_dust', 'construction_dust', 'vehicular', 'open_burning', 'industrial', 'regional_transport']
  );
  v_weights               := coalesce(v_cfg -> 'weights', '{}'::jsonb);
  v_dust_ratio_min        := coalesce((v_cfg ->> 'dust_pm_ratio_min')::double precision, 2.5);
  v_wind_score            := coalesce((v_cfg ->> 'wind_alignment_score')::double precision, 0.6);
  v_wind_max_age_hours    := coalesce((v_cfg ->> 'wind_max_age_hours')::double precision, 48);
  v_gis_ward_score        := coalesce((v_cfg ->> 'gis_ward_match_score')::double precision, 0.5);
  v_gis_city_score        := coalesce((v_cfg ->> 'gis_city_match_score')::double precision, 0.25);
  v_rush_windows          := coalesce(v_cfg -> 'rush_hour_windows', '[[7,11],[17,21]]'::jsonb);
  v_rush_score            := coalesce((v_cfg ->> 'rush_hour_score')::double precision, 1.0);
  v_offpeak_score         := coalesce((v_cfg ->> 'off_peak_score')::double precision, 0.3);
  v_citizen_partial_n     := coalesce((v_cfg ->> 'citizen_partial_reports')::int, 2);
  v_citizen_full_n        := coalesce((v_cfg ->> 'citizen_full_reports')::int, 3);
  v_citizen_partial_score := coalesce((v_cfg ->> 'citizen_partial_score')::double precision, 0.5);
  v_citizen_full_score    := coalesce((v_cfg ->> 'citizen_full_score')::double precision, 1.0);
  v_citizen_verif_boost   := coalesce((v_cfg ->> 'citizen_verification_boost')::double precision, 0.2);
  v_field_score_const     := coalesce((v_cfg ->> 'field_verification_score')::double precision, 0.9);
  v_regional_excess_max   := coalesce((v_cfg ->> 'regional_local_excess_max')::double precision, 15);
  v_regional_station_frac := coalesce((v_cfg ->> 'regional_min_station_fraction')::double precision, 0.5);
  v_regional_score_const  := coalesce((v_cfg ->> 'regional_pattern_score')::double precision, 1.0);
  v_regional_penalty_factor := coalesce((v_cfg ->> 'regional_penalty_factor')::double precision, 0.5);
  v_readings_fresh_hours  := coalesce((v_cfg ->> 'readings_freshness_hours')::double precision, 6);
  v_confidence_threshold  := coalesce((v_cfg ->> 'confidence_threshold')::double precision, 0.45);
  v_ambiguity_gap         := coalesce((v_cfg ->> 'ambiguity_gap')::double precision, 0.12);
  v_min_total             := coalesce((v_cfg ->> 'min_total_score_for_resolution')::double precision, 0.05);
  v_recalc_hours          := coalesce((v_cfg ->> 'recalculation_interval_hours')::double precision, 6);
  v_corrob_env_min        := coalesce((v_cfg ->> 'corroboration_min_env_score')::double precision, 0.3);

  -- ---- skip if recently calculated and not forced (recalculation interval) ----
  if not p_force and exists (
    select 1 from incident_source_hypotheses
    where incident_id = p_incident_id and is_current
      and computed_at >= v_now - make_interval(hours => v_recalc_hours::int)
  ) then
    return;
  end if;

  -- ---- ward-level facts, gathered once ----
  if v_incident.ward_id is not null then
    select r.pm25, r.pm10, r.no2, r.so2, r.co, r.o3, r.ts
      into v_pm25, v_pm10, v_no2, v_so2, v_co, v_o3, v_readings_ts
    from stations s
    join readings r on r.station_id = s.id
    where s.ward_id = v_incident.ward_id
      and r.ts >= v_now - make_interval(hours => v_readings_fresh_hours::int)
    order by r.ts desc
    limit 1;
    if v_readings_ts is not null then v_has_readings := true; end if;

    select direction, ts into v_wind_dir, v_wind_ts
    from attributions where ward_id = v_incident.ward_id
    order by ts desc limit 1;
    if v_wind_ts is not null and v_wind_ts >= v_now - make_interval(hours => v_wind_max_age_hours::int) then
      v_has_wind := true;
    else
      v_wind_dir := null;
    end if;

    v_local_hour := extract(
      hour from (v_now at time zone coalesce((select timezone from city_config where id = v_city_id), 'Asia/Kolkata'))
    )::int;
  end if;

  select exists(select 1 from responsibility_registry where city_id = v_city_id) into v_has_registry;

  select exists(
    select 1 from reports where incident_id = p_incident_id
    union all
    select 1 from evidence_missions
      where incident_id = p_incident_id and mission_type = 'citizen_verification' and outcome is not null
  ) into v_has_citizen_evidence;

  select exists(
    select 1 from incident_evidence
    where incident_id = p_incident_id and evidence_type in ('field_inspection', 'photo')
  ) into v_has_field_evidence;

  v_missing_signal_count :=
    (case when v_has_readings then 0 else 1 end) +
    (case when v_has_wind then 0 else 1 end) +
    (case when v_has_registry then 0 else 1 end) +
    (case when v_has_citizen_evidence then 0 else 1 end) +
    (case when v_has_field_evidence then 0 else 1 end);

  v_dq_note := format(
    'Evidence availability for this calculation: monitoring readings %s, wind direction %s, responsibility registry %s, citizen evidence %s, field evidence %s (%s of 5 evidence types available).',
    v_has_readings, v_has_wind, v_has_registry, v_has_citizen_evidence, v_has_field_evidence, 5 - v_missing_signal_count
  );

  v_unresolved_missing := array[]::text[];
  if not v_has_readings then v_unresolved_missing := v_unresolved_missing || 'No recent monitoring (pollutant) readings for this ward.'::text; end if;
  if not v_has_wind then v_unresolved_missing := v_unresolved_missing || 'No recent wind-direction data for this ward.'::text; end if;
  if not v_has_registry then v_unresolved_missing := v_unresolved_missing || 'No responsibility-registry entries exist for this city at all.'::text; end if;
  if not v_has_citizen_evidence then v_unresolved_missing := v_unresolved_missing || 'No citizen reports or verification answers are linked to this incident.'::text; end if;
  if not v_has_field_evidence then v_unresolved_missing := v_unresolved_missing || 'No field verification has been performed for this incident.'::text; end if;

  -- ---- regional signal: this incident's own latest anomaly-detection
  -- local_excess, plus a genuine city-wide "how many OTHER stations are
  -- also currently elevated" fraction for the same pollutant/threshold
  -- anomaly detection already uses. Both are real, already-stored/derivable
  -- values — nothing invented. ----
  select local_excess into v_local_excess
  from anomaly_candidates
  where incident_id = p_incident_id
  order by detected_at desc limit 1;

  if v_incident.primary_pollutant is not null and (v_pollutant_thresholds ->> v_incident.primary_pollutant) is not null then
    declare
      v_thr double precision := (v_pollutant_thresholds ->> v_incident.primary_pollutant)::double precision;
      v_total_stations int;
      v_elevated_stations int;
    begin
      select count(*) into v_total_stations
      from stations s join wards w on w.id = s.ward_id
      where w.city_id = v_city_id;

      select count(*) into v_elevated_stations
      from (
        select distinct on (s.id) s.id,
          case v_incident.primary_pollutant
            when 'pm25' then r.pm25 when 'pm10' then r.pm10 when 'no2' then r.no2
            when 'so2' then r.so2 when 'co' then r.co when 'o3' then r.o3
          end as val
        from stations s
        join wards w on w.id = s.ward_id
        join readings r on r.station_id = s.id
        where w.city_id = v_city_id
          and r.ts >= v_now - make_interval(hours => v_readings_fresh_hours::int)
        order by s.id, r.ts desc
      ) latest
      where val is not null and val >= v_thr;

      if v_total_stations > 0 then
        v_elevated_fraction := v_elevated_stations::double precision / v_total_stations;
      end if;
    end;
  end if;

  if v_local_excess is not null and v_elevated_fraction is not null
     and abs(v_local_excess) <= v_regional_excess_max and v_elevated_fraction >= v_regional_station_frac then
    v_regional_signal := v_regional_score_const;
  end if;

  -- ---- categories already officially_verified: never touched again ----
  select coalesce(array_agg(source_category::text), array[]::text[])
    into v_protected_categories
  from incident_source_hypotheses
  where incident_id = p_incident_id and is_current and confidence_level = 'officially_verified';

  -- ============================================================
  -- per-category scoring
  -- ============================================================
  foreach v_cat in array v_categories loop
    if v_cat = any(v_protected_categories) then
      continue;
    end if;

    v_sig := 0; v_wind := 0; v_gis := 0; v_temporal := 0; v_citizen := 0; v_field := 0;
    v_regional := 0; v_contra := 0; v_dq_penalty := 0;
    v_missing := array[]::text[]; v_supporting := array[]::text[]; v_contradicting := array[]::text[];

    -- ---- pollutant signature ----
    if v_cat in ('road_dust', 'construction_dust') then
      if v_pm25 is not null and v_pm10 is not null and v_pm25 > 0 then
        v_sig := greatest(0, least(1, ((v_pm10 / v_pm25) - v_dust_ratio_min) / v_dust_ratio_min));
        if v_sig > 0 then
          v_supporting := v_supporting || format(
            'PM10/PM2.5 ratio of %s is consistent with a dust source (does not itself distinguish road dust from construction dust — see gis_proximity/wind_alignment for that).',
            round((v_pm10 / v_pm25)::numeric, 1)
          );
        end if;
      else
        v_missing := v_missing || 'PM2.5 and/or PM10 readings are unavailable for this ward.'::text;
      end if;
    elsif v_cat = 'vehicular' then
      declare
        v_no2_thr double precision := (v_pollutant_thresholds ->> 'no2')::double precision;
        v_co_thr double precision := (v_pollutant_thresholds ->> 'co')::double precision;
      begin
        -- BOTH NO2 and CO must be present and elevated together — a single
        -- elevated pollutant (e.g. PM2.5 alone from a regional event) must
        -- not be credited as a vehicular-combustion signature.
        if v_no2 is not null and v_no2_thr is not null and v_co is not null and v_co_thr is not null then
          v_sig := (least(1, v_no2 / v_no2_thr) + least(1, v_co / v_co_thr)) / 2;
          if v_sig > 0.3 then
            v_supporting := v_supporting || 'Elevated NO2 together with CO is consistent with vehicular combustion (does not itself prove it).'::text;
          end if;
        else
          v_missing := v_missing || 'NO2 and CO readings (both needed together for this signature) are not both available for this ward.'::text;
        end if;
      end;
    elsif v_cat = 'open_burning' then
      declare
        v_pm25_thr double precision := (v_pollutant_thresholds ->> 'pm25')::double precision;
        v_co_thr double precision := (v_pollutant_thresholds ->> 'co')::double precision;
      begin
        -- BOTH PM2.5 and CO must be present and elevated together — PM2.5
        -- alone (e.g. from a regional event, with no CO data) must not be
        -- credited as an open-burning signature.
        if v_pm25 is not null and v_pm25_thr is not null and v_co is not null and v_co_thr is not null then
          v_sig := (least(1, v_pm25 / v_pm25_thr) + least(1, v_co / v_co_thr)) / 2;
          if v_sig > 0.3 then
            v_supporting := v_supporting || 'Elevated PM2.5 together with CO is consistent with a combustion/burning signature (does not itself prove open burning).'::text;
          end if;
        else
          v_missing := v_missing || 'PM2.5 and CO readings (both needed together for this signature) are not both available for this ward.'::text;
        end if;
      end;
    elsif v_cat = 'industrial' then
      declare
        v_so2_thr double precision := (v_pollutant_thresholds ->> 'so2')::double precision;
        v_no2_thr double precision := (v_pollutant_thresholds ->> 'no2')::double precision;
      begin
        -- BOTH SO2 and NO2 must be present and elevated together — a single
        -- elevated pollutant must not be credited as an industrial signature.
        if v_so2 is not null and v_so2_thr is not null and v_no2 is not null and v_no2_thr is not null then
          v_sig := (least(1, v_so2 / v_so2_thr) + least(1, v_no2 / v_no2_thr)) / 2;
          if v_sig > 0.3 then
            v_supporting := v_supporting || 'Elevated SO2 together with NO2 is consistent with industrial combustion (does not itself prove it).'::text;
          end if;
        else
          v_missing := v_missing || 'SO2 and NO2 readings (both needed together for this signature) are not both available for this ward.'::text;
        end if;
      end;
    end if;
    -- regional_transport has no pollutant-SIGNATURE term of its own — its
    -- evidence is the multi-station/local-excess pattern, scored below.

    -- ---- wind/upwind alignment + GIS proximity, via responsibility_registry ----
    -- Ward-level only: this schema has no per-asset coordinates, so this is
    -- NOT a metric distance or a true bearing check — stated honestly, not
    -- silently upgraded into one. "Proximity alone must never determine the
    -- source" (plan §4) is why gis_proximity's weight is capped low relative
    -- to pollutant_signature/field_verification, not why it is zero.
    if v_cat in ('road_dust', 'construction_dust', 'vehicular', 'industrial') then
      select exists(
        select 1 from responsibility_registry
        where city_id = v_city_id and source_category = v_cat::source_category and ward_id = v_incident.ward_id
      ) into v_registry_ward_hit;
      select exists(
        select 1 from responsibility_registry
        where city_id = v_city_id and source_category = v_cat::source_category
      ) into v_registry_city_hit;

      if v_registry_ward_hit then
        v_gis := v_gis_ward_score;
        v_supporting := v_supporting || format('A registered %s source location exists in this ward (ward-level match, not a metric distance).', v_cat);
      elsif v_registry_city_hit then
        v_gis := v_gis_city_score;
        v_supporting := v_supporting || format('A registered %s source location exists in this city, but not confirmed in this specific ward.', v_cat);
      else
        v_missing := v_missing || format('No known %s source location is registered in the responsibility registry for this city.', v_cat);
      end if;

      if v_has_wind and v_registry_ward_hit then
        v_wind := v_wind_score;
        v_supporting := v_supporting || format(
          'Current wind direction (%s) is recorded while a known %s source is registered in this ward (a coarse, ward-level alignment check, not a per-asset bearing calculation).',
          v_wind_dir, v_cat
        );
      elsif not v_has_wind then
        v_missing := v_missing || 'No recent wind-direction data is available for this ward.'::text;
      end if;
    end if;

    -- ---- temporal/activity match ----
    -- Only vehicular has a genuine, non-invented temporal signal available
    -- (time-of-day). There is no construction-operation or industrial-
    -- operation telemetry in this repository — recorded as missing, exactly
    -- as the plan requires, rather than guessed.
    if v_cat = 'vehicular' then
      if exists (
        select 1 from jsonb_array_elements(v_rush_windows) w
        where v_local_hour >= (w ->> 0)::int and v_local_hour <= (w ->> 1)::int
      ) then
        v_temporal := v_rush_score;
        v_supporting := v_supporting || 'Detected during a configured peak-traffic window.'::text;
      else
        v_temporal := v_offpeak_score;
      end if;
    else
      v_missing := v_missing || format('No construction/industrial-operation telemetry exists to time-match against %s.', v_cat);
    end if;

    -- ---- citizen corroboration ----
    -- One report never corroborates a source (plan §4). Two independent
    -- reporters add real, partial evidence; three or more reach full weight.
    select count(distinct reporter_id) into v_distinct_reporters
    from reports where incident_id = p_incident_id and ai_category = v_cat::source_category;

    if v_distinct_reporters >= v_citizen_full_n then
      v_citizen := v_citizen_full_score;
      v_supporting := v_supporting || format('%s independent citizen reports name this source category.', v_distinct_reporters);
    elsif v_distinct_reporters >= v_citizen_partial_n then
      v_citizen := v_citizen_partial_score;
      v_supporting := v_supporting || format('%s independent citizen reports name this source category (partial corroboration).', v_distinct_reporters);
    elsif v_distinct_reporters = 1 then
      v_missing := v_missing || 'Only one citizen report names this category — a single report cannot corroborate a source.'::text;
    else
      v_missing := v_missing || 'No citizen reports name this source category.'::text;
    end if;

    select exists(
      select 1 from evidence_missions
      where incident_id = p_incident_id and mission_type = 'citizen_verification' and outcome = 'confirmed'
        and (
          (v_cat = 'road_dust' and public_prompt ilike '%dust%')
          or (v_cat = 'construction_dust' and public_prompt ilike '%construction%')
          or (v_cat = 'open_burning' and public_prompt ilike '%smoke%')
        )
    ) into v_citizen_verified_confirm;
    if v_citizen_verified_confirm then
      v_citizen := least(1, v_citizen + v_citizen_verif_boost);
      v_supporting := v_supporting || 'A citizen answered a safe verification question consistent with this category.'::text;
    end if;

    -- ---- field verification ----
    -- Coarse, documented mapping from the ORIGINATING mission's type to a
    -- category — there is no per-evidence-row category tag in this schema.
    select
      coalesce(bool_or(ie.supports = true), false),
      coalesce(bool_or(ie.supports = false), false)
      into v_field_hit, v_field_contra
    from incident_evidence ie
    join evidence_missions em
      on em.id = case when (ie.payload ->> 'mission_id') ~ '^[0-9]+$' then (ie.payload ->> 'mission_id')::bigint end
    where ie.incident_id = p_incident_id
      and ie.evidence_type in ('field_inspection', 'photo')
      and em.mission_type = any(case v_cat
        when 'road_dust' then array['field_photo']
        when 'construction_dust' then array['construction_check']
        when 'vehicular' then array['traffic_count']
        when 'industrial' then array['source_status_check']
        when 'open_burning' then array['source_status_check']
        when 'regional_transport' then array['upwind_downwind_reading', 'mobile_sensor_route']
        else array[]::text[]
      end);

    if v_field_hit then
      v_field := v_field_score_const;
      v_supporting := v_supporting || format('A field inspection supports %s.', v_cat);
    elsif v_field_contra then
      v_contra := v_contra + 1;
      v_contradicting := v_contradicting || format('A field inspection did not confirm %s.', v_cat);
    else
      v_missing := v_missing || format('No field verification has been performed for %s.', v_cat);
    end if;

    -- Citizen-report contradiction: a linked report explicitly rejected this
    -- category (recorded by link_report_to_incident's own citizen_report
    -- evidence payload). Weighted at half a field contradiction — one
    -- citizen signal, in either direction, is never treated as decisive.
    if exists (
      select 1 from incident_evidence
      where incident_id = p_incident_id and evidence_type = 'citizen_report'
        and supports = false and payload ->> 'ai_category' = v_cat
    ) then
      v_contra := v_contra + 0.5;
      v_contradicting := v_contradicting || format('A linked citizen report was recorded against %s.', v_cat);
    end if;
    v_contra := least(1, v_contra);

    -- ---- regional pattern ----
    if v_cat = 'regional_transport' then
      v_regional := v_regional_signal;
      if v_regional > 0 then
        v_supporting := v_supporting || 'Similar simultaneous pollutant increases across multiple monitoring stations, with low local excess, are consistent with a regional contribution.'::text;
      else
        v_missing := v_missing || 'No multi-station simultaneous-rise pattern with low local excess was found.'::text;
      end if;
    elsif v_regional_signal > 0 then
      -- A strong regional pattern makes a purely LOCAL source less likely,
      -- though it does not rule one out — a stated, documented penalty.
      v_regional := -1 * v_regional_signal * v_regional_penalty_factor;
      v_contradicting := v_contradicting || 'A city-wide simultaneous rise with low local excess suggests a regional contribution, reducing confidence in a purely local source.'::text;
    end if;

    -- ---- data-quality penalty (its own named, scored component) ----
    v_dq_penalty := (v_missing_signal_count::double precision / 5) * coalesce((v_weights ->> 'data_quality_penalty')::double precision, 0.20);

    v_raw := greatest(0,
      coalesce((v_weights ->> 'pollutant_signature')::double precision, 0.35) * v_sig
      + coalesce((v_weights ->> 'wind_alignment')::double precision, 0.15) * v_wind
      + coalesce((v_weights ->> 'gis_proximity')::double precision, 0.15) * v_gis
      + coalesce((v_weights ->> 'temporal_match')::double precision, 0.05) * v_temporal
      + coalesce((v_weights ->> 'citizen_corroboration')::double precision, 0.15) * v_citizen
      + coalesce((v_weights ->> 'field_verification')::double precision, 0.25) * v_field
      + coalesce((v_weights ->> 'regional_pattern')::double precision, 0.20) * v_regional
      - coalesce((v_weights ->> 'contradiction_penalty')::double precision, 0.35) * v_contra
      - v_dq_penalty
    );

    v_raw_scores := v_raw_scores || jsonb_build_object(v_cat, v_raw);
    v_evidence_scores := v_evidence_scores || jsonb_build_object(v_cat, jsonb_build_object(
      'pollutant_signature', round(v_sig::numeric, 3),
      'wind_alignment', round(v_wind::numeric, 3),
      'gis_proximity', round(v_gis::numeric, 3),
      'temporal_match', round(v_temporal::numeric, 3),
      'citizen_corroboration', round(v_citizen::numeric, 3),
      'field_verification', round(v_field::numeric, 3),
      'regional_pattern', round(v_regional::numeric, 3),
      'contradiction_penalty', round(v_contra::numeric, 3),
      'data_quality_penalty', round(v_dq_penalty::numeric, 3),
      'raw_score', round(v_raw::numeric, 3),
      'weights_used', v_weights
    ));
    v_supporting_map := v_supporting_map || jsonb_build_object(v_cat, to_jsonb(v_supporting));
    v_contradicting_map := v_contradicting_map || jsonb_build_object(v_cat, to_jsonb(v_contradicting));
    v_missing_map := v_missing_map || jsonb_build_object(v_cat, to_jsonb(v_missing));
    v_total_raw := v_total_raw + v_raw;
  end loop;

  -- ============================================================
  -- branch 1: not enough evidence to say anything meaningful (plan §4/§5:
  -- "poor data quality produces unresolved or low-confidence output")
  -- ============================================================
  if v_total_raw <= v_min_total then
    update incident_source_hypotheses set is_current = false
    where incident_id = p_incident_id and is_current
      and source_category::text <> all(v_protected_categories)
      and source_category::text = any(v_categories || array['mixed', 'unresolved']);

    insert into incident_source_hypotheses (
      incident_id, source_category, probability, confidence_level, rationale,
      model_version, computed_at, is_current, evidence_scores, supporting_evidence,
      contradicting_evidence, missing_evidence, data_quality_note
    ) values (
      p_incident_id, 'unresolved', 1.0, 'suspected',
      'No source category has enough independent evidence to be assessed as more likely than any other. This is a statement about the evidence available, not about what actually happened.',
      v_calc_version, v_now, true, '{}'::jsonb, '[]'::jsonb, '[]'::jsonb,
      to_jsonb(v_unresolved_missing),
      v_dq_note
    );

    insert into incident_events (incident_id, event_type, actor_id, note, is_public, payload)
    values (
      p_incident_id, 'attribution_recalculated', null,
      'Automated source attribution: insufficient evidence to assess a probable source — marked unresolved.',
      false, jsonb_build_object('calc_version', v_calc_version, 'result', 'unresolved')
    );

    if v_incident.classification_source is null or v_incident.classification_source = 'model' then
      update incidents set
        classification = 'uncertain', classification_source = 'model', classification_updated_at = v_now
      where id = p_incident_id;
    end if;
    return;
  end if;

  -- ============================================================
  -- branch 2: normal — retire old current rows for categories being
  -- recomputed (never the protected/verified ones), then insert fresh ones
  -- ============================================================
  update incident_source_hypotheses set is_current = false
  where incident_id = p_incident_id and is_current
    and source_category::text <> all(v_protected_categories)
    and source_category::text = any(v_categories || array['mixed', 'unresolved']);

  for v_cat in select jsonb_object_keys(v_raw_scores) loop
    declare
      v_es jsonb := v_evidence_scores -> v_cat;
      v_env double precision;
      v_citz double precision;
      v_fld double precision;
      v_ctr double precision;
      v_conf_level source_confidence_level;
      v_rationale text;
      v_contradicted_summary text;
    begin
      v_prob := (v_raw_scores ->> v_cat)::double precision / v_total_raw;

      v_env := greatest(
        (v_es ->> 'pollutant_signature')::double precision,
        (v_es ->> 'wind_alignment')::double precision,
        (v_es ->> 'gis_proximity')::double precision,
        case when v_cat = 'regional_transport' then (v_es ->> 'regional_pattern')::double precision else 0 end
      );
      v_citz := (v_es ->> 'citizen_corroboration')::double precision;
      v_fld := (v_es ->> 'field_verification')::double precision;
      v_ctr := (v_es ->> 'contradiction_penalty')::double precision;

      -- plan §5: model-only stays suspected; independent environmental PLUS
      -- citizen/field evidence may reach corroborated; officially_verified is
      -- never set here.
      if v_env >= v_corrob_env_min and (v_citz > 0 or v_fld > 0) and v_ctr < 0.5 then
        v_conf_level := 'corroborated';
      else
        v_conf_level := 'suspected';
      end if;

      v_contradicted_summary := case
        when jsonb_array_length(coalesce(v_contradicting_map -> v_cat, '[]'::jsonb)) > 0
        then (v_contradicting_map -> v_cat ->> 0)
        else null
      end;

      v_rationale := format(
        'Rule-based attribution (%s): relative confidence %s%%, from pollutant signature %s, wind/GIS alignment %s/%s, temporal match %s, citizen corroboration %s, field verification %s, regional pattern %s, minus contradiction %s and data-quality penalty %s. This is a probable-source hypothesis, not a confirmed violation.',
        v_calc_version, round((v_prob * 100)::numeric, 0),
        round(((v_es ->> 'pollutant_signature')::numeric), 2), round(((v_es ->> 'wind_alignment')::numeric), 2),
        round(((v_es ->> 'gis_proximity')::numeric), 2), round(((v_es ->> 'temporal_match')::numeric), 2),
        round(((v_es ->> 'citizen_corroboration')::numeric), 2), round(((v_es ->> 'field_verification')::numeric), 2),
        round(((v_es ->> 'regional_pattern')::numeric), 2), round(((v_es ->> 'contradiction_penalty')::numeric), 2),
        round(((v_es ->> 'data_quality_penalty')::numeric), 2)
      );

      insert into incident_source_hypotheses (
        incident_id, source_category, probability, confidence_level, rationale, contradicted_by,
        model_version, computed_at, is_current, evidence_scores, supporting_evidence,
        contradicting_evidence, missing_evidence, data_quality_note
      ) values (
        p_incident_id, v_cat::source_category, v_prob, v_conf_level, v_rationale, v_contradicted_summary,
        v_calc_version, v_now, true, v_es, coalesce(v_supporting_map -> v_cat, '[]'::jsonb),
        coalesce(v_contradicting_map -> v_cat, '[]'::jsonb), coalesce(v_missing_map -> v_cat, '[]'::jsonb),
        v_dq_note
      );

      if v_prob > v_top1_prob then
        v_top2_prob := v_top1_prob; v_top2_cat := v_top1_cat;
        v_top1_prob := v_prob; v_top1_cat := v_cat;
      elsif v_prob > v_top2_prob then
        v_top2_prob := v_prob; v_top2_cat := v_cat;
      end if;
    end;
  end loop;

  v_ambiguous := v_top2_cat is not null
    and ((v_top1_prob - v_top2_prob) < v_ambiguity_gap or v_top1_prob < v_confidence_threshold);

  -- plan §1/§7: 'mixed' as its own hypothesis when the top two do not
  -- clearly separate. Its probability is a stated rule (the runner-up's own
  -- share), not a rigorous joint-source estimate — documented as such.
  if v_ambiguous then
    insert into incident_source_hypotheses (
      incident_id, source_category, probability, confidence_level, rationale,
      model_version, computed_at, is_current, missing_evidence
    ) values (
      p_incident_id, 'mixed', v_top2_prob, 'suspected',
      format(
        'The two leading candidate sources (%s at %s%%, %s at %s%%) are too close to confidently distinguish — this incident may involve more than one source, or the evidence available simply does not separate them yet.',
        v_top1_cat, round((v_top1_prob * 100)::numeric, 0), v_top2_cat, round((v_top2_prob * 100)::numeric, 0)
      ),
      v_calc_version, v_now, true, '[]'::jsonb
    );
  end if;

  -- ---- local-vs-regional classification recommendation (plan §7) ----
  -- Never overwrites a human-confirmed classification.
  if v_incident.classification_source is null or v_incident.classification_source = 'model' then
    update incidents set
      classification = (case
        when v_top1_cat = 'regional_transport' and v_top1_prob >= v_confidence_threshold then 'regional'
        when v_ambiguous then 'mixed'
        else 'local'
      end)::incident_classification,
      classification_source = 'model',
      classification_updated_at = v_now
    where id = p_incident_id;
  end if;

  insert into incident_events (incident_id, event_type, actor_id, note, is_public, payload)
  values (
    p_incident_id, 'attribution_recalculated', null,
    format('Automated source attribution recalculated. Leading hypothesis: %s (%s%%). Probable source — not a confirmed violation.', v_top1_cat, round((v_top1_prob * 100)::numeric, 0)),
    false,
    jsonb_build_object('top_category', v_top1_cat, 'top_probability', v_top1_prob, 'ambiguous', v_ambiguous, 'calc_version', v_calc_version)
  );

  -- ============================================================
  -- next-best-evidence recommendation (plan §8): only when ambiguous, low
  -- confidence, or meaningfully contradicted — never for a clear result.
  -- Reuses the existing evidence_missions table/RLS exactly (Phase 3), so
  -- command dispatches it through the SAME "Request evidence" surface
  -- Phase 6 already established, rather than a new mechanism.
  -- ============================================================
  if v_top1_cat is not null and (v_ambiguous or v_top1_prob < v_confidence_threshold) then
    if not exists (
      select 1 from evidence_missions
      where incident_id = p_incident_id and status in ('proposed', 'dispatched')
        and rationale like 'Automated attribution:%'
        and created_at >= v_now - make_interval(hours => v_recalc_hours::int)
    ) then
      declare
        v_mission_type text;
        v_public_prompt text;
        v_rationale text;
      begin
        -- Never send an unsafe citizen mission (plan §8): open_burning and
        -- industrial are the SAME hazardous set docs/incidentRules.ts's
        -- HAZARDOUS_FOR_CITIZENS uses (keep these two lists in sync by hand
        -- — plpgsql cannot import a TypeScript constant).
        if v_ambiguous and v_top2_cat = 'open_burning' and v_top1_cat not in ('open_burning', 'industrial') then
          v_mission_type := 'citizen_verification';
          v_public_prompt := 'Is visible smoke present near the reported location?';
          v_rationale := format(
            'Automated attribution: %s and %s are too close in confidence (%s%% vs %s%%) — a smoke observation would help tell them apart. Safe for a citizen to answer from where they already are.',
            v_top1_cat, v_top2_cat, round((v_top1_prob * 100)::numeric, 0), round((v_top2_prob * 100)::numeric, 0)
          );
        elsif v_top1_cat = 'road_dust' then
          v_mission_type := 'citizen_verification';
          v_public_prompt := 'Is heavy road dust visible near the reported location?';
          v_rationale := format('Automated attribution: leading hypothesis is road dust at %s%% confidence — a visible-dust observation would help confirm or rule it out.', round((v_top1_prob * 100)::numeric, 0));
        elsif v_top1_cat = 'construction_dust' then
          v_mission_type := 'citizen_verification';
          v_public_prompt := 'Is loose construction material left uncovered nearby?';
          v_rationale := format('Automated attribution: leading hypothesis is construction dust at %s%% confidence — an uncovered-material observation would help confirm or rule it out.', round((v_top1_prob * 100)::numeric, 0));
        elsif v_top1_cat in ('open_burning', 'industrial') then
          v_mission_type := 'source_status_check';
          v_rationale := format('Automated attribution: leading hypothesis is %s at %s%% confidence. This needs a trained officer to check — not a citizen mission.', v_top1_cat, round((v_top1_prob * 100)::numeric, 0));
        elsif v_top1_cat = 'vehicular' then
          v_mission_type := 'traffic_count';
          v_rationale := format('Automated attribution: leading hypothesis is traffic emissions at %s%% confidence — a traffic observation would help confirm or rule it out.', round((v_top1_prob * 100)::numeric, 0));
        elsif v_top1_cat = 'regional_transport' then
          v_mission_type := 'upwind_downwind_reading';
          v_rationale := 'Automated attribution: evidence suggests a possible regional contribution — an upwind/downwind mobile reading would help confirm this.';
        else
          v_mission_type := 'upwind_downwind_reading';
          v_rationale := 'Automated attribution: no single source clearly dominates — a general upwind/downwind reading would help narrow this down.';
        end if;

        insert into evidence_missions (incident_id, mission_type, status, rationale, public_prompt)
        values (p_incident_id, v_mission_type, 'proposed', 'Automated attribution: ' || v_rationale, v_public_prompt);
      end;
    end if;
  end if;
end $$;

revoke all on function calculate_incident_source_attribution(bigint, boolean) from public;
grant execute on function calculate_incident_source_attribution(bigint, boolean) to authenticated;

-- ============================================================
-- run_incident_source_attribution — the batch driver: every open incident
-- (status <> 'closed') in a city (or every active city when p_city_code is
-- null). Skips an incident recalculated within its own city's configured
-- interval unless p_force. Wired from ingest/app/source_attribution.py,
-- run on the same cron as anomaly detection, after it.
-- ============================================================
create or replace function run_incident_source_attribution(
  p_city_code text default null,
  p_force boolean default false
) returns table (incident_id bigint)
language plpgsql security definer set search_path = public as $$
declare
  v_caller_role user_role;
  r record;
begin
  if auth.uid() is not null then
    select role into v_caller_role from profiles where id = auth.uid();
    if coalesce(v_caller_role, 'citizen') not in ('commander', 'admin') then
      raise exception 'Only a commander or admin may run source attribution.'
        using errcode = 'insufficient_privilege';
    end if;
  end if;

  for r in
    select i.id
    from incidents i
    left join wards w on w.id = i.ward_id
    left join city_config c on c.id = coalesce(i.city_id, w.city_id)
    where i.status <> 'closed'
      and (p_city_code is null or c.city_code = p_city_code)
      and (c.is_active is null or c.is_active)
  loop
    incident_id := r.id;
    perform calculate_incident_source_attribution(r.id, p_force);
    return next;
  end loop;
end $$;

revoke all on function run_incident_source_attribution(text, boolean) from public;
grant execute on function run_incident_source_attribution(text, boolean) to authenticated;

-- ============================================================
-- get_incident_responsible_authority — plan §9 responsibility mapping.
--
-- Read-only, NOT security definer: relies on the CALLER's own RLS, exactly
-- like every other plain view over `incident_source_hypotheses`/
-- `responsibility_registry` — a citizen calling this gets zero rows (both
-- underlying tables already deny them), which is the correct, safe answer,
-- not a special case this function needs to reimplement.
--
-- Never dispatches anything (plan §9's own explicit limit for this phase).
-- Suppresses local routing entirely for a `regional`-classified incident
-- (plan §7's "predominantly regional incidents should not receive local
-- enforcement recommendations").
-- ============================================================
create or replace function get_incident_responsible_authority(p_incident_id bigint)
returns table (
  source_category source_category,
  owner_name text,
  regulating_authority text,
  asset_description text,
  escalation_contact text,
  is_disputed boolean,
  match_basis text,
  routing_confidence double precision,
  note text
)
language sql stable as $$
  with top as (
    select h.source_category, h.probability
    from incident_source_hypotheses h
    where h.incident_id = p_incident_id and h.is_current
      and h.source_category not in ('regional_transport', 'mixed', 'unresolved')
    order by h.probability desc
    limit 1
  ),
  inc as (select * from incidents where id = p_incident_id)
  select
    t.source_category,
    r.owner_name, r.regulating_authority, r.asset_description, r.escalation_contact, r.is_disputed,
    case when r.ward_id is not null then 'ward_and_source' when r.id is not null then 'city_and_source' else 'none' end,
    case
      when inc.classification = 'regional' then 0
      when r.ward_id is not null then 0.6
      when r.id is not null then 0.35
      else 0
    end,
    case
      when inc.classification = 'regional' then 'This incident is classified predominantly regional — local responsibility routing is not applicable.'
      when r.id is null then 'No reliable responsibility-registry match — unresolved jurisdiction.'
      else null
    end
  from top t
  cross join inc
  left join lateral (
    select * from responsibility_registry rr
    where rr.city_id = inc.city_id and rr.source_category = t.source_category
      and (rr.ward_id = inc.ward_id or rr.ward_id is null)
    order by (rr.ward_id is not null) desc
    limit 1
  ) r on true
$$;

revoke all on function get_incident_responsible_authority(bigint) from public;
grant execute on function get_incident_responsible_authority(bigint) to authenticated;

-- ============================================================
-- Seed: Delhi's attribution configuration (city-configurable, per plan §12).
-- Merged into the existing config jsonb, guarded so this is safe to re-run
-- and safe alongside any other key a future migration adds to the same
-- column — mirrors the anomaly_detection seed's own pattern exactly.
--
-- `category_labels` lets the UI show the plan's own literal wording
-- (`traffic_emissions`, `industrial_combustion`) without renaming the
-- underlying `source_category` enum values (`vehicular`, `industrial`) that
-- classify.py and the Phase 5 playbook seed already depend on.
-- ============================================================
update city_config
set config = config || jsonb_build_object(
  'attribution', jsonb_build_object(
    'source_categories', jsonb_build_array('road_dust', 'construction_dust', 'vehicular', 'open_burning', 'industrial', 'regional_transport'),
    'category_labels', jsonb_build_object(
      'road_dust', 'road_dust', 'construction_dust', 'construction_dust',
      'vehicular', 'traffic_emissions', 'open_burning', 'open_burning',
      'industrial', 'industrial_combustion', 'regional_transport', 'regional_transport',
      'mixed', 'mixed', 'unresolved', 'unresolved'
    ),
    'weights', jsonb_build_object(
      'pollutant_signature', 0.35, 'wind_alignment', 0.15, 'gis_proximity', 0.15,
      'temporal_match', 0.05, 'citizen_corroboration', 0.15, 'field_verification', 0.25,
      'regional_pattern', 0.20, 'contradiction_penalty', 0.35, 'data_quality_penalty', 0.20
    ),
    'dust_pm_ratio_min', 2.5,
    'wind_alignment_score', 0.6,
    'wind_max_age_hours', 48,
    -- Reserved for a future per-asset bearing model — this schema has no
    -- per-asset coordinates yet, so wind evidence today is ward-level
    -- presence/absence only, not a true degree-tolerance bearing check.
    'wind_alignment_tolerance_deg', 45,
    'gis_ward_match_score', 0.5,
    'gis_city_match_score', 0.25,
    -- Reserved for the same future per-asset coordinate model as above.
    'gis_proximity_radius_m', 2000,
    'rush_hour_windows', jsonb_build_array(jsonb_build_array(7, 11), jsonb_build_array(17, 21)),
    'rush_hour_score', 1.0,
    'off_peak_score', 0.3,
    'citizen_partial_reports', 2,
    'citizen_full_reports', 3,
    'citizen_partial_score', 0.5,
    'citizen_full_score', 1.0,
    'citizen_verification_boost', 0.2,
    'field_verification_score', 0.9,
    'regional_local_excess_max', 15,
    'regional_min_station_fraction', 0.5,
    'regional_pattern_score', 1.0,
    'regional_penalty_factor', 0.5,
    'readings_freshness_hours', 6,
    'confidence_threshold', 0.45,
    'ambiguity_gap', 0.12,
    'min_total_score_for_resolution', 0.05,
    'recalculation_interval_hours', 6,
    'corroboration_min_env_score', 0.3
  )
)
where city_code = 'delhi'
  and not (config ? 'attribution');

-- ---------- Seed: illustrative Delhi responsibility_registry rows ----------
-- City-wide (ward_id null) only — this repo has no verified per-ward asset
-- data to point at, and inventing specific addresses/officer names would
-- violate the "do not fake integrations" rule the rest of this codebase
-- follows (see docs/DATA_MODEL.md: `deputy_commissioner` is left null for
-- the same reason). `regulating_authority` mirrors the SAME generic agency
-- labels the Phase 5 playbook seed already uses
-- (`responsible_agency_type`), for consistency. `open_burning` is
-- DELIBERATELY left unseeded, so "unresolved jurisdiction" (plan §9) has a
-- genuine, non-contrived demonstration case for Delhi rather than every
-- category always resolving.
insert into responsibility_registry (city_id, source_category, ward_id, asset_description, regulating_authority)
select c.id, v.cat::source_category, null, v.asset, v.authority
from city_config c
cross join (values
  ('road_dust', 'City road network (sweeping, unpaved-shoulder maintenance)', 'Municipal roads/sanitation department'),
  ('construction_dust', 'Registered construction sites (dust-control compliance)', 'Municipal building/construction enforcement'),
  ('vehicular', 'Road network traffic management', 'Traffic police'),
  ('industrial', 'Registered industrial units (emissions consent)', 'State Pollution Control Board / DPCC')
) as v(cat, asset, authority)
where c.city_code = 'delhi'
  and not exists (
    select 1 from responsibility_registry rr where rr.city_id = c.id and rr.source_category = v.cat::source_category
  );
