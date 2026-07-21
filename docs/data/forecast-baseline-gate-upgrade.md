# Forecast Baseline Gate Upgrade

**Type:** Code change (`ingest/app/forecast.py` + its test suite only) + dry-run validation. No migrations, no RLS changes, no UI changes, no manual database write, no API keys exposed. Backward-compatible by construction — verified against the actual schema constraint and the actual UI consumer, not assumed.
**Date:** 2026-07-21
**Follows on from:** [`rohini-pm25-forecast-validation.md`](rohini-pm25-forecast-validation.md) (found same-hour-yesterday beat both persistence and LightGBM at short horizons for Rohini)

---

## 1. What changed

`forecast.py`'s validation gate used to ask one question: *does the model beat flat persistence?* It now asks a harder one: *does the model beat the best of four baselines* — persistence, diurnal (hour-of-day average), same-hour-yesterday (seasonal-naive), and a 24h rolling average?

Concretely, in `_validate()`:
- Two new baseline functions: `_same_hour_yesterday_baseline()` and `_rolling_average_baseline()`, both causally correct (every value they use for reference always comes from before the forecast's own start, never from data that wouldn't exist yet at real generation time — see §2 for why this took care to get right).
- Each horizon's metrics now record all four baselines' MAE, which one was strongest (`best_baseline`), and its MAE (`best_baseline_mae`) — all new, additive `validation_metrics` jsonb keys.
- The `beats_persistence` field (per-horizon and top-level) now means "beat the strongest of the four," not just "beat persistence." This is a **strictly harder bar** — see §6 for why that makes it backward-compatible rather than a breaking change.

**Not changed:** `forecast_runs.method` still only ever stores `'lightgbm'` or `'diurnal_persistence'` (the column has a database-level `CHECK` constraint restricting it to exactly those two values — introducing a third would need a migration, which this task explicitly said to avoid unless required). The four-baseline comparison decides *whether* LightGBM gets promoted, not a new label for what wins.

## 2. Why same-hour-yesterday matters (and why it's non-trivial to get right)

Confirmed directly in the prior Rohini validation: a same-hour-yesterday baseline beat both persistence *and* LightGBM at the 6h and 12h horizons. Persistence (flat at the last known value) can't represent a daily cycle at all; same-hour-yesterday can, for free, with no training.

The subtlety: a naive `value[t - 24h]` lookup is **not causally valid for every horizon**. For a 30-hour-ahead forecast, "yesterday, same hour" relative to the *target* time is only 6 hours after the forecast was *generated* — i.e., in the future relative to what a real forecast could know. The implementation here instead tiles the **last known 24 hours** forward across the full 48h horizon (`_same_hour_yesterday_baseline`), so hour 30's reference is hour 6 of that same tile — always drawn from data that existed before generation, for every one of the 4 supported horizons. Verified with a dedicated test (`test_same_hour_yesterday_repeats_the_last_24h_cycled_forward`) that specifically checks the wrap-around at hour 24→25 never reaches into the forecast's own future.

## 3. Old vs. new validation behavior

| | Old gate | New gate |
|---|---|---|
| Compared against | Persistence only | Best of {persistence, diurnal, same-hour-yesterday, rolling 24h avg} |
| `beats_persistence` meaning | Literally beat persistence | Beat the strongest of all four (implies beating persistence too — see §6) |
| Can a horizon "validate" under new but not old? | — | **No** — new is a strict subset of old (proven in §6) |
| Can a horizon "validate" under old but not new? | — | **Yes** — this is the entire point of the change |
| `method` values written | `lightgbm` / `diurnal_persistence` | Unchanged — same two values, same column, same constraint |

## 4. Rohini PM2.5 — old vs. new, run live just now

