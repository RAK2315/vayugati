# Final Overview Fix — Transport Data Binding, Compact Layout, Feed Health

**Type:** Bug fix + UI polish on top of the source-aware redesign. No backend logic, RLS, migrations, ingest jobs, forecast.py, or API-client changes.
**Date:** 2026-07-22

## The bug: "Transport activity data unavailable" despite a live backend

### Root cause

Overview's Refresh button only called `state.refresh()` and `forecastsState.refresh()` — it never called `transitState.refresh()` or `latestReadingsState.refresh()`. Both of those fetch once on mount (`useAsync(..., [])`) and never automatically retry.

The ingest service's `run_transit()` and `run_cpcb_reconcile()` jobs run once on service bootstrap, *after* the slower `run_ingest → run_intel → run_ops` chain, and then on a 5/10-minute schedule. If a user loaded Overview before that first bootstrap cycle reached `run_transit()`, the endpoint legitimately returned:

```json
{"unavailable_reason": "Not yet refreshed since service start", "live_buses_tracked": null, "per_ward": []}
```

— reproduced directly by curling `/transit/activity` immediately after starting the service. Because the Refresh button never re-fetched this endpoint, the page stayed on that first, stale response **forever**, even though the backend caught up moments later and `/transit/activity` was already returning 5,000+ live vehicles when checked directly.

### Fix

1. `CommandView.tsx`, `MapPage.tsx`, and `SensorsView.tsx`'s Refresh buttons now call every independent `useAsync` fetch on the page (`transitState.refresh()`, `latestReadingsState.refresh()`, and on Sensors also `footprintState`/`forecastAccuracyState`) — not just the main data bundle. Same class of bug existed on Map and Sensors too (added before it caused an identical, unreported symptom there).
2. `TransportActivityPanel` gained a direct **Retry** button in its unavailable state, so a user doesn't need to know the page-level Refresh button now covers this — it's an obvious, local recovery action.

### Verified

- Cleared `/transit/activity` on a freshly started service → confirmed the exact `"Not yet refreshed since service start"` response.
- Triggered `POST /transit/refresh` (what the fixed button's re-fetch now benefits from) → confirmed a real payload: 5,503 live buses, 1,314 routes, 13 wards scored.
- Live in the browser: Transit column populated on every Hotspot table row, Transport Activity Context card showing real numbers, zero console errors.
- As a live illustration of exactly why this fix matters: during this same verification session, one scheduled `run_cpcb_reconcile()` cycle hit a transient Supabase disconnect (`httpx.RemoteProtocolError: Server disconnected`) and returned an empty reconciliation for that cycle — already handled gracefully by the existing `except Exception` fallback, but previously **unrecoverable from the UI** without a full page reload. The same fix now lets a user recover with one click.

## A second, related bug found during verification: misleading "Stale" confidence

While visually verifying the new Hotspot table columns, several wards using a **fresh** CPCB reading (`AQ Source: CPCB`) were shown as `Confidence: Stale` — which is actively misleading, not just imprecise: a commander reading "Stale" next to a CPCB-sourced value would reasonably assume *that* reading is old, when it wasn't.

**Cause:** `dataConfidenceLevel()` checked *both* `cpcb_stale` and `openaq_stale` flags regardless of which source was actually being displayed. Since 31 of 34 stations' OpenAQ feed happened to be genuinely stale at the time (matches the Feed Health card's own "31 stale" independently), nearly every CPCB-sourced row inherited a false "Stale" from the *unused* OpenAQ side.

**Fix:** confidence now only checks the staleness flag of the source actually in use (`cpcb_stale` when `sourceUsed === 'cpcb'`, `openaq_stale` otherwise). By construction, `reconcile_latest()` never selects `sourceUsed: 'cpcb'` while `cpcb_stale` is set, so this isn't a hypothetical edge case — it was actively firing on real, current data. Re-verified live: the same wards now correctly show `Confidence: Matched`.

## Other fixes in this pass

1. **AQ Source / Data Confidence columns** on the Hotspot table (`CPCB` / `OpenAQ` / `Review`, `Matched` / `Stale` / `Mismatch` / `No data`) — the columns from the prior redesign pass, now confirmed rendering with real per-ward badges.
2. **Footer condensed** to one line — *"Latest readings: CPCB/data.gov preferred · OpenAQ fallback · AQI computed using CPCB breakpoints."* — with the previous three paragraphs of explanation moved into a click-toggle info popover (an `Info` icon button, not a bare hover title, so it works on touch too).
3. **Priority Alerts no longer stretches to a mostly-empty card.** The alerts/summary row used CSS Grid's default `align-items: stretch`, so a one-line "No wards predicted..." card was forced to match Operational Summary's full height. Added `items-start` to that grid row — each card now sizes to its own content.
4. **Operational Summary tightened**: the "Active dispatch SLA" section now collapses to a single "No active dispatches right now." line when all four buckets are zero (previously always rendered 4 zero-value tiles), and internal spacing was trimmed (`space-y-4`→`space-y-3`, a few `mt-3`→`mt-2`).
5. **"Sensor Health" → "Feed Health"** (the Overview card, distinct from the Sensors page rename in the prior pass) — now also shows a compact `N CPCB · N OpenAQ fallback` line above the existing fresh/stale/inactive bar.
6. **Source Mix donut**: unchanged, as requested.
7. **Header**: unchanged, as requested — still Refresh/notification/profile only, no search/help re-added.

## Files changed

`web/src/pages/CommandView.tsx`, `web/src/pages/MapPage.tsx`, `web/src/pages/SensorsView.tsx`, `web/src/lib/latestReadingRules.ts` (+ tests), `web/src/components/overview/TransportActivityPanel.tsx`, `web/src/components/overview/HotspotsRiskTable.tsx`, `web/src/components/overview/OperationalSummaryPanel.tsx`, `web/src/components/overview/SensorHealthSnapshot.tsx`, `web/src/lib/overviewRules.ts` (+ tests).

## Verification

- **Overview shows live transit values when the backend has them**: confirmed live (5,558–5,559 buses / 1,321–1,323 routes across repeated checks — real fleet counts fluctuate between calls, not a bug).
- **Transit card no longer says "unavailable" when data exists**: confirmed; Retry button verified as a working fallback path too.
- **Hotspot table shows AQ Source and Confidence**: confirmed, including the corrected (non-misleading) confidence values.
- **No fake data**: every figure traced to a real `GET /readings/latest` or `GET /transit/activity` field; "—" shown wherever a summary hasn't loaded.
- **No console errors**: confirmed across Overview (top + scrolled), Sensors (list + detail panel).
- **`tsc -b`**: clean. **`vitest run`**: 291/291 (23 new in `latestReadingRules.test.ts`, 2 new in `overviewRules.test.ts`). **`vite build`**: succeeds.
- **Missing-key / API-failure graceful behavior**: unchanged from the prior integration pass (not touched by this fix) — re-confirmed indirectly via the live transient-Supabase-disconnect event during this same verification session, which degraded to an empty (not crashed) reconciliation exactly as designed.

## Known limitations carried forward

- The Refresh-button fix re-fetches the *last completed* backend cycle; it does not force an immediate new fetch from CPCB/Delhi OTD (that stays on the existing 5/10-minute schedule, unchanged per "do not change ingest jobs"). A user clicking Refresh seconds after a failed cycle may need to wait for the next scheduled attempt.
- "Timestamp mismatch" on the Sensors page's new stat currently reads high (34/34 in one live check) because OpenAQ's own feed is broadly stale right now (31/34, independently confirmed by Feed Health) — a real, honest signal of the two sources' different update cadences, not a computation bug.
