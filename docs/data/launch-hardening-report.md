# Launch Hardening — Backend/Frontend Connection Pass

**Type:** Frontend wiring + two new lightweight, read-only query functions. No migrations, no RLS changes, no `forecast.py`/ingest changes, no new datasets (no FIRMS/OSM/Open-Meteo/PostGIS). No fabricated data anywhere — every number in every new UI element comes from a real query.
**Date:** 2026-07-21
**Follows on from:** [`forecast-trust-ui-framing-report.md`](forecast-trust-ui-framing-report.md) (Analytics/Overview forecast framing, same day)

---

## 1. Goal

Vayu Gati has real, verified backend capability (250 ward boundaries, 34 stations, 44k+ OpenAQ readings, a live forecast pipeline with a strengthened validation gate) that wasn't fully connected to the frontend. This pass audited every forecast/station-health surface, then closed the gaps that mattered for launch — without starting any new backend feature.

## 2. Audit: backend available vs. UI showing (before this pass)

| Backend data | Where it lives | Shown in UI? | Gap |
|---|---|---|---|
| `forecast_runs.method`/`beats_persistence`/`generated_at` per ward | `fetchLatestForecastRun()` (already used by `PredictedIncidentPanel.tsx`) | Only on the incident detail panel | Not visible from the Map, where a commander is most likely to be looking at a ward |
| Method mix, baseline-winner distribution, coverage/staleness | `forecast_runs`, `validation_metrics` jsonb | Analytics (from the same-day prior pass) | Missing: latest cycle timestamp, ward/pollutant breadth (the pair count mixes wards × pollutants together) |
| Total readings loaded, ward-boundary count | `readings`, `wards.boundary` | Nowhere in the UI | No way for anyone to see "how much data is actually loaded" without querying Supabase directly |
| Station freshness (34-station network) | `fetchStationHealth()` | Sensors KPI strip — already solid | Stale/no-data rows gave no context that some staleness is a known, documented upstream gap rather than a new problem |
| Known structural data gaps (ITO/Pusa manual review, Pitampura, Mayapuri) | Documented across 3 prior audit reports, not in any table | Nowhere in the product | No single place a commander could see "what's still missing and why," so a stale/missing row could easily be misread as broken |

Everything else (Sensors' KPI strip, Overview's forecast framing, Analytics' method-mix/baseline-winner panel) was already correctly connected from the prior pass — this audit only found and closed the five gaps above.

## 3. Changes made

### 3.1 Forecast Trust — reach + latest cycle time (Analytics)

Added `summarizeForecastReach()` to `forecastTrustRules.ts` (pure, tested) — counts distinct wards and pollutants separately from the raw ward×pollutant pair count, since "93 pairs" alone doesn't say whether that's 31 wards × 3 pollutants or 93 wards × 1. Wired into `ForecastAccuracySummary.reach` in `data.ts` (same query, no new fetch) and displayed on `ForecastTrustPanel.tsx` as:

> "Covering 31 wards across 3 pollutants (NO2, PM10, PM25) — latest cycle Jul 21, 2026, 10:27 AM"

`latestGeneratedAt` (already computed by the existing `summarizeForecastCoverage`, just not displayed before) now surfaces as the cycle timestamp.

### 3.2 Map ward panel — forecast method + validation status

`fetchLatestForecastRun(wardId, 'pm25')` (already battle-tested by `PredictedIncidentPanel.tsx`) is now also fetched in `MapPage.tsx` on ward selection, mirroring the existing `attributionState` pattern exactly (one more `useAsync`, enabled only when a ward is selected). `SelectedWardPanel.tsx` renders a new "PM2.5 forecast status" block using two already-existing, already-tested pure functions from `incidentRules.ts` — `FORECAST_METHOD_LABEL` and `forecastFallbackStatus()` — so the wording is identical to what `PredictedIncidentPanel.tsx` already says elsewhere in the app, not a new, possibly-inconsistent phrasing. Shows: method ("Machine-learning model (LightGBM)" / "Seasonal/hourly baseline (fallback)"), a one-line status sentence, and the latest cycle timestamp. Falls back to "No forecast validation record yet for this ward" when none exists — never a blank or fabricated state.

### 3.3 Sensors — known-gap context note

A short, non-alarmist note now appears above the station table whenever any station is stale or no-data: "N stations showing stale or no data — some of this is expected (upstream OpenAQ publish delays, or a known gap — see Data Readiness for specifics), not necessarily a broken sensor." Purely conditional on the existing `sensorStatus()` classification already powering the KPI strip — no new query.

### 3.4 Data Readiness card (Sensors, right-hand panel default state)

New `DataReadinessCard.tsx`, shown in Sensors' existing side-panel slot whenever no station is selected (same pattern as the Map's `SpatialSummaryPanel` default state — reuses existing screen space, not a bigger layout). Backed by:

