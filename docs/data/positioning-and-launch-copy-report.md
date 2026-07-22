# Positioning and Launch-Readiness Copy Pass

**Type:** Documentation + UI copy/framing pass — no schema, RLS, ingest, or forecast logic changes.
**Base commit:** `94c3ff2` (Polish login card visuals - no content changes)
**Date:** 2026-07-22

## Summary

Vayu Gati's README and in-app copy were, in places, still readable as "another AQI dashboard." This pass makes the actual positioning explicit everywhere a commander, field officer, or evaluator first encounters the product: **CPCB tells us where pollution is; Vayu Gati helps decide what to do, who should do it, and whether it worked.** No new data sources, no schema changes, no fabricated numbers — every fact added (34 stations, 252 wards, 45k+ readings, forecast coverage) is a number already surfaced live elsewhere in the app (Sensors' Data Readiness card, Overview's Forecast Trust panel).

## Markdown files changed

- **`README.md`** — full rewrite of the opening section:
  - New `## What Vayu Gati Is` — states the product is the action/evidence/accountability layer built on top of monitoring data, not a replacement for CPCB, with the CPCB-vs-Vayu-Gati two-line positioning statement.
  - New `## How Vayu Gati Differs from an AQI Dashboard` — an 11-row comparison table (dashboard capability vs. Vayu Gati capability).
  - New `## Vayu Gati Action Loop` — Monitor → Detect → Predict → Attribute → Verify → Dispatch → Track → Evaluate, one line each.
  - New `## Current Launch Scope` — "Delhi City Pack" framing: an Available list (252 wards, 34 stations, 45k+ readings, PM2.5/PM10/NO2 forecasting with a strict baseline gate — explicitly "never mislabelled as ML" — incident/evidence/dispatch workflows, commander/citizen/field roles) and a Known limitations list (does not replace CPCB; Mayapuri is proxy-only; Pitampura unavailable via OpenAQ; ITO/Pusa pending manual ward review; FIRMS/OSM/weather are planned, not built; source attribution is probable, not confirmed).
  - New `## Why Governments Would Use Vayu Gati` and `## Recommended Demo Flow` (8-step walkthrough).
  - The pre-existing "Phases 0-4 built" content was **not deleted** — it was relabelled `## Project history (Phases 0–4)` with a transition sentence, and a closing note flagging that the setup/deploy instructions further down still describe the original 13-hotspot-ward pilot, not the current ward/station counts. This avoids the file self-contradicting (old "13 hotspots" sitting next to new "252 wards") without an out-of-scope rewrite of the setup/deploy instructions themselves.
  - The Hindi tagline `जानकारी से कार्यवाही तक` / "From information to action" is preserved and now used consistently (README + Login page).

## UI files changed

| File | Change |
|---|---|
| `web/src/pages/Login.tsx` | Added positioning line ("Air-quality response layer for city teams"); added a "Delhi City Pack" pilot-facts card (34 stations / 252 wards / forecast pipeline live — static text, no query on this unauthenticated page); updated the file's own doc comment to reflect this is a deliberate positioning pass, not visual-only. |
| `web/src/pages/CommandView.tsx` | Added "Monitoring data provides the signal. Vayu Gati converts it into incidents, evidence requests, and action workflows." under the Overview header. |
| `web/src/pages/FieldView.tsx` | Empty evidence-mission state now explains *why* it's empty ("Evidence missions appear when the command centre requests field verification.") instead of showing nothing; "No open reports - all clear." → "No assigned field tasks right now." (avoids implying a false all-clear). |
| `web/src/pages/MissionsView.tsx` | Same evidence-mission explainer appended to the field officer's empty missions state. |
| `web/src/lib/incidentRules.ts` | New pure function `actionChainStages()` — derives the 6-stage action-chain status (Detected/Predicted → Likely source → Evidence → Responsible authority → Dispatch → Outcome evaluation) entirely from fields `IncidentDetail` already fetches. No new query. |
| `web/src/components/incidents/ActionChainStrip.tsx` | **New file.** Renders the 6-stage strip in the incident detail pane. |
| `web/src/components/incidents/IncidentDetailPanel.tsx` | Wires `ActionChainStrip` in between the action bar and the tab list. |
| `web/src/lib/incidentRules.test.ts` | 6 new tests for `actionChainStages`. |

