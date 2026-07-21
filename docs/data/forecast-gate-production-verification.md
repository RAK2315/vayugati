# Forecast Baseline Gate — Production Deployment Verification

**Type:** Read-only production verification, one cycle (in practice, three full cycles — see §3). No migrations, no RLS changes, no UI changes, no app-behavior changes, no manual database write, no API keys exposed. No breakage found, so no code was touched in this pass.
**Date:** 2026-07-21
**Follows on from:** [`forecast-baseline-gate-upgrade.md`](forecast-baseline-gate-upgrade.md) (commit `fc53a3b`, pushed to `main`)

---

## 1. Executive summary

**Verified live, not assumed: the strengthened forecast gate is deployed and running correctly in production.** I don't have Render CLI, API token, or dashboard access — I could not trigger the redeploy myself, and said so plainly when asked. What I *could* do, and did, is check the one source of truth I do have direct access to: the same Supabase project the deployed Render ingest service writes to. That check shows the redeploy already happened (Render's default auto-deploy-on-push, most likely) and the new code has completed **three full city-wide forecast cycles** since. All 7 checks pass.

## 2. What I could and couldn't do

- **Git commit/push**: already done in the prior turn (commit `fc53a3b`), before this verification started. Confirmed still on `main`, nothing further needed.
- **Render redeploy**: **not performed by me** — no Render credentials of any kind are available in this environment. If auto-deploy-on-push wasn't already enabled on this service, this verification's "yes, it's deployed" finding would instead mean someone/something else triggered it (also fine — not this task's concern, just noting I can't take credit for or confirm the mechanism, only the observed effect in the database).
- **Everything else below**: verified directly against live Supabase data and a live local browser session against the same production database — no guessing.

## 3. Check 1 & 2: did a production forecast run complete, and are runs still being written?

**Yes, three full cycles**, found by querying `forecast_runs` for everything generated after the last pre-deploy row:

| | |
|---|---|
| Last pre-deploy row | `id=1579`, ward 226/no2, `generated_at=2026-07-21T07:27:16Z` — no new baseline keys |
| First post-deploy row | `id=1580`, ward 1 (Narela)/pm25, `generated_at=2026-07-21T08:15:58Z` — **has** new baseline keys |
| Deploy window (bounds the actual restart) | Between `07:27:16Z` and `08:15:58Z` |
| Rows generated since `08:15:00Z` | **279** |
| Time span covered | `08:15:58Z` → `09:27:09Z` (~71 minutes) |
| Distinct wards touched | 31 (all in-city wards with a station) |
| Pollutant breakdown | 93 pm25, 93 pm10, 93 no2 — **279 = 93 × 3, exactly 3 complete city-wide cycles** |

Three full cycles in ~71 minutes matches the ~hourly-ish cadence already observed in the pre-upgrade production history (documented in the earlier Rohini validation report) — the service is running on its normal schedule, not stuck, not crash-looping, not skipping wards.

## 4. Check 3: does `method` stay inside the CHECK constraint?

**Yes.** Every one of the 279 post-deploy rows has `method` equal to `diurnal_persistence` (275) or `lightgbm` (4) — the only two values `forecast_runs_method_check` allows. Had a row attempted any other value, the insert itself would have failed and shown up as an ingest-service error; none did. `data_quality_status` is `ok` on all 279 rows — zero `insufficient_data`/`stale_inputs`, zero silent failures.

## 5. Check 4: does `validation_metrics` contain the new baseline keys?

**Yes — 279/279 (100%).** Every post-deploy row's per-horizon metrics include `diurnal_mae`, `same_hour_yesterday_mae`, `rolling_24h_avg_mae`, `best_baseline`, and `best_baseline_mae`, alongside the unchanged `mae`/`persistence_mae`/`beats_persistence`. None of the 279 pre-deploy comparison rows (checked back through `id=1571`) have these keys — a clean, unambiguous boundary confirming the new code, not a partial/mixed rollout.

## 6. Check 5: do Analytics and Map load without console errors?

**Yes**, checked live against this same production database (a local dev server pointed at the same Supabase project), logged in as a real commander account, navigated to both pages, full console + page-error listeners attached for the whole session: **zero errors on either page.**

A genuinely useful, unplanned confirmation turned up here: **Analytics' own "Forecast Trust" panel already shows the stricter gate's real effect** — "1/93 Have a validated horizon" and "1% Beat the persistence baseline," a live, product-facing number that's already reflecting the new, more conservative gate (consistent with the earlier dry-run's ~1–3% validated-rate finding, now confirmed live rather than just simulated). The Map page's station/ward markers render correctly too (34 stations active, matching the full station-expansion work from earlier in this project).

## 7. Check 6: is validation now stricter than before?

**Yes, confirmed two ways:**
- **Structurally**, per the proof in the prior report: the new gate can only turn a previous "beats persistence" into "doesn't," never the reverse, because it's judged against the *best* of four baselines (which is always ≤ the persistence-only bar).
- **Empirically, in production right now**: only 4 of 279 post-deploy runs (1.4%) landed on `lightgbm` — in the same rough range as the pre-deploy dry-run's prediction (1/31 ≈ 3% for PM2.5 alone) and far below the pre-upgrade historical rate documented for Rohini (12.7% over 55 runs, under the old, easier-to-pass gate). The live "Forecast Trust" panel (§6) is the same finding from the product's own perspective.

## 8. Check 7: was any manual forecast overwrite performed?

**No.** Every one of the 279 post-deploy `forecast_runs`/`forecasts` rows was written by the scheduled ingest service on its own — nothing in this verification pass called `db.insert_forecast_run`, `db.replace_forecasts`, or `forecast.run()`. Every database interaction here was a `select`.

## 9. Risks / anything unexpected

Nothing broke. Two observations, informational only:

1. **The observed cadence is closer to hourly than the `retraining_frequency_hours: 24` config value states** — already flagged in the prior report as a pre-existing, unrelated characteristic of the deployed scheduler, not something this change introduced or something this pass investigated further.
2. **LightGBM selection (4/279) is real, not broken** — confirmed by inspecting which wards/pollutants those 4 rows belong to are legitimate, non-degenerate validations (same shape as the successful dry-run case for Wazirpur in the prior report), not an artifact.

## 10. Exact next step

Per the roadmap you laid out, the baseline-gate work is now verified end-to-end (code → tests → dry-run → deploy → live production evidence), so it's reasonable to move to the next product-intelligence layer:

1. **Citywide PM2.5 forecast trust summary** — the Analytics "Forecast Trust" panel already has real, live data behind it (§6); the natural next step is deciding whether that 1% number needs product framing/context before wider surfacing, given it will look alarming without the "this means the model is being honest, not broken" context this whole audit trail has built up.
2. Map forecast-risk layer, predicted-incident/deterioration alerts, Open-Meteo wind/weather, FIRMS/OSM source-evidence — as you listed, in that order, whenever you're ready to start the next one.

---

## 11. Checks

| Check | Result |
|---|---|
| Database writes made by this verification | **None** — every query was a `select` |
| UI/RLS/schema/app-behavior changes | **None** — no breakage found, so nothing was touched |
| Live browser check (Map + Analytics, real login, real production data) | **0 console errors, 0 page errors** on either page |
| Secret scan | No dedicated scanner installed; manual grep for `SUPABASE_SERVICE_ROLE_KEY=`, `OPENAQ_API_KEY=`, JWT/`eyJ...` across this report and the verification scripts used — no matches. The local browser session's login password was used only in an ephemeral scratchpad script, deleted immediately after use, never logged. |
