# Source-Aware UI Redesign — Overview, Map, Sensors, Hotspot Triage

**Type:** UI redesign surfacing real backend data already exposed by the CPCB/data.gov and Delhi OTD integrations. No backend logic, RLS, migrations, ingest jobs, forecast.py, or API-client changes.
**Date:** 2026-07-22

## Summary

Vayu Gati's Overview, Map, Sensors, and the Operational Hotspot Triage table now visibly reflect the CPCB/data.gov-preferred / OpenAQ-fallback reconciliation and the Delhi OTD transport-activity layer, both already live on the ingest service from the prior integration pass. Every number shown is a real value already returned by `GET /readings/latest` or `GET /transit/activity` — nothing here adds a new fetch, a new backend concept, or a fabricated figure.

## What was added

### 1. Overview header (kept minimal, per spec)
- Title unchanged: **Delhi City Pack**
- Subtitle updated to: *Air response command centre · Official AQ readings, forecast risk, and action tracking.*
- No search/help/extra branding text re-added — header stays profile + notification only.

### 2. Operational Hotspot Triage
- Controls (AQI/PM2.5/PM10/NO2, 12h/24h/36h/48h) stay in the table's own header, unchanged.
- Two new columns, short labels: **AQ Source** (`CPCB` / `OpenAQ` / `Review`) and **Confidence** (`Matched` / `Stale` / `Mismatch` / `No data`) - both derived from the same `LatestReadingReconciliation` row already keyed by ward.
- Transit column (already present from the prior pass) confirmed working.

### 3. Data Source Confidence strip (new)
A compact strip between the Hotspot table and the alerts/summary row:
- CPCB/data.gov matched: **X**
- OpenAQ fallback: **Y**
- Forecast history: **OpenAQ** (static label - forecast.py's training input never changes)
- Delhi OTD: **X vehicles / Y routes**
- Stale or mismatch flags: **Z**

### 4. Transport Activity Context card
- Live buses tracked / Active routes (already present).
- New: **High-risk hotspots with transit activity** - wards that are both currently severe/trending-up (`wardsNeedingReview`, generalized from a count-only helper into one that also returns the list) AND have real nearby transit activity - a genuine cross-reference of two already-fetched summaries, empty/hidden when nothing qualifies.
- Disclaimer unchanged: *"Context layer only — not proof of emissions or congestion."*

### 5. Map
- Public Transport Activity layer: unchanged (already live from the prior pass).
- New: a small accent-blue dot (bottom-left corner) on station markers when CPCB/data.gov is the confirmed, fresh source - added to `MapMarker`/`createMarkerElement`, documented in the legend.
- Station popup and detail panel now show all three required lines: **Latest source**, **Forecast history: OpenAQ**, **AQI computed using CPCB breakpoint logic** (this is the same `aqi.py` breakpoint function already used for every AQI value in this app, CPCB-derived or not - shown unconditionally since it's honestly true either way).

### 6. Sensors → "Data Feeds & Station Health"
- Page renamed; description updated to name both feeds.
- New KPI row: CPCB/data.gov matched, OpenAQ fallback, Timestamp mismatch, Value mismatch, Unmatched/stale - all real counts over the same reconciliation rows.
- Existing station table/detail panel (already showing per-station source dots from the prior pass) unchanged.

## Files changed

New: `web/src/lib/latestReadingRules.ts` (+ tests), `web/src/components/overview/DataSourceConfidenceStrip.tsx`.
Modified: `web/src/lib/overviewRules.ts` (+ tests, `wardsNeedingReview` list function), `web/src/pages/CommandView.tsx`, `web/src/components/overview/HotspotsRiskTable.tsx`, `web/src/components/overview/TransportActivityPanel.tsx`, `web/src/components/overview/SensorHealthSnapshot.tsx`, `web/src/lib/mapMarkers.ts`, `web/src/pages/MapPage.tsx`, `web/src/components/map/SelectedStationPanel.tsx`, `web/src/components/map/MapLegend.tsx`, `web/src/pages/SensorsView.tsx`.

## Required/forbidden label audit

Grepped the full diff: zero matches for "Official CPCB AQI", "Traffic pollution", "Bus emissions", "Confirmed source". All four required labels present verbatim across Overview/Map/Sensors: `Latest readings: CPCB/data.gov preferred · OpenAQ fallback`, `Forecast history: OpenAQ`, `Public transport activity via Delhi Open Transit Data`, `AQI computed using CPCB breakpoint logic`.

## Verification

- `tsc -b` clean; `vitest run` 291/291 (35 new: `latestReadingRules` 23 + `overviewRules` additions 2 + others); `vite build` succeeds.
- Live-verified end to end (see the companion bug-fix report for the details and a real backend/frontend run) - the earlier "Transport activity data unavailable" symptom and its root cause are covered there, since it was found and fixed as part of finishing this same redesign.