Single fresh run, both gates recomputed from the identical underlying metrics (no re-running needed — `persistence_mae` is unchanged, so the old gate is a pure recomputation from the new function's own output):

| Horizon | Model MAE | Persistence MAE | Best baseline | Best baseline MAE | OLD beats | NEW beats |
|---|---|---|---|---|---|---|
| 6h | 9.59 | 8.97 | same_hour_yesterday | 7.80 | false | false |
| 12h | 12.25 | 14.06 | same_hour_yesterday | 7.64 | **true** | **false** |
| 24h | 11.68 | 15.74 | rolling_24h_avg | 13.33 | **true** | **true** |
| 48h | 9.87 | 14.70 | rolling_24h_avg | 10.80 | **true** | **true** |

At this exact moment, the final outcome happens to be the **same both ways** (`diurnal_persistence`, unvalidated) — the 6h horizon fails even the old, easier gate here, and the monotonic rule means nothing beyond it can validate regardless. That's a coincidence of timing, not evidence the change is a no-op: 12h flips from "would have validated" to "correctly doesn't," a real, visible difference in that horizon's own recorded metrics even though it didn't change the final headline number this particular run.

## 5. All-station dry-run summary (31 in-city wards with a station, PM2.5)

Zero database writes — every result below came from calling `_forecast_ward_pollutant()` directly, exactly like the prior Rohini-only validation.

| | Count |
|---|---|
| Wards evaluated | 31 |
| Wards where old gate would have validated something | **14 / 31 (45%)** |
| Wards where new gate validates something | **1 / 31 (3%)** |
| Wards where old and new *disagree* | **14 / 31 (45%)** |
| Wards with insufficient/stale data (`no_data` status) | 0 |

**Every disagreement runs the same direction** (old validates more than new, never the reverse) — exactly the mathematical guarantee in §6, now confirmed empirically across the whole city, not just proven on paper.

**Which baseline is actually the strongest**, tallied across all 31 wards × 4 horizons (124 checks):

| Baseline | Times strongest | Share |
|---|---|---|
| Persistence | 38 | 30.6% |
| Rolling 24h average | 37 | 29.8% |
| Diurnal (hour-of-day mean) | 32 | 25.8% |
| Same-hour-yesterday | 17 | 13.7% |

Persistence *is* still the single most common winner — but it's the strongest baseline barely more than 3 times in 10; the other three combined win 69% of the time. The old gate was checking the right opponent well under a third of the time.

**The one ward that still validates under the new gate — Wazirpur — is the clearest illustration of why this matters.** The old gate would have called it validated all the way to 48h (beat persistence at every horizon). Under the new gate it only validates to 6h, because:

| Horizon | Model MAE | Persistence MAE | Rolling 24h avg MAE |
|---|---|---|---|
| 12h | 6.58 | 8.21 | **6.60** |
| 24h | 13.99 | 15.96 | **11.61** |
| 48h | 29.23 | 32.63 | **25.68** |

At 48h specifically, a naive 24-hour rolling average (25.68) beats the trained model (29.23) by more than persistence does. The old gate would have shipped a 48h-validated forecast that a simple average genuinely outperforms.

**Wards where the divergence was largest** (old validated to 48h, new validates nothing): Dwarka, Jahangirpuri, Patparganj (PATPAR GANJ), Sonia Vihar (SONIA VIHAR), Sri Niwas Puri (SRI NIWAS PURI), Dhirpur (DHIRPUR).

## 6. Why this is backward-compatible, not a breaking change

Proven, not assumed: for any horizon, `best_baseline_mae = min(persistence_mae, diurnal_mae, same_hour_yesterday_mae, rolling_24h_avg_mae) ≤ persistence_mae` always, because persistence is itself one of the four candidates. So `model_mae ≤ best_baseline_mae × (1 − margin)` (the new check) can only be true when `model_mae ≤ persistence_mae × (1 − margin)` is *also* true (the old check) — the new gate is a strict subset of the old one. It can turn a previous `true` into `false`; it can never turn a `false` into `true`.

Consequences, checked against the actual consuming code (not assumed):
- **`evaluate_station_pollutant_anomaly`** (the anomaly-detection SQL function) gates on `fr.beats_persistence` and `fr.max_validated_horizon_hours` to decide whether to trust a validated forecast over its own raw-trend-projection fallback. Under the new logic it will trust the validated forecast *less often*, falling back to trend-projection *more often* — a more conservative outcome, not a broken one, and no SQL/schema change was needed since the column semantics only got stricter, never different in shape.
- **`PredictedIncidentPanel.tsx`** reads `validation_metrics[h].mae/persistence_mae/beats_persistence` directly via a TypeScript object cast. All three keys are unchanged in name and in what `persistence_mae` reports; the five new keys (`diurnal_mae`, `same_hour_yesterday_mae`, `rolling_24h_avg_mae`, `best_baseline`, `best_baseline_mae`) are additive and silently ignored by the existing cast — confirmed by reading the component, not guessed. Its "Persistence MAE" tooltip stays accurate (the number itself didn't change); its label doesn't yet say "vs. best baseline," which is a real, minor, future copy update — **not made here**, since this task's constraints explicitly ruled out touching UI.
- **`forecast_runs.method` CHECK constraint** (`'lightgbm'`/`'diurnal_persistence'`) — untouched. No migration.

## 7. Risks

1. **The new gate is dramatically more conservative right now (3% vs. 45% validated in this one dry-run snapshot)** — this is by design, but it's a real, large drop in how often the UI will show "Machine-learning model" instead of "Seasonal/hourly baseline (fallback)." Product-facing framing may need to adjust expectations ahead of this shipping.
2. **Single-snapshot dry-run** — like the previous Rohini validation, model/baseline selection is time-sensitive (sliding 30-day window, sliding 48h holdout). The 45%→3% swing is a real measurement, but its exact magnitude will vary run to run; the *direction and mechanism* (new ≤ old, always) is what's guaranteed, not this specific percentage.
3. **`PredictedIncidentPanel.tsx`'s "Persistence MAE" label is now incomplete** (doesn't mention the other three baselines) — flagged, not fixed, per the no-UI-changes constraint.
4. **Open-Meteo weather-forecast fetches timed out for most wards during this dry-run** (a sandboxed-environment networking limitation also seen in an earlier audit, not a code defect) — each was caught by the existing `except Exception` handler and fell back to persisted weather, exactly as designed; did not affect validation metrics (weather only feeds the recursive *future* forecast, not the holdout backtest).

## 8. Should production ingest be redeployed?

**Recommended: yes, once reviewed** — this change is strictly more conservative (§6's proof), fully covered by tests (21 passing in `test_forecast.py`, 6 new), and makes zero schema or API changes, so there's nothing else in the deployed service that needs to change in lockstep. It was **not deployed or pushed by this task** — redeploying is the same git-push-triggers-Render-deploy path already used for every other change in this project, and that's a decision for you to make, not something run here.

One operational note worth passing along before redeploying: production's actual retraining cadence (hourly, per the 55-run history examined in the prior report) doesn't match `city_config.forecasting.retraining_frequency_hours: 24`. Not this task's scope to fix, but worth knowing that after redeploy, the new gate will start being exercised roughly every hour, not daily.

## 9. Exact next step

**Let the new gate run in production for a few days, then re-pull the `forecast_runs` history** (the same query used in the prior Rohini report) for Rohini and 2-3 other wards, to see the *real* validated-rate under the new gate over time — not a single dry-run snapshot. That number (whatever it turns out to be — this dry-run's 3% is a lower bound at best, one moment in time) is the honest answer to "how often does ML actually help," and it's the number worth putting in front of anyone deciding whether to invest further in the LightGBM path versus leaning more on the newly-formalized simple baselines.

---

## 10. Checks

| Check | Result |
|---|---|
| `ingest` Python tests (`pytest`) | **43 passed** (37 pre-existing + 6 new: 4 for the new baseline functions, 2 for the strengthened gate behavior) |
| `test_forecast.py` specifically | **21 passed** (15 pre-existing + 6 new) |
| Typecheck / build | Not run — no TypeScript touched |
| Database writes | **None** — every dry-run call was to the pure `_forecast_ward_pollutant()` function; `forecasts`/`forecast_runs` were read only (to pull the live Rohini history for §4's context), never written |
| Secret scan | No dedicated scanner installed; manual grep for `SUPABASE_SERVICE_ROLE_KEY=`, `OPENAQ_API_KEY=`, JWT/`eyJ...` across the changed file, the new tests, this report, and the analysis scripts used — no matches |