- **`fetchDataFootprint()`** (new, `data.ts`) — 4 small `count`/`head: true` or `.limit(1)` queries (ward-boundary count, total readings count, earliest/latest reading timestamp). No row payloads transferred; safe to run on every Sensors load.
- **`fetchForecastAccuracySummary()`** (existing, reused — same function Analytics already calls) for the forecast-pipeline line.
- **`buildDataReadinessChecklist()`** (new, `readinessRules.ts`, pure, 6 tests) — turns those real counts into ok/attention lines. Nothing is hardcoded "ok": a zero count genuinely flips a line to "attention," so the card can't silently claim readiness that isn't real.

Live values observed in verification: **252 ward boundaries loaded, 34 stations (34 active), forecast pipeline live (93 of 93 pairs fresh), 45,026 OpenAQ readings loaded, forecast gate active.**

The card also lists the four known, already-documented gaps (verbatim-consistent with `delhi-station-expansion-report.md` and `delhi-safe-station-import-report.md`, not paraphrased into something less accurate):
- ITO and both Pusa stations (DPCC + IMD) verified live on OpenAQ, pending manual ward-boundary review.
- Pitampura has no matching OpenAQ location.
- Mayapuri has no official CPCB/DPCC/IMD station.
- FIRMS/OSM/dedicated weather map layer are not part of this launch (noted precisely: Open-Meteo forecast weather is already an internal model input in `forecast.py`, it just has no user-facing layer yet — this distinction matters, since claiming "weather not used" would itself be inaccurate).

These four bullets are static text, not derived from a query — there is no `known_gaps` table. They're drawn directly from completed, cited audits, not invented for this card.

## 4. What was deliberately not changed

- **No migrations** — `fetchDataFootprint()` reads existing columns (`wards.boundary`, `readings.ts`) with `count`/`head` queries only.
- **No RLS changes** — every new query goes through the same RLS every existing caller of these tables already uses; no blocker was found that would have required one.
- **No `forecast.py`/ingest changes.**
- **No new datasets** — FIRMS/OSM/Open-Meteo/PostGIS untouched; Open-Meteo's existing internal-only usage is called out accurately, not expanded.
- **No baseline forecast relabeled as ML** — `SelectedWardPanel`'s new block uses the exact same `FORECAST_METHOD_LABEL` map that already correctly says `diurnal_persistence: 'Seasonal/hourly baseline (fallback)'`.
- **Low LightGBM rate not hidden** — it's the literal number in three places now (Analytics' method-mix stat, the model-selection explainer sentence, and the Map ward panel's per-ward method line), always framed as conservative gate behavior, never as failure.

## 5. Tests

New: `forecastTrustRules.test.ts` gained 2 tests for `summarizeForecastReach` (25 total in that file, up from 23). New file `readinessRules.test.ts`, 6 tests — every-line-ok on healthy input, ward-boundary attention flip at zero, forecast-pipeline "stalled" vs. "no runs yet" distinction, gate-always-active invariant, thousands-separator formatting.

Full suite: `npx vitest run` → **207/207 passed** (142 `incidentRules` + 21 `overviewRules` + 25 `forecastTrustRules` + 13 `mapRules` + 6 `readinessRules`).
Typecheck: `npx tsc -b` → clean.
Build: `npx vite build` → succeeds (pre-existing >500kB single-chunk warning, unrelated).

## 6. Live verification

Local dev server against the same production Supabase project, logged in as a real commander account, full console/page-error listeners attached, navigated via real nav links:

