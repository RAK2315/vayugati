# Delhi Ward Boundary Import — Phase 2 Report

**Type:** Executed import report. This phase wrote real data to the live hosted Supabase project (`xpinidergyqkunoiukal`) via a migration and an idempotent import script — see [Section 7](#7-what-was-changed) for the exact scope, and [Section 8](#8-risks-and-limitations) for what to watch for.
**Date:** 2026-07-20
**Prerequisite:** [docs/data/delhi-ward-251-review.md](delhi-ward-251-review.md) (validated the source GeoJSON and identified `FID=53`/`Ward_No=0` as an artifact to exclude).

---

## 1. Summary

**250 real MCD ward boundaries were imported into the live `wards` table**, upserted by `(city_id, ward_number)`, alongside — not replacing — the 13 existing seeded hotspot wards. The known `Ward_No=0` artifact was excluded exactly as recommended. The import is idempotent (verified by running it twice; the second run wrote zero new rows). Existing app behavior (Overview, Incidents, the admin Registry form) is unchanged, verified both by design (a new `is_hotspot` filter) and by a live browser check. The Map page's "Ward boundaries" layer is now real, Supabase-backed, and enabled — verified rendering actual ward polygons with click-to-select detail.

## 2. What was imported

| Metric | Value |
|---|---|
| Total features read from `delhi_wards.geojson` | 251 |
| Included (Ward_No 1–250, clean) | **250** |
| Excluded (Ward_No = 0, known artifact, `FID=53`) | **1** |
| Rejected (missing/non-numeric/duplicate/missing-name) | 0 |
| Duplicate Ward_No values found | none |
| Name collisions against the 13 seeded hotspot wards | none |
| Delhi `city_id` used | 1 (`city_config.city_code = 'delhi'`) |

## 3. Database changes

**Migration:** `supabase/migrations/20260731000000_delhi_ward_boundaries_import_support.sql` — additive only:
- `wards.ward_number int` (null for the 13 seeded hotspot wards; 1–250 for imported wards)
- `wards.zone text` (null everywhere — no real zone field exists in the source, not fabricated)
- `wards.metadata jsonb not null default '{}'::jsonb` (`{}` for the 13 seeded wards; `{source_fid, total_pop, sc_pop, ac_no, ac_name, source_document}` for imported wards)
- `wards_city_ward_number_key` unique index on `(city_id, ward_number)` — a plain (non-partial) index; Postgres never treats two `NULL`s as equal for uniqueness, so the 13 existing rows (all `ward_number = null`) coexist under it without any special-casing.

Verified via the full local RLS/workflow test suite (`supabase/tests/run.sh`, 150+ assertions, all pass) before being pushed to the hosted project. `web/src/lib/database.types.ts` was regenerated from that same disposable Postgres and matches what CI's own regeneration step produces — zero drift.

**Data written:** 250 new `wards` rows, `is_hotspot = false`, `boundary` set to the real GeoJSON polygon/multipolygon geometry, `name` = the source's `WardName` (original case preserved, e.g. `"NARELA"`), `ward_number` = the source's `Ward_No`.

## 4. Live verification (post-import)

Queried directly against the hosted project:

| Check | Result |
|---|---|
| Total `wards` rows | 263 (13 original + 250 imported) |
| Imported rows (`is_hotspot = false`) | 250 |
| Original hotspot rows (`is_hotspot = true`) | 13, **completely untouched** — `ward_number` still null, `boundary` still null on every one |
| Unique `ward_number` among imported rows | 250 (no duplicates) |
| `ward_number` range | 1–250 (no gaps, `0` correctly absent) |
| Imported rows with null `metadata` | 0 |
| Re-running the import a second time | **0 new rows written** — confirmed idempotent |

## 5. Frontend changes

| File | Change |
|---|---|
| `web/src/lib/data.ts` | `fetchAllWardsAqi()` now filters `is_hotspot = true` — Overview, Incidents, and the admin Registry form (its only 3 callers) keep seeing exactly the same 13 wards as before this phase, unchanged. New `fetchAllWardBoundaries()` fetches every ward with a non-null `boundary` (all 250 imported wards today; would include hotspot wards too if they're ever given a boundary later), used only by the Map's new polygon layer. |
| `web/src/components/MapView.tsx` | Added a real MapLibre GeoJSON source + fill/line layers for ward boundaries (`wardBoundaries`, `showWardBoundaries`, `selectedBoundaryId`, `onBoundaryClick` props) — survives basemap switching (re-added on every `style.load`), click-selects a polygon, highlights the selected one. No hardcoded polygon data anywhere. |
| `web/src/components/map/MapLayerControl.tsx` | "Ward boundaries" toggle now enables itself via a `wardBoundariesAvailable` prop, driven entirely by whether Supabase actually returned boundary rows — never a hardcoded flip. |
| `web/src/components/map/SelectedWardBoundaryPanel.tsx` (new) | Lightweight panel shown when a boundary polygon (not a monitored hotspot marker) is clicked — name + ward number only, explicitly notes it has no monitoring data, never fabricates AQI/forecast info for wards that don't have any. |
| `web/src/pages/MapPage.tsx` | Wires the above together: fetches boundaries alongside existing data, builds the GeoJSON feature collection, routes polygon clicks to the new panel. |

**A real bug was caught and fixed during verification**: the boundary source/layers were only ever created inside the map's one-time mount effect, which usually runs before the async ward-boundary fetch resolves — so on first load, nothing was ever added, and the separate data-update effect only called `.setData()` on a source that didn't exist yet. Fixed by sharing one `ensureBoundaryLayers()` function (create-if-missing, else update) between the mount effect, style-swap re-adds, and the data-arrival effect. Confirmed fixed by zooming into the live map and seeing real polygons render.

## 6. Browser verification

Signed in as `command@vayugati.test` against the live post-import data:

- **Map page**: "Ward boundaries" toggle is enabled (no longer greyed out). Zooming in shows real MCD ward polygons (e.g. Karam Pura, ward 89) with correct outlines matching actual street geography. Clicking a polygon highlights it and opens `SelectedWardBoundaryPanel` showing the correct name and ward number, with an honest "no monitoring station" note. Zero page errors, zero console errors.
- **Overview page**: "Hotspots & Forecast Risk" table still shows exactly the original 13 hotspot wards (Punjabi Bagh, Bawana, Wazirpur, Jahangirpuri, Rohini, Dwarka, ...) — confirmed unaffected by the 250 new rows.
- **Incidents page**: ward data is consumed as an id→AQI lookup map (not a dropdown), so the extra 250 wards have no visible effect there either — confirmed by reading the actual code path, not just the UI.
- **Pre-migration sanity check** (run before the migration was pushed, for comparison): confirmed the app didn't crash even when `fetchAllWardBoundaries()` queried not-yet-existing columns — supabase-js returns `{data: null, error}` rather than throwing, and the code already handled a null/empty result gracefully.

## 7. What was changed

Touched: `supabase/migrations/20260731000000_delhi_ward_boundaries_import_support.sql` (new), `web/src/lib/database.types.ts` (regenerated), `web/src/lib/data.ts`, `web/src/components/MapView.tsx`, `web/src/components/map/MapLayerControl.tsx`, `web/src/components/map/SelectedWardBoundaryPanel.tsx` (new), `web/src/pages/MapPage.tsx`, `scripts/import-delhi-wards.ts` (new), `package.json` + `package-lock.json` (root, new `import:delhi-wards` script and its dependencies), `tsconfig.json` (new, root-level, scoped to `scripts/`).

**Not touched**: RLS policies (none added/changed — the existing `wards_read` policy already covers the new columns), any other page, any other table, the 13 seeded hotspot wards' own data.

## 8. Risks and limitations

- **250 non-hotspot wards now exist in a table other code might one day query without the `is_hotspot` filter.** Every current caller goes through `fetchAllWardsAqi()`, which now filters correctly — but any *future* code that queries `wards` directly (bypassing that function) needs to remember this table now holds both monitored hotspots and boundary-only municipal wards. Worth a comment or a code-review checklist item, not something this phase can fully prevent.
- **`ward_number`/`WardName` casing is preserved as-is from the source** (mostly uppercase, e.g. `"NARELA"`) — this looks visually different from the 13 hotspot wards' title-case names (`"Narela"`). Cosmetic, not a data-correctness issue, but worth knowing if the two sets are ever displayed together.
- **No name-based linkage between the 13 hotspot wards and their corresponding municipal ward polygon** was attempted in this phase (e.g. hotspot "Narela" and imported ward `Ward_No=1` "NARELA" are two separate, unlinked rows). If the product wants a hotspot marker to visually sit inside its own real boundary, that's a follow-up matching exercise, not done here.
- **The `Ward_No=0` feature remains excluded and unresolved** — still requires the manual follow-up recommended in `delhi-ward-251-review.md` (checking against an authoritative current MCD ward map), not something this import phase could resolve on its own.

## 9. Success criteria check

| Criterion | Status |
|---|---|
| Exactly 250 Delhi wards imported | ✅ (250 rows, `is_hotspot=false`) |
| `FID=53`/`Ward_No=0` excluded and reported | ✅ |
| Import is idempotent | ✅ (verified by a real second run — 0 new rows) |
| Ward boundary layer works on Map | ✅ (real polygons render, click-select works) |
| No fake geometry | ✅ (every polygon is the real source geometry, untouched) |
| No RLS or unrelated app breakage | ✅ (Overview/Incidents/Registry form all verified unchanged; no RLS policy touched) |
