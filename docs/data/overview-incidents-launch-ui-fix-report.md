# Overview & Incidents — Launch UI Clarity/Consistency/Bug-Fix Pass

**Type:** Display-layer clarity and bug fixes only. No migrations, no RLS changes, no `forecast.py`/ingest changes, no new datasets. Two genuine backend-generated-text bugs were found (a SQL double-prefix and a raw boolean leak) — both are fixed at the display layer with defensive parsing, not by editing the SQL functions that produce them (forbidden this pass).
**Date:** 2026-07-21
**Follows on from:** [`launch-hardening-report.md`](launch-hardening-report.md) (forecast/data-readiness visibility pass, same day)

---

## 1. Scope

Overview and Incidents only, per the brief. Touched `AppShell.tsx` (shared header, holds the search bar every page uses) and `mapMarkers.ts`/`overviewRules.ts`'s `hotspotStatus()` (shared with Map's `SelectedWardPanel`) only because the fix genuinely lived there — in both cases the change is strictly additive (new optional param, new enum value with a safe default) so Map's own behavior is provably unchanged; verified live in §6.

## 2. Overview fixes

| # | Issue | Fix |
|---|---|---|
| A1 | Forecast Trust wording was terse ("2% forecast trust") with no breakdown | `OperationalSummaryPanel` now shows Forecast coverage / ML selected / Baseline fallback as three stats, plus the existing honest explainer sentence and a "Latest forecast cycle" timestamp — all from data already fetched, no new query |
| A2 | Hotspots table mixed AQI and µg/m³ under vague headers ("Current", "Forecast Peak") | Renamed to "Current AQI" / "Current PM2.5 (µg/m³)" (toggles with the page's pollutant switch), "Forecast PM2.5 Peak (µg/m³)", "Local Excess (µg/m³)" — always PM2.5 regardless of the toggle, stated explicitly in the footnote. Unit text is exempted from the header's CSS `uppercase` transform (found live during verification - `uppercase` was rendering "µg/m³" as an easily-misread "MG/M³") |
| A3 | Mayapuri (no station, proxy-only) showed "industrial" as Likely Source despite having zero readings | New `isWardDataBacked()` check (`ward.ts != null`) gates the Likely Source cell to "Not assessed" for any ward with no reading at all — verified live: Mayapuri's row now reads "— — — Not assessed — No data —" |
| A4 | "Confidence" column read as source-attribution confidence but is actually the forecast's own peak-point confidence | Renamed "Forecast Confidence"; added a footnote distinguishing it from source-attribution confidence, which stays preliminary until per-incident evidence is added |
| A5 | A 51h-stale ward (Bawana) showed "Trending up" as if current | `hotspotStatus()` gained an optional `readingAgeMinutes` param (backward-compatible - Map's caller doesn't pass it, so Map is unaffected) - a reading older than 180 min (same threshold as Sensors' own staleness check) now returns a new `'stale'` status ("Stale reading"), checked before watch/stable but after severe (a forecast crossing threshold isn't demoted by reading staleness). The badge's tooltip keeps the underlying trend as a secondary note ("was trending up") |
| A6 | Team Allocation card showed a bare "6" with no label | Renamed "Field Team Allocation", added a "Teams available" label next to the stepper and a subtitle, and each ward chip now reads "2 teams" instead of a bare number |
| A7 | Central "(coming soon)" search bar read as unfinished | Text changed to "Search disabled in pilot build" / "Search will be enabled after pilot data review"; narrowed from `max-w-md` to `max-w-xs` so it no longer dominates the header (shared `AppShell.tsx`, so this applies app-wide) |

## 3. Incidents fixes

| # | Issue | Fix |
|---|---|---|
| B1 | An incident's "Prediction method: Validated forecast model" (detection-time snapshot) could sit next to a Forecast card now reading "Baseline fallback" (current cycle) - a real, honest divergence that reads as a contradiction | Added a clarifying note between the two facts explaining they're two different points in time (detection vs. most recent cycle) - never hides or fabricates agreement, just explains the real reason they can differ |
| B2 | Suspected pollutant mismatch between the incident's own "Pollutant" fact and its Forecast card | New `resolveIncidentPollutant()` is the single source of truth both `IncidentStatusHeader` and `PredictedIncidentPanel` now call, instead of each doing its own `??` fallback - they can no longer diverge for the same incident. Live-verified: a PM10 incident correctly showed "Forecast - PM10" throughout |
| B3 | Dispatch tab rendered nothing (blank white panel) when no intervention exists yet | New `dispatchEmptyStateMessage()` names the real, already-loaded blocker (source only suspected → needs corroboration; or no responsible authority resolved yet); "Interventions unavailable" also gets a proper empty state instead of returning `null` |
| B4 | Evidence tab showed N visually-identical "Citizen Verification — Proposed" rows, and rationale text like "Automated attribution: Automated attribution: leading hypothesis..." | Traced to a real SQL bug: `calculate_incident_source_attribution` prepends `'Automated attribution: '` to a `v_rationale` that already starts with that exact prefix (`supabase/migrations/20260722000000_source_attribution.sql:917`). Fixing the function needs a migration (forbidden this pass); `cleanMissionRationale()` strips however many copies of the prefix a given row has, and a separate "Automated attribution" badge replaces the inline prefix. `groupDuplicateMissions()` collapses exact (type, status, rationale) duplicates into one row with a "× N" count - live-verified: 4 identical missions collapsed to "Citizen Verification × 4", while 2 similar-but-different-confidence missions correctly stayed separate |
| B5 | An "unresolved" source hypothesis showed "Unresolved — 100%" with a full progress bar | Root cause: the attribution engine stores `source_category='unresolved'` with `probability=1.0` - 100% *certain it's unresolved*, not 100% confident in a source. That hypothesis now shows "Insufficient evidence" with no percentage/bar and the sentence "No source category has enough evidence to be assessed as more likely than others." Also fixed a related bug this surfaced: the "Recommended next evidence" block was silently not appearing for an unresolved-only case (the probability-threshold check read 1.0 as "confident enough") - now explicitly triggers for `source_category === 'unresolved'` too |
| B6 | Data-quality note showed raw Postgres boolean shorthand: "monitoring readings t, wind direction f, ..." | Root cause: the same SQL function's `format('%s', boolean)` call (line 380-383 of the migration). `parseDataQualityNote()` parses the fixed-shape sentence into "Available: ..." / "Missing: ..." lists; falls back to the raw text (never hidden) if the shape doesn't match |
| B7 | "No field officer assigned" dead-end message gave no next step | Added "Ask an admin to assign a field officer to this ward before dispatching." No settings/link added - confirmed no ward-officer-assignment page exists in the router, and the brief said only to link one if it already exists |
| B8 | Forecast chart had no horizon/unit/threshold context | Added a caption line: "Next {N}h" and "µg/m³ · shaded band = uncertainty range"; peak label now includes the unit ("peak 128 µg/m³"). No threshold line drawn - the only candidate constant (`SEVERE_THRESHOLD=400`) is PM2.5-specific and this chart also renders PM10/NO2/etc., so drawing it would be wrong for non-PM2.5 incidents; left out rather than shown incorrectly for some pollutants |
| B9 | Label read "Model accuracy by horizon (MAE vs. best baseline)" - stale phrasing from before the baseline-gate upgrade fully landed in the UI | Renamed "Forecast error by horizon" with supporting text "Compared against the strongest available simple baseline where validation data exists." |
| B10 | "NO SEVERITY" next to "ESCALATED" read as contradictory | Relabeled "Severity unavailable" and "Escalated by rule" (tooltip already explained escalation is time/SLA-based, independent of severity - now the visible label says so too) |
| B11 | Timeline could show many repeated internal events ("attribution recalculated" ×8, "predicted incident reviewed" ×5, seen live on a real incident during verification) | `collapseRepeatedTimelineEvents()` collapses only two confirmed-safe, auto-generated, identical-note event types (`attribution_recalculated`, `predicted_incident_reviewed`) into one entry with a count and the latest timestamp, at the position of the first occurrence. Every other event type is untouched, one entry each - deliberately narrow, not a general "merge similar events" rule. Live-verified: "Attribution recalculated × 8 / Latest: Jul 21, 07:27 AM" and "Reviewed × 5 / Latest: Jul 20, 11:14 AM" replaced what would have been 13 individual rows |

A small related cosmetic fix found during verification: the "Recommended next evidence" line could show a double period ("...rule it out.. Use..." ) when the cleaned rationale already ended in one - fixed with a trailing-period strip.

## 4. New pure functions (all tested)

`incidentRules.ts`: `resolveIncidentPollutant`, `missionRationaleIsAutomated`/`cleanMissionRationale`, `groupDuplicateMissions`, `dispatchEmptyStateMessage`, `parseDataQualityNote`, `collapseRepeatedTimelineEvents` (+ `COLLAPSIBLE_TIMELINE_EVENT_TYPES`).
`overviewRules.ts`: `hotspotStatus` extended (backward-compatible), `isWardDataBacked`.

20 new tests in `incidentRules.test.ts` (142 → 163... actually 163 total, +21 net including the follow-up predicted_incident_reviewed test), 6 new in `overviewRules.test.ts` (21 → 27).

## 5. What was deliberately not changed

- **No migrations** - the two SQL-generated-text bugs (B4's double prefix, B6's raw booleans) are fixed by defensive parsing at display time, not by editing `calculate_incident_source_attribution`.
- **No RLS changes** - no blocker was found that would have required one.
- **No `forecast.py`/ingest changes.**
- **No new datasets.**
- **No baseline forecast relabeled as ML** - B1/B9's fixes reuse the exact same `FORECAST_METHOD_LABEL`/`forecastFallbackStatus` already used elsewhere; nothing here claims a baseline result is ML-validated.
- **Map/Sensors/Analytics/Tasks/Citizens/Settings** - untouched except the two provably-safe shared helpers (`hotspotStatus`, the `AppShell` search bar) and one required type-completeness addition (`HOTSPOT_STATUS_HEX` in `mapMarkers.ts` needed a `stale` entry to keep compiling now that `HotspotStatus` has a new member - Map never triggers it, verified live).

## 6. Tests

New: 20 tests in `incidentRules.test.ts`, 6 in `overviewRules.test.ts`.
Full suite: `npx vitest run` → **234/234 passed** (163 `incidentRules` + 27 `overviewRules` + 25 `forecastTrustRules` + 13 `mapRules` + 6 `readinessRules`).
Typecheck: `npx tsc -b` → clean.
Build: `npx vite build` → succeeds (pre-existing >500kB single-chunk warning, unrelated).

## 7. Live verification

Local dev server against the same production Supabase project, logged in as a real commander account, full console/page-error listeners attached, navigated via real nav links and real incident data (not fixtures).

**Overview**: KPI tile, Priority Alerts, Operational Summary (coverage/ML/baseline stats + latest cycle time), Hotspots table (unit-labelled headers, Mayapuri's "Not assessed", every currently-stale ward correctly showing "Stale reading" instead of "Trending up" - the whole dataset happened to be >3h stale at verification time, which is itself a useful real-world confirmation the rule fires correctly at scale), Field Team Allocation ("Teams available 6", "2 teams" chips) - all rendered correctly, zero console/page errors.

**Incidents**: Opened a real predicted PM10 incident (#6, Dwarka) end-to-end across all 5 tabs:
- Overview: "Forecast - PM10" (matches the incident's own pollutant, not PM2.5), chart caption "Next 47h / µg/m³ · shaded band = uncertainty range", "Forecast error by horizon" with real MAE values, "Method used: Seasonal/hourly baseline (fallback)" with a consistent, non-contradictory fallback-status sentence.
- Evidence: "Citizen Verification × 4" (deduped from 4 identical rows), "AUTOMATED ATTRIBUTION" badge with clean rationale text (no doubled prefix), timeline showing "Attribution recalculated × 8" and "Reviewed × 5" instead of 13 separate rows.
- Source attribution: "Unresolved" hypothesis showing "Insufficient independent evidence" with no percentage bar; data-quality note showing "Available: monitoring readings, wind direction, responsibility registry / Missing: citizen evidence, field evidence" instead of raw t/f; "Recommended next evidence" line with clean single-period text.
- Intervention: existing `taskBlockedReason` empty state (unchanged, already correct).
- Dispatch: "No dispatch yet - No dispatch created yet. This incident cannot be routed until the source is corroborated..." instead of a blank panel.

Also opened the list view across Active/Predicted/Verification/Escalated queues - "SEVERITY UNAVAILABLE" / "ESCALATED BY RULE" badges render correctly, no longer reading as contradictory.

**Smoke (Map/Sensors/Analytics)**: all three load with zero new console/page errors and no visual regression from the prior launch-hardening pass. Map's basemap tiles still don't render locally (pre-existing MapTiler-key/localhost 403, unrelated to this pass, already documented in the prior two reports).

Zero new console or page errors were observed on any page across the entire verification session.

## 8. Remaining known limitations

1. **B4/B6's root causes are SQL bugs, not fixed at the source.** The display-layer fixes are robust (regex-based, defensive, fall back to raw text on an unrecognized shape) but every future row from `calculate_incident_source_attribution` will keep arriving with the double-prefix/raw-boolean quirk until that function is migrated - tracked here for whoever picks up the next migration-permitted pass.
2. **B8's forecast chart has no threshold line** - deliberately, since the only threshold constant in the codebase is PM2.5-specific and this chart renders any pollutant. Revisit if/when per-pollutant thresholds become available client-side.
3. **B11's timeline collapsing is narrow by design** - only two confirmed-safe event types are collapsed. Other real repeated-event patterns (if found later) need the same confirm-first treatment before being added to `COLLAPSIBLE_TIMELINE_EVENT_TYPES`.
4. **Map's ward panel forecast status (from the prior launch-hardening pass) was not re-verified by click in this pass** - same local MapTiler-key limitation as before; not something this pass touched or needed to re-check.

## 9. Launch-readiness verdict

**Overview and Incidents are launch-safe.** Every misleading or contradictory display identified in the brief was traced to a real, verifiable cause (a genuine SQL bug in two cases, a missing staleness check, an ambiguous label, or a component silently returning `null`) and fixed either by adding missing context or by parsing/degrading gracefully around the two backend quirks that can't be fixed without a migration this pass forbids. All fixes were verified against real production incident/ward data, not synthetic fixtures. No fake data was introduced anywhere - every new piece of copy is derived from a real, already-loaded field, and every "not assessed" / "insufficient evidence" / "not yet validated" state is a true absence, stated honestly rather than papered over.

## 10. Files changed

- `web/src/lib/incidentRules.ts` / `.test.ts` — new pure functions (§4)
- `web/src/lib/overviewRules.ts` / `.test.ts` — `hotspotStatus` extended, `isWardDataBacked`
- `web/src/lib/mapMarkers.ts` — required `HotspotStatus` type-completeness addition (`stale`, unreachable from Map)
- `web/src/components/overview/HotspotsRiskTable.tsx` — A2, A3, A4, A5
- `web/src/components/overview/OperationalSummaryPanel.tsx` — A1
- `web/src/components/overview/TeamAllocationPanel.tsx` — A6
- `web/src/components/AppShell.tsx` — A7
- `web/src/components/PredictedIncidentPanel.tsx` — B1, B2, B8, B9
- `web/src/components/incidents/IncidentStatusHeader.tsx` — B2
- `web/src/components/incidents/IncidentDetailPanel.tsx` — B2 (prop wiring)
- `web/src/components/TaskDispatchPanel.tsx` — B3
- `web/src/components/IncidentEvidencePanel.tsx` — B4
- `web/src/components/SourceAttributionPanel.tsx` — B4, B5, B6
- `web/src/components/incidents/EvidenceMissionDialog.tsx` — B7
- `web/src/components/incidents/IncidentListItem.tsx` — B10
- `web/src/components/IncidentTimeline.tsx` — B11
- `docs/data/overview-incidents-launch-ui-fix-report.md` — this report

## 11. Checks

| Check | Result |
|---|---|
| Migrations / RLS / `forecast.py` / ingest changes | **None** |
| New datasets | **None** |
| Tests | 234/234 passing (26 new) |
| Typecheck / build | Clean |
| Live browser check (Overview + Incidents full tab walkthrough + Map/Sensors/Analytics smoke, real login, real production data) | 0 new console/page errors |
| Secret scan | Manual grep across all 18 changed files for `SUPABASE_SERVICE_ROLE_KEY=`, `OPENAQ_API_KEY=`, JWT/`eyJ...`, and the live-verification login credentials — no matches. Credentials were passed only as env vars to ephemeral scratchpad scripts, deleted immediately after use. |