| Page | Result |
|---|---|
| **Analytics** | "Covering 31 wards across 3 pollutants (NO2, PM10, PM25) — latest cycle Jul 21, 2026, 10:27 AM" renders correctly above the existing model-selection explainer. LightGBM count had risen to 6/93 (6%) between this pass and the prior one — production is still writing new cycles, confirmed live. |
| **Sensors** | Data Readiness card renders with real live numbers (252/34/45,026/93 of 93 fresh); known-gap note appears correctly above the table when 6 stations are stale. |
| **Map** | Ward-panel code path verified two ways: (a) TypeScript compiles clean end-to-end through the new prop chain, and (b) a direct authenticated query against the same `forecast_runs` table `fetchLatestForecastRun` reads returned a real, correctly-shaped row (`method: 'diurnal_persistence'`, `beats_persistence: false`, `generated_at`) for a live ward. Could not visually confirm by clicking a ward marker in this local session: MapLibre markers only mount after the basemap style loads, and the style fetch 403s locally because the configured MapTiler key is domain-restricted to production — the same pre-existing, unrelated local-dev artifact noted in the prior report. Not a regression from this change (nothing here touches Map rendering, `basemaps.ts`, or marker mounting), and the earlier production-verification pass already confirmed the Map loads cleanly on the real deployed domain. |
| **Overview** | Regression-only check (no changes this pass) — renders identically to the prior verification, zero new console errors. |

No new console or page errors on any page beyond the pre-existing local MapTiler 403s.

## 7. Remaining launch risks

1. **Map ward-panel forecast block unverified by direct click**, for the local-dev reason in §6 — mitigated by the direct-query verification, but a production click-through (or a CI environment with a working MapTiler key) would close this out fully.
2. **`ForecastCoverageSummary.totalPairs`** still can't detect a ward/pollutant pair with *zero* runs ever (same limitation noted in the prior report) — the Data Readiness card's "Forecast pipeline" line inherits this: it reports "of pairs that have ever run," not "of the theoretical full city grid."
3. **Data Readiness's known-gaps list is static text** — if a future pass resolves ITO/Pusa/Pitampura/Mayapuri, this card needs a manual edit; nothing here would silently update it (a deliberate tradeoff — no `known_gaps` table was created to avoid a migration for four sentences).

## 8. Launch-readiness verdict

**Ready for launch from a forecast-trust and data-visibility standpoint.** The pipeline is understandable in the UI at three points (Overview, Analytics, Map), the low LightGBM rate is framed consistently and honestly everywhere it appears, the 34-station network's health is fully visible on Sensors with context for expected staleness, and a single Data Readiness card gives an honest, real-number snapshot of what's loaded and what's still a known gap. All tests pass, the build is clean, and no schema/RLS/ingest surface was touched.

## 9. Files changed

- `web/src/lib/forecastTrustRules.ts` / `.test.ts` — added `summarizeForecastReach`
- `web/src/lib/readinessRules.ts` / `.test.ts` — new
- `web/src/lib/data.ts` — `ForecastAccuracySummary.reach`, new `fetchDataFootprint()`
- `web/src/components/analytics/ForecastTrustPanel.tsx` — reach + cycle-time line
- `web/src/pages/MapPage.tsx` — new `fetchLatestForecastRun` fetch on ward selection
- `web/src/components/map/SelectedWardPanel.tsx` — new PM2.5 forecast status block
- `web/src/pages/SensorsView.tsx` — known-gap note, Data Readiness card wiring
- `web/src/components/sensors/DataReadinessCard.tsx` — new
- `docs/data/launch-hardening-report.md` — this report

## 10. Checks

| Check | Result |
|---|---|
| Migrations / RLS / `forecast.py` / ingest changes | **None** |
| New datasets (FIRMS/OSM/Open-Meteo/PostGIS) | **None added** |
| Tests | 207/207 passing (8 new) |
| Typecheck / build | Clean |
| Live browser check (Overview + Analytics + Map + Sensors, real login, real production data) | 0 new console/page errors; MapTiler 403s are the same pre-existing local-dev-only artifact noted in the prior report |
| Secret scan | Manual grep across every changed/new file for `SUPABASE_SERVICE_ROLE_KEY=`, `OPENAQ_API_KEY=`, JWT/`eyJ...`, and the live-verification login credentials — no matches. Credentials were passed only as env vars to ephemeral scratchpad scripts, deleted immediately after use. |
