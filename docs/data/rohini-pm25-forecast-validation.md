# Rohini PM2.5 Forecast Validation

**Type:** Live validation + evaluation-mode dry-run. No migrations, no RLS changes, no UI changes, no code changes, no destructive operations, no existing readings touched. No manual database write was made (see §5 for why). `OPENAQ_API_KEY` not used this pass; nothing printed or logged.
**Date:** 2026-07-21
**Follows on from:** [`openaq-backfill-forecast-readiness.md`](openaq-backfill-forecast-readiness.md) (34 stations, PM2.5-ready, Rohini recommended as first target)

---

## 1. Executive summary

**PM2.5 forecast MVP is already operational for Rohini — not hypothetically, but demonstrably, right now, in production.** This dev environment shares the same live Supabase project the deployed Render ingest service writes to, and that service has been running `forecast.py`'s scheduled job independently, roughly hourly, for the last ~2 days. Its 55th and most recent run (07:25:20 UTC today) **validated a real LightGBM model to the 24h horizon** and wrote it to `forecasts`/`forecast_runs` — that exact forecast (48 hourly points, PM2.5 predictions 9.4–19.8 µg/m³, confidence 0.6) is what `Analytics`/`Map` would already be reading if a user opened them right now.

The more nuanced, evidence-backed answer to "does it work": **yes, but not every run.** Across the full 55-run production history, LightGBM was selected 7 times (12.7%) and the conservative diurnal-persistence fallback 48 times (87.3%) — because the pipeline's validation gate requires the model to beat a plain persistence baseline at *every* horizon from the shortest up, and Rohini's actual short-horizon (6h) PM2.5 swings are volatile enough that this fails more often than it passes. This is the pipeline working as designed, not a defect — it would rather ship a safe, unglamorous diurnal forecast than a numerically-worse "smart" one.

**One real finding worth flagging**: a same-hour-yesterday baseline (not implemented in `forecast.py` itself) beat *every other method, including LightGBM*, at the 6h and 12h horizons in this audit's own holdout test (§6). The pipeline's chosen gate baseline (persistence) is not the strongest simple baseline available for Rohini at short horizons — a real opportunity for a future pass, not something changed here.

## 2. Is PM2.5 forecast MVP operational?

