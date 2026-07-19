# Vayu Gati — Data Quality and Scientific Standards

Tracks the plan's §6/§16 requirements against what exists today. Phase 2
added the **schema** hooks for data-quality metadata and evidence-based
outcomes. Phase 6 (`supabase/migrations/20260721000000_anomaly_detection.sql`)
adds the first real detection **logic** built on top of those hooks — see
"Automated anomaly detection (Phase 6)" below for what changed and, just as
important, what is still an honest approximation rather than a validated
scientific standard. Phase 7
(`supabase/migrations/20260722000000_source_attribution.sql`) adds the first
real probable-source **attribution** logic on top of both — see "Attribution:
fused as of Phase 7" below for the same treatment.

## Six-pollutant support

| Pollutant | Column in `readings` | V1 priority (plan §6) |
|---|---|---|
| PM2.5 | `pm25` | Core |
| PM10 | `pm10` | Core |
| NO2 | `no2` | Core |
| SO2 | `so2` | Supporting |
| CO | `co` | Supporting |
| O3 | `o3` | Supporting |

All six columns already existed in the pre-existing `readings` table — no
schema change needed here. `city_config.pollutant_priority` (new in Phase 2)
makes the V1 priority order configurable per city instead of an implicit
assumption (seeded `['pm25','pm10','no2']` for Delhi, matching the plan
exactly). As of Phase 6, `evaluate_station_pollutant_anomaly` genuinely
supports all six pollutants (the CHECK constraint on `anomaly_candidates
.pollutant` and `incidents.primary_pollutant` lists all six) — only PM2.5/
PM10/NO2 are actually *scheduled* to run by default (`run_anomaly_detection`
iterates `city_config.pollutant_priority`, which stays at the Core three for
Delhi), matching the plan's own "prioritise PM2.5/PM10/NO2 for the first
working detection rules" instruction. Adding SO2/CO/O3 for a city is a
one-line `pollutant_priority` config change, not a code change.

## Per-feed data-quality metadata

Plan requirement: every measurement/feed must carry timestamp/freshness,
unit, completeness, source/provider, regulatory/calibrated/indicative
classification, calibration status, reliability/confidence, and an explicit
stale/unavailable state.

**Status: modelled and, as of Phase 6, populated for the detection path.**

- `readings.ts` / `weather.ts` give timestamp/freshness today (age can always
  be computed client-side, and `FieldView`/`CitizenView` already do this via
  `timeAgo()`). `evaluate_station_pollutant_anomaly` now also computes
  freshness/completeness explicitly per station+pollutant evaluation and
  rejects (suppresses) a candidate that fails either — see below.
- `city_connectors.last_sync_at` / `last_sync_status` (Phase 2) give a
  connector-level freshness/availability signal — seeded honestly: OpenAQ and
  Open-Meteo are `ok`, mobility/satellite/GIS are `not_configured` (an
  explicit unavailable state, not a silent gap).
- `stations.sensor_type` (Phase 6, NOT NULL, default `'regulatory'`) is the
  regulatory/indicative/low-cost/unknown classification the plan asks for —
  populated honestly (every currently-seeded Delhi station really is a
  DPCC/CPCB regulatory monitor; a future low-cost network would insert its
  own stations with this set explicitly). Feeds directly into detection
  confidence (see "Automated anomaly detection" below) — not just stored,
  actually used.
