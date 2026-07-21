# Forecast Trust — Citywide UI Framing

**Type:** UI/copy + pure-function derivation layer only. No migrations, no RLS changes, no `forecast.py` changes, no ingest changes, no schema changes. `forecast_runs.method`'s `CHECK` constraint (`lightgbm` / `diurnal_persistence`) is untouched; all new data comes from columns already selected or already present in the free-form `validation_metrics` jsonb column.
**Date:** 2026-07-21
**Follows on from:** [`forecast-gate-production-verification.md`](forecast-gate-production-verification.md) (confirmed the strengthened baseline gate is live in production, and flagged that Analytics' "1/93, 1%" Forecast Trust number, while correct, could read as failure without framing)

---

## 1. Problem

The baseline-gate upgrade ([`forecast-baseline-gate-upgrade.md`](forecast-baseline-gate-upgrade.md)) made the LightGBM validation gate stricter on purpose: ML is now only selected when it beats the *best* of four simple baselines (persistence, diurnal/seasonal, same-hour-yesterday, 24h rolling average), not persistence alone. That's a deliberate, correct tightening — but its visible effect is that the LightGBM validation rate dropped from ~12.7% to ~1.4% in production. Every "Forecast Trust" surface in the app was still presenting that drop as a single bare percentage, with no framing to distinguish "the gate is being conservative" from "the forecasting system is broken." Three separate surfaces had this problem, not just the one originally flagged:

1. **Analytics → Forecast Trust panel** — showed "1/93, 1%" with no context.
2. **Overview (Command view) → "Forecast trust" KPI tile** — showed the same percentage, and its `tone` flipped to `warning` (amber) whenever it dropped below 50%, actively color-coding the conservative gate as a problem.
3. **Overview → Operational Summary panel** — a sentence reading "Forecasts beat a naive persistence baseline on 2% of validated ward/pollutant pairs," with no explanation of what "beat" means or why a low number is expected and fine.

The Overview page is the app's default landing view, so (2) and (3) are what a commander sees first — fixing only Analytics would have left the more prominent, more alarming (literally warning-colored) surface untouched.

## 2. What changed

### 2.1 New pure-function layer: `web/src/lib/forecastTrustRules.ts`

Following this codebase's existing convention (`incidentRules.ts`, `overviewRules.ts`, `mapRules.ts`: no I/O, pure functions, one co-located `.test.ts`), this file derives everything the UI needs from an array of `forecast_runs` rows:

- `summarizeForecastMethodMix` — counts of `lightgbm` vs `diurnal_persistence` vs unexpected values.
- `summarizeBaselineWinners` — tallies which of the four baselines (`best_baseline` key) won most often, per validated horizon, across all rows.
- `summarizeForecastCoverage` — fresh vs. stale (>6h since last run) ward/pollutant pairs, and the latest `generated_at`.
- `forecastEngineStatusLine`, `modelSelectionExplainer`, `strongestBaselineLabel` — the plain-language copy, written specifically to state honest numbers/percentages while never implying failure. Every one of these is unit-tested against that constraint directly (e.g. `expect(line.toLowerCase()).not.toContain('fail')`).

Every function tolerates rows written **before** the baseline-gate upgrade shipped, where `validation_metrics` is `{}` or missing the new keys entirely — a mixed fleet of old and new rows is the expected steady state, not an edge case. Tested explicitly (`treats a pre-upgrade row ... as no-data, not a crash`, `handles a mixed fleet of old and new rows correctly`).

### 2.2 `web/src/lib/data.ts`

`fetchForecastAccuracySummary()`'s `select()` was extended from 5 to 7 columns (added `method`, `validation_metrics` — both already-existing columns, no new query surface). `ForecastAccuracySummary` now additionally exposes `methodMix`, `baselineWinners`, and `coverage`, computed via the new pure functions over the same "latest row per (ward, pollutant) pair" dedup this function already did. `beatsPersistenceCount` and `wardsWithAnyValidatedHorizon` are kept for backward compatibility with any other caller, though the framing itself has moved away from leading with "beats persistence" as the headline number.

### 2.3 `web/src/components/analytics/ForecastTrustPanel.tsx` (rewritten)

Old: two stats (validated / beats-persistence), no explanatory copy.
New: coverage status line ("Forecasts are live for all 93 ward/pollutant pairs") stated up front, before any percentage, so "is it running" is answered before "how good is it" — then the model-selection explainer sentence, then a 4-stat grid (using ML / using a safer baseline / have a validated horizon / beat plain persistence), then the strongest-baseline line, then a stale-run warning if any pairs haven't refreshed recently. The old "beats persistence" percentage is still shown (users may want it), but it's now the fourth stat in a grid, not the panel's only number.

### 2.4 `web/src/pages/AnalyticsView.tsx`

Replaced the "Beat persistence baseline" KPI tile (conditionally toned `success`/`neutral` based on count — i.e., previously *would* have gone neutral/grey at 1%, not alarming there, but still uninformative) with a "Using machine learning" tile showing `lightgbmCount / total`, always toned `info`. Replaced rather than added, to keep the existing 6-column desktop grid intact.

### 2.5 `web/src/pages/CommandView.tsx` (Overview) — found during live verification, not in the original file list

The "Forecast trust" KPI tile computed `trustPct` from `beatsPersistenceCount` and set `tone: trustPct >= 50 ? 'success' : 'warning'` — meaning it rendered **amber/warning-colored** at the current 2% rate, on the app's home page. Replaced with the same "Using machine learning" framing as Analytics (`lightgbmCount/total`, sublabel "rest use a safer baseline"), tone hardcoded to `info` — a low count is conservative gate behavior, not a warning condition, so it no longer gets warning-colored.

### 2.6 `web/src/components/overview/OperationalSummaryPanel.tsx` — same discovery

Replaced the sentence "Forecasts beat a naive persistence baseline on 2% of validated ward/pollutant pairs (2 of 93)" — accurate but unexplained, and the word "naive" reads as a dig at the very fallback the gate now deliberately prefers — with the same `modelSelectionExplainer()` sentence used on Analytics, for one consistent explanation reused everywhere instead of three different partial framings.

### 2.7 `web/src/components/PredictedIncidentPanel.tsx` — small honesty fix

The per-horizon MAE chips were labelled "Model accuracy by horizon (MAE vs. persistence)" with a tooltip showing only `persistence_mae` — stale now that the gate compares against four baselines, not just persistence. Updated the label to "MAE vs. best baseline" and the tooltip to show `best_baseline` + `best_baseline_mae` when present (falling back to the old persistence-only tooltip for pre-upgrade rows, which don't have the new fields). No change to `m.mae`, `run.beats_persistence`, or any other existing binding.

## 3. What was deliberately not changed

- **`forecast.py`, ingest behavior, `forecast_runs` schema, RLS** — untouched, per the brief.
- **`method` values** — still exactly `lightgbm` / `diurnal_persistence`; nothing in the UI implies a third state exists.
- **No baseline forecast is ever labelled "ML"** — `FORECAST_METHOD_LABEL` in `incidentRules.ts` already correctly said `diurnal_persistence: 'Seasonal/hourly baseline (fallback)'`; nothing here relabels it.
- **The raw numbers are never hidden or rounded away** — every "X of Y" and percentage shown is the real live count; `modelSelectionExplainer` is tested to include the literal counts even at `4/279`.

## 4. Live verification

Local dev server against the same production Supabase project (established pattern from prior sessions), logged in as a real commander account, full console/page-error listeners attached, Overview → Analytics → Map navigated via the actual nav links (not direct URL, to exercise real client-side routing):

| Page | Result |
|---|---|
| Overview | "2/93 Using machine learning" tile renders `info`-toned (no warning color); Operational Summary shows the new explainer sentence; zero forecast-related console/page errors |
| Analytics | Forecast Trust panel shows: coverage line ("Forecasts are live for all 93 ward/pollutant pairs"), explainer sentence, 4-stat grid (2 / 91 / 2/93 / 2%), strongest-baseline line ("Persistence is the strongest baseline most often (31% of validated horizons)"); zero forecast-related console/page errors |
| Map | Spatial Summary and layer panel render correctly (13 wards shown, 34 stations active, 6 stale sensors); basemap tiles didn't render locally — `api.maptiler.com` returned 403 for every style, because the configured MapTiler key is restricted to the production domain and this check ran against `localhost`. This is a local-dev-only artifact of using a production key outside its allowed domain, not caused by this change (nothing here touches Map, `basemaps.ts`, or MapTiler config), and the prior production-verification pass already confirmed the Map page loads with zero console errors on the real deployed domain. |

No new console or page errors were introduced by any of the six files changed.

## 5. Tests

New: `web/src/lib/forecastTrustRules.test.ts`, 23 tests — method mix (including defensive bucketing of an unexpected `method` value, empty input), baseline winners (multi-horizon tally, empty `validation_metrics`, pre-upgrade rows with no `best_baseline` key, a mixed old+new fleet, an unrecognized baseline value, a null `validation_metrics`), coverage (fresh/stale split, empty input, the exact staleness-boundary second), and the three copy functions (each asserted to never contain "fail"/"broken"/"bad"/"poor"/"error", never claim ML is always better, and always report the real counts — including the zero-division case).

Full suite: `npx vitest run` → **199/199 passed** (142 `incidentRules` + 21 `overviewRules` + 23 `forecastTrustRules` + 13 `mapRules`).
Typecheck: `npx tsc -b` → clean, no errors.
Build: `npx vite build` → succeeds (pre-existing >500kB single-chunk warning, unrelated to this change).

## 6. Risks / limitations

1. **`ForecastCoverageSummary.totalPairs`** counts distinct (ward, pollutant) pairs that have *at least one* recorded run — it can't detect a pair with *zero* runs ever, since that would need a separate "all wards × enabled pollutants" query this summary doesn't have. Not fixed here — flagged, not silently assumed away.
2. **`strongestBaselineLabel`** is currently dominated by a small number of post-upgrade rows (2 pairs have gone through a validated LightGBM cycle so far; the baseline-winner tally comes from the `best_baseline` key which is present on all 279 post-deploy rows per the prior verification, so the 31%-persistence figure is a real tally over that fleet, not just the 2 ML rows) — will naturally become more representative as more of the fleet cycles through post-upgrade runs.
3. **MapTiler 403s in local dev** (§4) are pre-existing and out of scope; no action taken.

## 7. Files changed

- `web/src/lib/forecastTrustRules.ts` — new
- `web/src/lib/forecastTrustRules.test.ts` — new
- `web/src/lib/data.ts` — extended `ForecastAccuracySummary` + `fetchForecastAccuracySummary`
- `web/src/components/analytics/ForecastTrustPanel.tsx` — rewritten
- `web/src/pages/AnalyticsView.tsx` — one KPI tile replaced
- `web/src/pages/CommandView.tsx` — one KPI tile replaced (found during live verification)
- `web/src/components/overview/OperationalSummaryPanel.tsx` — one sentence replaced (found during live verification)
- `web/src/components/PredictedIncidentPanel.tsx` — label + tooltip honesty fix
- `docs/data/forecast-trust-ui-framing-report.md` — this report

## 8. Checks

| Check | Result |
|---|---|
| Database writes made by this pass | **None** — read-only `select`s in `data.ts`, everything else is pure UI/derivation code |
| Migrations / RLS / `forecast.py` / ingest changes | **None** |
| `forecast_runs.method` values | Unchanged — still exactly `lightgbm` / `diurnal_persistence` |
| Tests | 199/199 passing (23 new) |
| Typecheck / build | Clean |
| Live browser check (Overview + Analytics + Map, real login, real production data) | 0 forecast-related console/page errors; MapTiler 403s are a pre-existing local-dev-only artifact, unrelated to this change |
| Secret scan | No dedicated scanner installed; manual grep across changed files and this report for `SUPABASE_SERVICE_ROLE_KEY=`, `OPENAQ_API_KEY=`, `MAPTILER`, JWT/`eyJ...` — no matches. The login password used for live verification was passed only as an env var to an ephemeral scratchpad script, deleted immediately after use, never logged or written to any tracked file. |