**Yes.** Confirmed three independent ways in this pass:
1. A pure dry-run of `forecast.py`'s own per-ward computation function, called directly (zero DB writes), ran to completion without error using real Rohini data and the exact production data-assembly path.
2. The live `forecasts` table already has 48 real, current rows for Rohini/pm25, generated 25 minutes before this audit began, by a process this audit did not trigger.
3. 55 real historical `forecast_runs` rows for Rohini/pm25 spanning ~2 days, `data_quality_status='ok'` in 53 of 55 (the other 2 were from the service's very first two minutes online, before any real data existed — not a current issue).

## 3. Did Rohini train real LightGBM or fall back?

**Both — depending on which run you look at, and that's the honest, complete answer.**

| | Count | % |
|---|---|---|
| `lightgbm` (validated, beat persistence at every horizon up to the validated one) | 7 | 12.7% |
| `diurnal_persistence` (fallback — LightGBM either wasn't attempted or failed the gate) | 48 | 87.3% |
| **Total runs** | **55** | |

The **most recent run** (id=1491, generated `2026-07-21T07:25:20Z`) is `lightgbm`, validated to **24h**. The **most recent 5 consecutive runs** before this audit (04:25→07:25) were all `lightgbm` — a real winning streak, not a fluke — but the run pattern before that (00:25→03:25, four consecutive runs) was all `diurnal_persistence`. This flips over hours, not days, because both the 30-day training window and the 48h validation holdout slide forward with every run (hourly retraining, per `city_config.forecasting.retraining_frequency_hours: 24` intended cadence — the observed ~hourly cadence in the data is more frequent than that config value states, worth a note but not this audit's scope to reconcile).

**This audit's own dry-run** (run manually at `07:43`, ~20 minutes after the live 07:25 run, using 2 more hours of live-ingested data) landed on `diurnal_persistence` — the model was still trained and evaluated, but failed the 6h-horizon gate by a narrow margin (see §5, §6). This is not a contradiction with the live system; it's the same volatility the 55-run history already shows, caught mid-flip.

## 4. Training window, row counts, missing-hour rate (this audit's dry-run)

| | Value |
|---|---|
| Training period | `2026-06-21T08:00:00Z` → `2026-07-21T06:00:00Z` (30 days, matching `run()`'s hardcoded `hours=24*30`) |
| Continuous hours in window (`n`, the value checked against `MIN_TRAIN_ROWS`) | 719 |
| Real (non-interpolated) PM2.5 observations in that window | 634 |
| Missing-hour rate in the training window | **11.8%** (85 of 719 hours interpolated — matches the `openaq-backfill-forecast-readiness.md` audit's own 634/720 finding almost exactly, confirming both audits agree) |
| `MIN_TRAIN_ROWS` threshold | 240 (~10 days) — cleared with **3x margin** |
| `data_completeness` (as computed by `forecast.py` itself) | 1.0 (its own metric measures actual-vs-reindexed-span completeness *after* the `_ward_series` gap-fill, which is why it differs from this audit's raw missing-hour rate — both are legitimate, they're just measuring different things) |
| `data_quality_status` | `ok` |

The most recent live production run (id=1491) trained on 717 continuous hours ending `2026-07-21T04:00:00Z` — 2 hours earlier than this audit's manual run, entirely explained by the live-ingest gap between the two runs.

## 5. Why no manual database write was made

The task anticipated a possible write and asked for exact table/row reporting if one happened. **None was made, deliberately** — not because writing was unsafe in principle (`db.replace_forecasts(ward_id, pollutant, rows)` is scoped and idempotent, exactly the pattern already trusted throughout this project), but because:

- A live, unrelated production process already writes here on its own schedule, independent of this audit.
- The most recent live write (25 minutes before this audit started) is *better* than what a manual write would have produced at the time this audit ran (live: `lightgbm`, validated to 24h; this audit's own dry-run: `diurnal_persistence`, unvalidated) — overwriting a validated LightGBM forecast with a manually-triggered fallback one would have been a regression, not a contribution.
- `run()` itself doesn't support ward/pollutant targeting — calling it directly to "just do Rohini" would have retrained and rewritten forecasts for every ward and every enabled pollutant (`pm25`, `pm10`, `no2`) across the whole city, far outside this task's scope, and racing against the same live scheduled job.

**No table was written to by this audit.** `forecasts` and `forecast_runs` were only read.

## 6. Baseline comparison

Two comparisons, both real, from two different points in time (the flip described in §3 happening between them):

### This audit's dry-run holdout (`2026-07-19T07:00Z` → `2026-07-21T06:00Z`, 48h)

| Horizon | LightGBM MAE | Persistence MAE | Diurnal MAE | Same-hour-yesterday MAE | Rolling-24h-avg MAE | Winner |
|---|---|---|---|---|---|---|
| 6h | 10.01 | 8.97 | 12.40 | **7.80** | 10.29 | Same-hour-yesterday |
| 12h | 11.97 | 14.06 | 14.41 | **7.64** | 13.63 | Same-hour-yesterday |
| 24h | 12.53 | 15.74 | 13.90 | 13.85 | 13.33 | **LightGBM** |
| 48h | 10.03 | 14.70 | 11.58 | 13.98 | 10.80 | **LightGBM** |

(MAE in µg/m³ PM2.5, all methods evaluated against the identical actual holdout values.)

### Live production run id=1491 (`training_period_end=2026-07-21T04:00Z`)

| Horizon | LightGBM MAE | Persistence MAE | Beats persistence |
|---|---|---|---|
| 6h | 9.87 | 11.35 | **YES** |
| 12h | 10.54 | 12.65 | **YES** |
| 24h | 11.16 | 12.52 | **YES** |
| 48h | 10.22 | 9.68 | no (by 5.6%) |

→ Validated to **24h** (all horizons up to and including 24h passed; 48h's narrow miss doesn't retroactively invalidate the shorter ones, but per the monotonic rule it can't extend validation *past* 24h either).

**Takeaway:** LightGBM's edge over persistence is real but not large (typically 10-20% MAE improvement when it wins), and it's the 6h horizon specifically that's the swing vote for whether the whole model gets promoted or falls back — in this audit's holdout, persistence itself only barely beat LightGBM at 6h (8.97 vs 10.01), but a genuinely simple same-hour-yesterday heuristic beat *both* by a wider margin at both 6h and 12h. `forecast.py` doesn't currently consider same-hour-yesterday as a candidate baseline or gate — worth a future look, not changed here.

## 7. Forecast accuracy / trust metrics (from the current live forecast, run id=1491)

| | Value |
|---|---|
| Method | `lightgbm` (`lgb_unified_v2`) |
| Max validated horizon | 24h |
| Confidence (stored, used by the UI) | 0.6 |
| Residual std (RMSE at 48h from the same validated run, used for uncertainty bounds) | 12.48 |
| Sample predicted values (this run's actual output) | `2026-07-21T05:00Z`: 9.4 µg/m³ (range 0–25.4) → `2026-07-23T04:00Z`: 19.8 µg/m³ (range 3.8–35.8) |
| `beats_persistence` (stored flag) | `true` |

## 8. Known limitations

1. **Model selection is volatile run-to-run**, not a stable per-ward property — a consumer of `forecasts` (Analytics, Map) will sometimes see a validated LightGBM prediction and sometimes a diurnal-persistence one for the identical ward, with no visible signal in the UI today distinguishing which (the `model_version` column carries this, but nothing surfaced confirms whether the current dashboard surfaces it).
2. **Same-hour-yesterday outperforms the model at short horizons** in this audit's own test (§6) — the pipeline's persistence-only gate may be too easy to pass at some horizons and too hard at others relative to a stronger available baseline.
3. **The observed retraining cadence (~hourly) doesn't match `city_config.forecasting.retraining_frequency_hours: 24`** — either the config value is aspirational/unused, or a different scheduler setting governs actual cadence. Not investigated further; flagged for whoever owns the scheduling config.
4. **This audit did not investigate any ward besides Rohini** — the 12.7% historical LightGBM-selection rate is Rohini-specific, not necessarily representative of the other 33 stations.

## 9. Exact next step

**Extend this same validation to 2–3 more hotspot-ward stations** (e.g., the technical runners-up from the readiness audit — CRRI Mathura Road, Sirifort — or another original hotspot ward like Narela or Mundka) using the identical method: call `_forecast_ward_pollutant()` directly (no writes), pull each ward's own `forecast_runs` history if it already has one, and characterize its own LightGBM-selection rate. This tells whether Rohini's ~13% rate is typical or an outlier before drawing any city-wide conclusion about "how often does the ML model actually run." No code change is needed for this — it's the same read-only pattern used here, just pointed at different `ward_id` values.

---

## 10. Checks

| Check | Result |
|---|---|
| `ingest` Python tests (`pytest`) | **37 passed** (no code changed this pass; run as a sanity check per the task's instructions) |
| Typecheck / build | Not run — no code was changed |
| Secret scan | No dedicated scanner installed; manual grep for `SUPABASE_SERVICE_ROLE_KEY=`, `OPENAQ_API_KEY=`, JWT/`eyJ...` across this report and the two analysis scripts used this pass — no matches |
| Database writes | **None** — `forecasts` and `forecast_runs` were read only; no table was written to by this audit (§5 explains why) |