- **Still not added**: per-*reading* calibration-status columns (e.g. a
  timestamped calibration record per sensor). `stations.yaml` still has two
  unresolved station ids (R.K. Puram, Mayapuri — "DO NOT GUESS" in that
  file's own comment) with no real calibration data behind them yet; adding
  a guessed column would violate "do not fake integrations" in spirit.

## Incident detection must not fire from one reading

`incidents.detection_method` is `NOT NULL` with no default — every incident
row must name how it was detected (e.g. `citizen_report_cluster`,
`anomaly_persistence_threshold`, `anomaly_trend_projection`, `manual`). This
was a deliberate schema-level nudge from Phase 2, and as of Phase 6 it is
also a real, tested rule, not just a naming convention:
`evaluate_station_pollutant_anomaly` requires persistence across at least
two valid readings (city-configurable) before it will create or update an
incident — a single high reading produces, at most, a stored (non-incident-
linked) `anomaly_candidates` row showing exactly which criteria did and did
not fire. Verified directly (`supabase/tests/70_anomaly_detection.sql`,
test 41).

## Automated anomaly detection (Phase 6)

### What the rule engine actually is

Every threshold, window and projection in
`evaluate_station_pollutant_anomaly` (SQL) is a **stated, documented
constant or a simple linear calculation** — no trained model, no ML
classifier, per the phase's own explicit "do not add ML" instruction. Full
mechanism described in [DATA_MODEL.md](DATA_MODEL.md)'s Phase 6 section;
this section is specifically about the SCIENTIFIC basis (and honest limits)
of the numbers involved.

### Seeded Delhi thresholds — basis and honesty about precision

| Pollutant | Threshold (µg/m³) | Basis |
|---|---|---|
| PM2.5 | 90 | CPCB "Poor" AQI-category entry point — taken **directly** from this repo's own `ingest/app/aqi.py` breakpoint table (`(90, 120, 201, 300)`), not re-derived or guessed. |
| PM10 | 250 | Same source, same category (`(250, 350, 201, 300)` in `aqi.py`). |
| NO2 | 180 | Standard published CPCB "Poor" category entry point. Not encoded anywhere else in this repo (no NO2 breakpoint table exists yet, unlike PM2.5/PM10) — **flagged here as an approximation from general knowledge, not verified against a primary CPCB document in this pass. Needs a domain-expert review before any production/enforcement use.** |
| SO2 / CO / O3 | 380 / 4000 / 180 | Rough, lower-confidence placeholders for the "supporting" tier (plan §1 prioritises PM2.5/PM10/NO2 for the first working rules) — explicitly **not** claimed to be precise. A city operator should review and override these via `city_config.config` before relying on them. |

This table is honest about its own precision on purpose — "never present
expected impact as guaranteed" (the same standard already applied to
playbook cost/time estimates) applies equally to a detection threshold.
Every value is a `city_config.config` entry, not a code constant, precisely
so a domain expert can correct it without a deployment.

### Other seeded parameters (Delhi), and their reasoning

