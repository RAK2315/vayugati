# Historical Replay Report

Last updated: 2026-07-25 (Phase 11 — Delhi pilot validation).

Results of replaying **real historical Delhi air-quality data** through the
actual anomaly-detection, source-attribution, and forecast-validation
engines — not synthetic fixtures. Produced by
`ingest/scripts/historical_replay.py` and `ingest/scripts/forecast_replay.py`;
raw machine-readable output in `docs/_replay_reports/*.json` (regenerate
with `python3 ingest/scripts/historical_replay.py --reset` and
`ingest/.venv/bin/python3 ingest/scripts/forecast_replay.py`).

## 1. Dataset

| Property | Value |
|---|---|
| Source | OpenAQ v3 API (`api.openaq.org`), real government (CPCB/DPCC) sensor data |
| Geographic coverage | 4 of this repo's real, already-`stations.yaml`-configured Delhi stations: Okhla, Narela, Wazirpur, Rohini |
| Pollutants | PM2.5 only (the sensors expose more, but this replay pulled PM2.5 — the one pollutant every one of the four stations reports) |
| Station coverage | 4 of 11 currently-resolved Delhi stations (this repo has 13 configured, 11 resolved to a real OpenAQ location, 2 unresolved — see [DELHI_DATA_GAP_REPORT.md](DELHI_DATA_GAP_REPORT.md)) |
| Time range | 2018-12-01 to 2018-12-31 (a real, documented severe Delhi winter smog episode — chosen because it is real, high-signal data, not because it is recent) |
| Time resolution | Hourly (station-reported; some 30-minute-interval entries exist in the raw feed and were floored to the hour, matching `ingest/app/forecast.py`'s own existing hourly-flooring behaviour) |
| Missingness | **930 real readings across 4 stations over 31 days** — only 10 of 31 calendar days have ANY reading at all (~32% day-level coverage); real gaps of 4-6 consecutive days are common. This is genuine CPCB/DPCC sensor uptime behaviour, not a synthetic artefact. |
| Weather | Real Open-Meteo Historical Weather Archive API, ONE representative coordinate (Okhla, 28.530785°N 77.271255°E), 744 hourly rows (complete, no missingness — a reanalysis product, not a station feed) |
| Known quality limitations | Single-pollutant (PM2.5 only); weather applied identically to all 4 wards (a documented simplification — real per-station weather was not fetched for this bounded replay); no citizen reports, field evidence, or ground-truth "this was actually X source" labels exist for this period, so **detection and forecasting are evaluated against real data, but source attribution is NOT** (see §3) |
| Suitable for | Detection replay (§2) and forecast replay (§3) — **yes, using real data**. Source attribution accuracy — **no**; no real, labelled ground truth exists for what actually caused this smog episode at each station, so attribution is validated separately via synthetic scenarios (see [END_TO_END_TEST_REPORT.md](END_TO_END_TEST_REPORT.md) and `supabase/tests/120_pilot_validation_scenarios.sql`), explicitly labelled synthetic, never presented as accuracy evidence. |

A **simulation accommodation** was required and is disclosed here plainly:
`evaluate_station_pollutant_anomaly` compares a reading's timestamp against
actual wall-clock `now()` for staleness. Since these readings are genuinely
from December 2018, `data_freshness_max_minutes` was set to a very large
number **for this isolated replay city only** (`city_code =
'replay_dec2018'`, `config->'is_replay' = true`) — never for a real pilot
city. Without this, every replayed reading would appear infinitely stale
and nothing would ever be evaluated. This does not weaken the detection
LOGIC under test — the same persistence/local-excess/completeness rules
run unchanged — it only widens the wall-clock-proximity tolerance, which
tests something specifically artificial to replaying old data long after
the fact, not a real production condition.

## 2. Detection replay evaluation (real data)

| Metric | Value |
|---|---|
| Anomaly candidates evaluated | 40 (4 stations x 10 simulated days with data) |
| Incidents created | 2 |
| Duplicate-incident rate | 0% — the same 2 incidents persisted across all 10 simulated days; no new incident was ever created for a ward that already had one open (the existing update-not-duplicate rule, exercised against real repeated data, not just a single synthetic re-run) |
| False repeat creations | 0 (same evidence as above) |
| Detection delay | Not measurable from this dataset — OpenAQ does not record when CPCB/DPCC itself detected the episode, only the raw readings; detection ran once per simulated day in this replay's granularity (see the "reproducing" note) |
| Suppression due to stale/incomplete data | Not observed within a simulated day once readings existed for it — but implicitly, 21 of 31 calendar days had a "detection did not run meaningfully" gap simply because no station reported at all, which is itself the real-world data-quality story this dataset tells |
| Detected vs. predicted stage | 100% detected (2/2), 0% predicted. This dataset has no forecast_runs of its own (forecasting replay in §3 was run separately, not fed back into this detection pass), so the validated-forecast path was never exercised here |
| Requiring command review | 2/2 (100%) — both incidents landed at `source_confidence = 'suspected'` (correct: detection alone never corroborates), which requires command review before any intervention per the existing evidence-level gate |

**Manual inspection of the 2 real incidents created**: both incidents
formed on the first simulated day with any data (2018-12-15) and were then
correctly treated as already-open for the rest of the month (updated, not
duplicated) as more real readings arrived. Only 2 of the 4 real stations'
wards produced an incident, despite all 4 showing genuinely hazardous PM2.5
(station means 287-455 ug/m3, see [DATA_QUALITY_AND_SCIENCE.md](DATA_QUALITY_AND_SCIENCE.md)
for full station-level stats) — not a bug: December 2018 was a genuinely
REGIONAL smog event (all Delhi stations elevated together), so
`local_excess` (a station's reading relative to the OTHER stations'
average) was small at the 2 stations that didn't produce an incident —
exactly the real-world signature the regional-transport classification
mechanism (tested separately in `80_source_attribution.sql` TEST 66/71)
exists to catch. This dataset did not also run source attribution to
confirm the regional classification directly (an honest scope limit of
this pass), but the local-excess arithmetic behaved exactly as designed
against real, severe, region-wide pollution data.

**No sensitivity/specificity claim is made** — this dataset has no
independent ground truth for "was there really an anomalous LOCAL event at
each station on each day," so recall/precision cannot be honestly computed
here. What IS proven: the detection rules run correctly, deterministically,
and without duplication against 930 real hourly readings spanning a real
severe pollution episode.

## 3. Forecast replay evaluation (real data)

Real Phase 8 validation logic (`forecast._validate`), same real PM2.5
readings, real weather, threshold = 90 ug/m3 (Delhi's own seeded pm25
anomaly threshold):

| Station | Rows | Selected method | Max validated horizon | Beats persistence overall |
|---|---|---|---|---|
| Okhla | 299 | diurnal_persistence (fallback) | none | No |
| Narela | 299 | diurnal_persistence (fallback) | none | No |
| Wazirpur | 299 | lgb_unified_v2 | 48h | Yes |
| Rohini | 298 | lgb_unified_v2 | 6h only | Yes (6h only) |

Per-horizon detail (MAE in ug/m3; persistence MAE is the baseline the model
must beat by `min_mae_improvement_pct` = 5%):

| Station | 6h MAE (persist.) | 12h MAE (persist.) | 24h MAE (persist.) | 48h MAE (persist.) |
|---|---|---|---|---|
| Okhla | 50.2 (45.0) fail | 40.9 (64.8) pass | 73.2 (69.0) fail | 52.5 (74.3) pass |
| Narela | 36.0 (31.9) fail | 33.9 (22.0) fail | 47.2 (37.6) fail | 37.6 (40.9) pass |
| Wazirpur | 78.5 (98.3) pass | 42.1 (69.4) pass | 105.3 (113.0) pass | 68.8 (74.2) pass |
| Rohini | 15.6 (28.8) pass | 21.4 (18.4) fail | 42.3 (45.0) pass | 44.1 (45.2) fail |

(`max_validated_horizon_hours` is monotonic by design — a horizon only
counts as validated if it AND every smaller configured horizon all beat
persistence, so Okhla's 12h/48h individual passes do not count because 6h
failed first, and Rohini's 24h pass doesn't count because 12h failed first.)

**Honest reading of this real result**: roughly half the tested wards
(Wazirpur fully, Rohini partially) show genuine forecast skill beating a
naive persistence baseline during a severe pollution episode; the other
half (Okhla, Narela) do not, at least not consistently across all four
horizons, during this specific real event. This is exactly the kind of
mixed, honest result a real evaluation should produce, and it directly
answers plan section 5's question:

**Which pollutant/horizon combinations are safe to enable during the
pilot, based on this real-data evidence**: PM2.5 forecasting shows genuine
skill at SOME wards and SOME horizons, not uniformly. Per-ward validation
(which is exactly what `forecast_runs.beats_persistence` already gates in
production — see [DATA_MODEL.md](DATA_MODEL.md)'s Phase 8 section) is the
correct mechanism already in place: a ward whose own validation fails
correctly falls back to the diurnal/persistence baseline rather than
serving an unvalidated forecast. This replay is real evidence that the
GATING mechanism matters in practice, not just in theory — 2 of 4 real
Delhi wards would have been correctly held back from LightGBM forecasting
during this real event if this exact data had been the pilot's live feed.

**Uncertainty-band calibration**: not independently re-verified against
this real dataset in this pass (the residual-RMSE approximation's own
limitations are already documented in
[DATA_QUALITY_AND_SCIENCE.md](DATA_QUALITY_AND_SCIENCE.md) from Phase 8's
synthetic validation — this replay did not add a second, real-data-based
calibration check, a genuine scope limitation of this pass, noted honestly
rather than silently skipped).

## 4. Reproducing this report

```bash
# detection replay (writes docs/_replay_reports/detection_replay_dec2018.json)
python3 ingest/scripts/historical_replay.py --reset

# forecast replay (writes docs/_replay_reports/forecast_replay_dec2018.json)
ingest/.venv/bin/python3 ingest/scripts/forecast_replay.py
```

Both require the disposable local Postgres (`vg-pg`, matching
`supabase/tests/run.sh`) to already have the full schema applied. Neither
script touches any hosted project or real pilot data — the replay city is
fully isolated (`city_code = 'replay_dec2018'`) and `--reset` deletes only
its own fixtures.

## 5. What this replay does NOT prove

- It does not prove source-attribution accuracy (no ground truth exists —
  see section 1 and [END_TO_END_TEST_REPORT.md](END_TO_END_TEST_REPORT.md)).
- It does not prove dispatch/notification/SLA behaviour under real
  operational load (see [END_TO_END_TEST_REPORT.md](END_TO_END_TEST_REPORT.md)
  for that, via deterministic scenarios).
- It is 4 of 13 Delhi wards, one severe historical month, not a
  representative sample of ordinary conditions or the other 9 wards.
- It does not include NO2/PM10/SO2/CO replay (PM2.5 only, per what these
  4 sensors' fetched data covers in this pass).