### Areas audited and found already compliant (no changes made)

- **Map** — layer labels ("Ward-linked AQI", "AQ station readings", "Forecast alerts", "Suspected source signals") and legend copy already matched the required wording exactly.
- **Source attribution** — "Probable source - not a confirmed violation" and the unresolved-state copy ("Insufficient independent evidence - no source category has enough evidence to be assessed as more likely than others") were already in place from an earlier session's fix; no "Unresolved 100%" pattern exists anywhere.
- **Forecast labels** — `forecastTrustRules.ts`'s existing explainer ("machine learning (LightGBM) only when it beats the strongest of several simple baselines...") is more detailed and equally honest as the task's suggested wording; left unchanged rather than simplified.
- **Sensors** — Data Readiness card and the stale-station disclaimer ("upstream OpenAQ publish delays, or a known gap...not necessarily a broken sensor") were already present.
- **Citizens** — "Citizen reports do not automatically prove a violation..." already present verbatim. Citizen intake is genuinely live (`insertReport` flow exists and works), so no "intake limited" disclaimer was added, per the task's own conditional instruction.
- **Search bar** — already reads "Search disabled in pilot build," not "coming soon."
- App-wide grep for `AI forecast` / `AI-drafted` / `AI-powered` in `web/src/**` returned zero matches. One match exists in README (a citizen-report AI classification note), which describes a real, distinct feature and was left as-is.

## The Incidents action chain (new)

The task asked for the action chain (Detected/Predicted → Likely source → Evidence needed → Responsible authority → Dispatch/blocked reason → Outcome evaluation) to be visually obvious on the Incidents page. This is now a compact strip at the top of every incident's detail pane, with each stage's done/pending state derived from real, already-fetched data:

- **Detected/Predicted** — always done (an incident that exists has been detected or predicted).
- **Likely source** — done when a current source hypothesis exists.
- **Evidence** — done when source confidence has moved past "suspected," *or* a mission has been dispatched (a mission in flight counts even before it changes anything).
- **Responsible authority** — done when `incident.assigned_authority` is set, i.e. the incident has actually been routed (matches the existing "Not routed yet" label already shown elsewhere on the page).
- **Dispatch** — done when at least one intervention exists.
- **Outcome evaluation** — done when the incident is closed, or an impact evaluation exists.

**Bug caught and fixed during live verification:** the first wiring used `IncidentDetail.responsibleAuthority` (a probable *registry match*, which exists as soon as a hypothesis exists — a different, pre-existing concept already used by `dispatchEmptyStateMessage` for a different purpose) instead of `incident.assigned_authority` (whether the incident has actually been routed). This made the strip show "Responsible authority: done" on an incident the panel itself labelled "Not routed yet." Caught by comparing the rendered strip against the panel's own text during the browser smoke check, fixed by rewiring to `incident.assigned_authority != null`, and re-verified live. See `web/src/lib/incidentRules.ts` for the corrected field's doc comment distinguishing the two concepts.

## Tests run

- `npx tsc -b` — clean, no errors.
- `npx vitest run` — **258/258 passed** (169 incidentRules [6 new] + 31 overviewRules + 25 forecastTrustRules + 27 mapRules + 6 readinessRules).
- `npx vite build` — succeeded (`dist/assets/index-*.js` 1.62 MB / 434 kB gzip — same pre-existing >500 kB chunk-size warning as every prior build in this project, unrelated to this change).

## Live browser verification

Logged in as the existing commander test account against the local dev server (Vite, port 5184; MapTiler still 403s locally — a known, pre-existing, prod-only-key limitation, unrelated to this pass, silently falls back to the keyless basemap).