| Parameter | Delhi value | Reasoning |
|---|---|---|
| `persistence_window_readings` / `persistence_min_count` | 3 / 2 | Matches the plan's own literal example rule ("persists for at least two valid readings"); window of 3 gives one point of slack for a single missed hourly ingest. |
| `local_excess_min` | 20 µg/m³ | A round, defensible "meaningfully above background" bar — smaller than the smallest AQI category width (50 µg/m³ for PM2.5's worst band) so it doesn't require an implausibly large excess to register, larger than plausible sensor noise. |
| `nearby_station_radius_m` | 5000 | Generous on purpose: Delhi's actual station density is sparse (13 configured stations city-wide, 2 with no resolved OpenAQ id — see `ingest/stations.yaml`), so a tight radius would leave `nearby_station_diff` null for nearly every station. Documented as a real, current limitation below, not hidden. |
| `data_completeness_min` | 0.5 | At least half the expected window must be valid — tolerates one missed hourly reading out of three without suppressing a genuine signal. |
| `data_freshness_max_minutes` | 180 | Three missed hourly ingest cycles = treat the station as possibly offline, not still "live." |
| `prediction_horizon_hours` | 6 | A "predicted" (not yet crossing) signal must be projected to cross within this window — long enough to be operationally useful (time to dispatch evidence-gathering), short enough that the linear trend projection hasn't had time to become nonsense. |
| `dedup_window_hours` | 12 | Matches `link_report_to_incident`'s own `p_recency_hours` default (12h) — the same "how long is this still plausibly the same event" judgement, applied consistently across both detection paths. |

### Honest scientific limitations of this pass

- **Thresholds are AQI-category boundaries, not health-effect or
  intervention-efficacy thresholds.** They mark "this is unusually bad air,"
  not "this specific level requires this specific response" — that mapping
  is what `intervention_playbooks.min_evidence_level` and the evidence-level
  gate are for, unchanged by this phase.
- **The trend projection is a single linear extrapolation over 2-3 points**,
  not a fitted trend line, not weather-adjusted, and does not account for
  diurnal pollution cycles the way `forecast.py`'s LightGBM model already
  does for PM2.5. It is deliberately simple and stated as such — a real
  forecasting model for anomaly prediction specifically (as opposed to the
  existing PM2.5 48h forecast) is future work, not this phase's job.
- **`local_excess`'s "background baseline" is the average of every other
  currently-reporting station in the city right now** — a real-time
  cross-sectional baseline, not a historical seasonal/diurnal baseline the
  way `forecast.py`'s `local_excess` (ward vs. trailing city median) is.
  These are two different, both-legitimate notions of "excess" computed by
  two different parts of this system; they are not reconciled or compared
  against each other in this pass.
- **Sparse station coverage limits `nearby_station_diff` and even the
  city-wide baseline itself.** With as few as 1-2 stations reporting at any
  given moment (2 of 13 configured Delhi stations have no OpenAQ id at all —
  unresolved since Phase 1, see `ingest/stations.yaml`), a "city-wide
  average of other stations" can be a single station's value, not a
  meaningful aggregate. The system never fabricates a value when no other
  station is reporting (`local_excess`/`nearby_station_diff` are `null`,
  not zero), but a null-safe computation is not the same as a
  statistically sound one at this coverage level.
- **`data_completeness` counts valid readings within the last N pulled
  rows, not against a true expected-cadence calendar model.** A station
  that reports 3 readings spread across 30 hours (instead of the intended
  hourly cadence) can still show `completeness = 1.0` if all 3 happen to be
  valid — the separate `data_freshness_minutes` check catches the "station
  went fully silent recently" case, but a station reporting sporadically
  (not silent, just sparse) is not fully modelled. No per-city ingest-cadence
  configuration exists yet to compare against.
- **No PostGIS, no true geodesic distance** — `nearby_station_diff` uses the
  same equirectangular approximation `link_report_to_incident` already
  relies on, accurate at the few-kilometre scale this operates at, not
  beyond it.
- **Regulatory-vs-indicative sensor weighting (the 1.0/0.7/0.6/0.5
  confidence multipliers) is a stated, documented judgement call, not a
  calibrated instrument-uncertainty model.** No city in this system
  currently has any indicative/low-cost sensors deployed (`sensor_type`
  defaults to `'regulatory'` for every real seeded station) — this signal
  exists and is tested (`supabase/tests/70_anomaly_detection.sql` test 46),
  but is unexercised by real data today.

## Forecast validation (already good practice, unchanged)

`ingest/app/forecast.py` already does two things the plan asks for:
compares against a persistence baseline and logs RMSE, and tags
`model_version` so a placeholder-model forecast is distinguishable from a
trained one (`ForecastChart.tsx` already reads this: `isPlaceholder =
model_version?.startsWith('diurnal')`). This predates this migration and was
not changed — flagged here as a good existing pattern to keep extending
(MAE/bias/severe-event-recall/false-alarm tracking per plan §16 is not yet
computed anywhere; only RMSE is logged today, server-side, not surfaced in
the UI).

## Attribution: fused as of Phase 7 — and honest about what "fusion" means here

`ingest/app/attribution.py` still computes exactly one thing, unchanged: which
wind sector is statistically associated with the current pollution load per
ward (the pollution-rose method, `pollution_rose_v1`). Phase 7 adds a SEPARATE,
second attribution mechanism —
`calculate_incident_source_attribution()` (SQL,
`supabase/migrations/20260722000000_source_attribution.sql`) — which is what
actually fuses the plan's own listed evidence types into
`incident_source_hypotheses`: pollutant signatures/ratios (PM10:PM2.5,
NO2+CO, PM2.5+CO, SO2+NO2), a coarse ward-level proxy for spatial
movement/proximity to known source types (`responsibility_registry` +
`attributions`'s own wind direction), a coarse time-of-day proxy for
vehicular activity, citizen/field evidence, and (via the anomaly-detection
engine's own `local_excess`) a genuine, already-computed basis for
regional-vs-local. These two attribution mechanisms are NOT reconciled with
each other — `attribution.py`'s wind-sector rose is a ward-wide, always-on
background signal; `calculate_incident_source_attribution` is a per-incident,
on-demand/scheduled scoring engine. A future pass could feed the wind rose's
own `direction`/`confidence` into the incident engine's `wind_alignment`
factor directly (today the incident engine reads `attributions.direction`
itself, but only as a presence/absence check, not the rose's magnitude or
confidence) — flagged here as real, honest follow-up work, not claimed done.

**What "fusion" does NOT mean here, stated as plainly as this document states
every other limitation:**

- **Not chemical source apportionment.** A PM10:PM2.5 ratio, or an NO2+CO
  co-elevation, is a coarse, literature-informed heuristic threshold — not a
  receptor model, not a chemical mass-balance calculation, and not validated
  against any real source-apportionment study for Delhi or any other city.
  The exact ratio/threshold values (`dust_pm_ratio_min = 2.5`, and reusing
  anomaly detection's own AQI-category pollutant thresholds as the
  "elevated" bar) are stated, documented, city-configurable constants, the
  same honesty standard already applied to every anomaly-detection threshold
  above.
- **Not ML, and no ML was added.** Every score is a deterministic, stated
  weighted sum of named factors (`evidence_scores` stores each factor AND
  the exact weights snapshot used) — reproducible and auditable by
  construction, per the plan's own explicit requirement, and re-verified
  directly (`supabase/tests/80_source_attribution.sql` test 73: identical
  inputs produce an identical result across repeated recalculations).
- **GIS proximity is ward-level, not a metric distance.** This schema has no
  per-asset (road/construction-site/factory) coordinates — only
  `responsibility_registry.ward_id`, a coarse "is a source of this category
  registered in this ward at all" signal. `gis_proximity_radius_m` and
  `wind_alignment_tolerance_deg` are seeded in `city_config` as **reserved,
  not-yet-applied** placeholders for a future per-asset coordinate model —
  stated as reserved rather than silently pretending they already govern a
  real distance/bearing calculation.
- **Wind "alignment" is presence/absence, not a bearing check.** The engine
  checks "is the wind-rose data fresh, AND is a known source of this
  category registered in this ward" — it does NOT compute whether the wind
  is actually blowing FROM that registered source's direction TOWARD the
  incident, because no per-asset location exists to compute a bearing
  against in the first place.
- **No construction-operation or industrial-operation telemetry exists, and
  none was invented.** The one place a genuine temporal signal exists
  (vehicular activity, via a configured rush-hour window checked against
  the incident's own detected time, in the city's own timezone) is used;
  every other category's temporal-match factor is recorded as MISSING
  evidence, not defaulted to zero-and-silent.
- **One citizen report never corroborates a source, by construction.**
  Verified directly (test 62: a single linked report scores zero
  citizen-corroboration evidence, and the fact that only one report exists
  is itself recorded in `missing_evidence`). Two or more independent
  reporters add real, partial evidence (test 63) — matching Phase 3's own
  "two independent reports" corroboration rule for the incident-level
  evidence tier, now applied per-category here too.
- **A field-inspection result is mapped back to a category through the
  ORIGINATING MISSION'S TYPE**, not a per-evidence-row category tag (no such
  tag exists in this schema) — a coarse, documented mapping
  (`construction_check` → construction_dust, `traffic_count` → vehicular,
  `source_status_check` → industrial/open_burning,
  `upwind_downwind_reading`/`mobile_sensor_route` → regional_transport,
  `field_photo` → road_dust), stated as coarse rather than claimed precise.
- **`officially_verified` is never set by the rule engine, and a
  category already at that level is never touched again by a later
  recalculation** (test 69) — plan §5/§6's own explicit requirement.
  Verification stays exclusively an authorised human action (the existing
  Phase 3 officer-confirmation flow), unchanged by this phase.
- **Responsibility routing never dispatches anything.** For a
  `regional`-classified incident, local routing is suppressed entirely
  (`routing_confidence = 0`, an explicit note) rather than pointing at a
  local agency that cannot meaningfully act on a regional contribution
  (test 71) — the plan's own explicit "predominantly regional incidents
  should not receive local enforcement recommendations".

## Uncertainty and model metadata

Plan requirement: forecast and attribution outputs must include uncertainty
and model/version metadata. `forecasts.confidence` and
`attributions.confidence` already existed; `model_version` already existed on
`forecasts` only. `incident_source_hypotheses.model_version` extends this
pattern to source hypotheses, now genuinely populated
(`attribution_rule_engine_v1`) rather than only schema-ready — every
hypothesis row also carries its own `evidence_scores` (the factor breakdown
AND the exact weights snapshot used), so a future weight change never makes
an OLDER calculation's rationale unintelligible.

## Never present AI probability as fact

`incident_source_hypotheses.confidence_level` uses the required
`source_confidence_level` enum (`suspected` / `corroborated` /
`officially_verified`) as a **separate column from** `probability` (a raw
0–1 number). As of Phase 7, the UI-side rule is now implemented, not just
schema-ready: `SourceAttributionPanel.tsx` labels every result with the
fixed disclaimer `"Probable source — not a confirmed violation."`
(`PROBABLE_SOURCE_DISCLAIMER`), shows `confidence_level` and `probability`
as two visually distinct facts (a labelled evidence-tier badge plus a
percentage bar, never merged into one number), and always shows
`supporting_evidence`/`contradicting_evidence`/`missing_evidence` alongside
the probability rather than the number alone.

## Operational vs. environmental verification

`action_evidence` (operational proof: GPS/timestamp/checklist/photo/etc.) and
`impact_evaluations` (environmental outcome: before/after, weather-adjusted,
comparable location, citizen confirmation, recurrence window) are two
separate new tables, deliberately not one. `impact_evaluations.outcome`
defaults to `inconclusive` — the schema cannot represent "we didn't check but
assume it worked"; every row must pick one of the seven real outcome states,
and the default is the honest one. No code writes to either table yet (see
[IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md)).

## Unified forecasting (Phase 8)

### Model inputs

`ingest/app/forecast.py`'s feature set, per ward+pollutant, all real and
already-available in this codebase (plan's own "do not invent unavailable
traffic or satellite data" — none is used):

| Input | Source |
|---|---|
| Pollutant lags (1h, 24h) | This ward's own recent `readings` history. |
| Local excess (the modelling TARGET itself) | Ward value − city-wide median at the same hour, unchanged methodology from the original PM2.5-only forecast. |
| Nearby-station reading | `city_avg_lag1` — the city-wide mean value at t−1 across every OTHER ward, a genuine spatial signal. |
| Weather: temperature, humidity, wind speed, wind direction (sin+cos), rainfall | Historical, from `weather` (already ingested from Open-Meteo). |
| **Weather forecast** | A genuine Open-Meteo **hourly forecast** fetch (`open_meteo.get_hourly_forecast`, new in Phase 8) — distinct from `get_current`'s single now-reading. Used at every step of the recursive multi-hour forecast instead of assuming today's weather persists unchanged for two days. |
| Hour of day, day of week, month | Calendar features — month is a deliberately simple proxy for Delhi's stubble-burning winter seasonality; no explicit "season" taxonomy is invented beyond it. |

Deliberately **not** used: traffic counts, satellite imagery, mobility
data — none exist anywhere in this codebase's data model (`city_connectors`
marks mobility/satellite as `not_configured`, honestly, since Phase 2).

### Validation methodology — time-based, never random

Every generation is validated with a **chronological holdout** (the last
portion of history, in time order — never a random sample; plan's own
explicit requirement, and the literal reason a random split would be
scientifically wrong here: a pollutant time series is autocorrelated, so a
random split leaks future information into "training" via adjacent hours).

The holdout is not scored by asking the model to predict one hour ahead
using the TRUE preceding values (which would silently leak information a
real future forecast could never have) — it is scored by **recursively
re-simulating the exact same procedure used for real future forecasts**,
starting from the split point, using only data available at that point and
the model's own prior predictions as subsequent lag inputs. This is what
makes the backtest an honest simulation of what the model actually knew,
not an inflated best case.

At each of the four supported horizons (6h, 12h, 24h, 48h), the recursive
forecast trajectory is compared against: a flat **persistence** baseline
(last known value carried forward) and a **seasonal/hourly (diurnal)**
baseline (mean value for that hour-of-day, from training data only). Five
metrics are computed per horizon: **MAE**, **RMSE**, **bias** (mean signed
error — positive means systematic over-prediction), **threshold recall**
(of the holdout hours that genuinely crossed the ward's configured
threshold, what fraction did the forecast also flag — `None`, never a
fabricated 0, when no real crossing occurred to score against),
**false-alarm rate** (of the hours the forecast flagged as crossing, what
fraction didn't actually cross), plus **data completeness** (valid readings
present ÷ expected, over the training window).

**A horizon is only ever marked "validated" if the model's MAE beats
persistence by at least the city's configured margin
(`min_mae_improvement_pct`, Delhi: 5%) — AND every smaller configured
horizon has also beaten persistence.** This is deliberately conservative:
a model that wins at 24h but loses at 6h is reported as *not* validated to
24h, because `max_validated_horizon_hours` is monotonic by construction.
"A model must not be marked production-ready unless it beats persistence"
is enforced exactly here, and stored as `forecast_runs.beats_persistence`/
`max_validated_horizon_hours` — a checked fact on every single generation,
not a one-time claim.

Below `MIN_TRAIN_ROWS` (10 days of hourly history) or when LightGBM itself
isn't beating persistence on the holdout, the pipeline falls back to the
diurnal/persistence blend — the exact same honest degradation the original
PM2.5-only forecast already did, now formalised with a stored `method` and
`data_quality_status` rather than being an implicit code path.

### Uncertainty range — a stated approximation, not a quantile model

`lower_bound`/`upper_bound` are computed as the point prediction ± 1.28×
the validated run's own holdout RMSE at the longest horizon (`UNCERTAINTY_Z
= 1.28`, an ~80% interval under a normal-residual approximation). This is a
simple, honestly-labelled choice — **not** a quantile-regression model or a
calibrated prediction interval — chosen because a full quantile model would
be exactly the kind of added ML complexity the phase's own brief asks to
avoid, while a residual-based band is still meaningfully better than no
uncertainty information at all.

### Fixed backtest dataset

`ingest/tests/test_forecast.py` validates the metric formulas (MAE/RMSE/
bias/threshold-recall/false-alarm-rate) against hand-computed values, the
chronological-split behaviour against a constructed series with an
unmistakable holdout-only outlier tail, the monotonic beats-persistence
gating, the LightGBM-vs-diurnal fallback decision under both a
low-noise/learnable and a flat/uninformative signal, and a full `run()`
end-to-end pass — every one of these against a **fixed, seeded**
(`RNG_SEED = 20260723`) synthetic dataset, never live OpenAQ/Open-Meteo
data, mirroring this repo's own SQL-test convention of fixed sample rows
applied to the one part of this phase that has to live in Python.

### Honest limitations

- **`min_mae_improvement_pct = 5` and the horizon set (6/12/24/48h) are
  stated, defensible choices, not derived from a formal power analysis** —
  a genuinely rigorous minimum-detectable-improvement threshold would need
  historical forecast-error variance data this system doesn't have yet.
- **The uncertainty band is a residual-RMSE approximation** (see above),
  not a calibrated interval — it will typically be too narrow in genuinely
  unusual conditions and too wide in very calm ones, the known failure mode
  of assuming normally-distributed, homoscedastic residuals.
- **"Nearby station reading" is a city-wide average, not a true spatial
  interpolation** — at Delhi's current sparse station density (2 of 13
  configured stations still unresolved), this can be a small handful of
  stations' average, same caveat already stated for anomaly detection's own
  `local_excess`/`nearby_station_diff`.
- **The recursive multi-step forecast compounds its own errors** — a wrong
  prediction at hour 3 becomes part of the lag input for hour 4, same as
  the original PM2.5-only forecast; this is inherent to any recursive
  (as opposed to direct-multi-horizon) forecasting approach and is exactly
  why validation is measured at the ACTUAL horizons of interest rather than
  assumed from 1-step accuracy.
- **PM10/NO2 forecasting reuses the identical pipeline and thresholds
  methodology as PM2.5**, with no pollutant-specific tuning — "add PM10
  where sufficient data exists, keep NO2 optional/supporting" is satisfied
  by the SAME `MIN_TRAIN_ROWS` bar and `beats_persistence` gate applying
  per pollutant independently, not by a separate, more lenient bar for the
  newer pollutants.

### A note on model persistence (Phase 10, backup/recovery relevance)

The LightGBM model is **retrained from scratch on every scheduled run** —
never serialized to disk or Storage, never loaded from a prior run. There is
no model artefact to back up, version-pin, or ever "corrupt" — a bad
forecast run is fully explained by (and fixed by) the input data quality at
that run, not by a stale or damaged model file. This is a deliberate
simplicity choice appropriate to this system's retraining cadence, not an
oversight; see [BACKUP_AND_RECOVERY.md](BACKUP_AND_RECOVERY.md) for the
operational consequence.

## Real-data validation (Phase 11 historical replay)

Everything above was validated against synthetic, hand-constructed test
data. Phase 11 additionally replayed **real** OpenAQ v3 + Open-Meteo Delhi
data (December 2018, 4 real stations — Okhla, Narela, Wazirpur, Rohini —
930 real hourly PM2.5 readings, a real, documented severe winter smog
episode) through the actual detection and forecasting engines. Full
detail, tables, and reproduction commands in
[HISTORICAL_REPLAY_REPORT.md](HISTORICAL_REPLAY_REPORT.md); summarized
here because it materially confirms or corrects several of this
document's own claims:

- **Detection**: 40 candidates evaluated, 2 incidents created, 0
  duplicates. Only 2 of the 4 real stations produced an incident despite
  all 4 showing genuinely hazardous PM2.5 (station means 287-455 ug/m3) —
  not a bug: this was a genuinely REGIONAL event (all Delhi stations
  elevated together), so `local_excess` was correctly small at the other
  2 stations. This is real, positive evidence that the local-excess-gated
  detection design (documented above) behaves exactly as intended against
  a genuinely regional signal, rather than over-triggering local
  enforcement inappropriately.
- **Forecasting**: real skill exists at some wards/horizons and not
  others during this real event — Wazirpur beat persistence at all 4
  horizons, Rohini only at 6h, Okhla and Narela never did. This is
  concrete, real-world confirmation that the `beats_persistence` gate
  (§"Unified forecasting (Phase 8)" above) is not a theoretical
  safeguard — 2 of 4 real Delhi wards would have been correctly held back
  from LightGBM forecasting and fallen back to the diurnal baseline if
  this exact real data had been the pilot's live feed.
- **Missingness is real and substantial**: only 10 of 31 calendar days in
  this real dataset had ANY reading at all from a given station (~32%
  day-level coverage), with genuine 4-6+ consecutive-day gaps — this is
  actual CPCB/DPCC sensor uptime behaviour, not a synthetic artefact, and
  materially reinforces the "sparse monitoring limits neighbourhood-level
  inference" caveat stated throughout this document.
- **Source attribution was NOT validated against this real data** — no
  labelled ground-truth exists for "what actually caused this smog
  episode," so attribution accuracy remains validated only via synthetic,
  explicitly-labelled scenarios (`supabase/tests/80_source_attribution.sql`,
  `120_pilot_validation_scenarios.sql`). This is a structural limitation
  of the domain (no dataset anywhere provides this ground truth for
  Delhi), not a gap specific to this codebase, and is stated plainly
  rather than worked around with a fabricated accuracy claim.
- **Uncertainty-band calibration was not independently re-verified**
  against this real dataset — the residual-RMSE approximation's own
  known limitations (above) were not re-tested with a second, real-data
  calibration check in this pass; noted honestly as a scope limit, not
  silently skipped.

See [PILOT_READINESS_REPORT.md](PILOT_READINESS_REPORT.md) section 7 for
the concise, pilot-facing scientific sign-off statement this evidence
supports.