| Surface | Result |
|---|---|
| Login — desktop | New positioning line + pilot-facts card render correctly under the logo/tagline. |
| Login — mobile (390×844) | Same content reflows correctly; layout intact. |
| Overview | New "Monitoring data provides the signal..." line renders under the page title; all KPIs still populate from live data; no regression. |
| Overview — mobile | Header ("Vayu Gati" + bell/help/avatar) and bottom tab bar both present; KPI grid reflows to 2 columns; no console errors. |
| Map | Layer control and legend confirmed to already match required copy; no changes needed; MapTiler 403 is the sole console warning (pre-existing, dev-only). |
| Incidents | List + detail pane both open correctly; new `ActionChainStrip` renders with correct per-stage done/pending state (verified against a real incident, and against the panel's own "Not routed yet" / "Route to authority is unavailable" text after the bug fix above). |
| Sensors | Data Readiness card and stale-station note render as before; no regression. |
| Citizens | "Citizen reports do not automatically prove a violation..." and the linking-rules explainer render as before; no regression. |
| Field officer mobile | **Not tested.** No field-officer or citizen role test credential has been established anywhere in this project's session history — only the commander account (`command@vayugati.test`) is known. Documenting this honestly rather than fabricating a verification. The `FieldView.tsx` / `MissionsView.tsx` copy changes were verified by code read and by the unit/type checks only, not by a live role-specific session. |

No console or page errors were observed on any tested route (excluding the pre-existing MapTiler 403).

## Secret check

Grepped the full diff of every changed/new file for API keys, tokens, passwords, and private-key markers — no matches. `web/.env.local` (gitignored) was not modified. All scratch Playwright scripts that referenced the test login credential were deleted immediately after use; none were committed.

## Remaining known limitations (unchanged by this pass, restated here per the task's own "don't hide limitations" instruction)

- Vayu Gati does not replace CPCB as the regulatory/official monitoring source.
- Mayapuri has no official CPCB/DPCC/IMD station — shown as a proxy, not fabricated.
- Pitampura has no matching OpenAQ location — unavailable, not merely stale.
- ITO and both Pusa stations are on OpenAQ but pending manual ward-boundary review before import.
- FIRMS satellite fire detection, OpenStreetMap source layers, and a dedicated wind/weather map view are planned, not built in this launch.
- Source attribution is probabilistic ("probable source," confidence levels) — never presented as a confirmed violation.
- Field officer and citizen role UI changes in this pass were verified by code/type/unit checks only — not by a live browser session, since no test credential for those roles exists yet.

## Launch-readiness verdict

**Ready**, with one caveat. The README and every audited UI surface now consistently frame Vayu Gati as the action/evidence/accountability layer above CPCB monitoring data, not a competing AQI dashboard — positioning copy, the CPCB-vs-Vayu-Gati distinction, and the action-loop explanation are all in place and match the product's actual current capabilities (no overclaiming, no fabricated data, no "ML" mislabelling of baseline forecasts). Typecheck, full unit suite, and production build are all clean. The one open item is that field-officer and citizen role copy could not be verified in a live browser session for lack of a test credential — the copy itself was still read, reasoned about, and covered by existing type/test checks, but a live check should happen once such a credential exists.

## Files changed (full list)

- `README.md`
- `web/src/pages/Login.tsx`
- `web/src/pages/CommandView.tsx`
- `web/src/pages/FieldView.tsx`
- `web/src/pages/MissionsView.tsx`
- `web/src/lib/incidentRules.ts`
- `web/src/lib/incidentRules.test.ts`
- `web/src/components/incidents/ActionChainStrip.tsx` (new)
- `web/src/components/incidents/IncidentDetailPanel.tsx`

## Checks

| Check | Result |
|---|---|
| `tsc -b` | ✅ clean |
| `vitest run` | ✅ 258/258 |
| `vite build` | ✅ succeeded |
| Live smoke (commander role) | ✅ Login, Overview, Map, Incidents, Sensors, Citizens — desktop + mobile |
| Live smoke (field officer role) | ⚠️ not tested — no test credential available |
| Console/page errors | ✅ none (excl. pre-existing MapTiler 403) |
| Secret grep | ✅ none found |
| `git status` matches intended file set | ✅ |
