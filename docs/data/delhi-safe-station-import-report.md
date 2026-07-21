# Delhi Safe Station Import Report

**Type:** Targeted, idempotent config/data import. No migrations created, no RLS touched, no UI changed, no station fabricated, no `OPENAQ_API_KEY` printed or logged.
**Date:** 2026-07-21
**Follows on from:** [`delhi-station-geospatial-ward-assignment.md`](delhi-station-geospatial-ward-assignment.md) (the 15-safe / 3-manual-review / 0-unresolved classification)

---

## 1. Summary

**19 → 34 stations.** Imported all 15 geometrically-safe stations from the audit's point-in-polygon classification — no name guessing, ward assignment taken directly from real polygon containment against the 252 imported ward boundaries. **+19,834 readings, zero duplicates, zero data-quality issues**, verified with a full (paginated, not sampled) scan. The 3 "needs manual review" stations (ITO, Pusa DPCC, Pusa IMD) were **not** imported, exactly as instructed. Mayapuri and Pitampura are unchanged — still honestly unresolved/unavailable, nothing fabricated.

One real hiccup during the run: OpenAQ's rate limit (429) hit partway through the first backfill batch, leaving 5 of 15 stations incomplete (4 not created at all, 1 created with zero readings). Retried with a longer pause between requests — all 5 completed cleanly on the second attempt, confirmed via direct Supabase inspection, not just trusting the script's log output.

---

## 2. Pre-import verification

**Ward boundary count reconciled:** Supabase has 252 `wards` rows with non-null `boundary`, not 250. Confirmed exactly why: **250 MCD wards + 1 `New Delhi (NDMC)` + 1 `Delhi Cantonment`** (the latter two added in a later import phase than the original 250 MCD wards, per `wards.metadata.jurisdiction_type`: 250 rows `mcd`, 1 `ndmc`, 1 `cantonment`). Not a discrepancy or data-quality problem — the audit's "252" was correct and now explained.

**Duplicate check on the 252 boundary rows (before importing anything):** 0 duplicate `name` values, 0 duplicate `ward_number` values, exactly 2 rows with `ward_number IS NULL` (`New Delhi (NDMC)` and `Delhi Cantonment` — expected, since they're not MCD wards and were never assigned an MCD ward number). Clean; nothing blocked the import.

**Baseline snapshot before any writes:** 19 stations, 25,109 total readings. All 15 target OpenAQ ids (5626, 5622, 5630, 5586, 6934, 6957, 6929, 6358, 8365, 10484, 5541, 5627, 5650, 5634, 5610) confirmed absent from Supabase's existing `external_ref` set — zero overlap, no duplicate-station risk going in.

**Live re-verification:** all 15 OpenAQ locations re-confirmed live and reporting 2026-07 data immediately before writing `stations.yaml` (read-only `get_location`/`get_latest` calls) — re-checked rather than trusted from the older audit report, consistent with this project's established pattern.

---

## 3. `stations.yaml` changes

15 new entries appended (full diff is the only file changed for this step). Each `ward:` is the exact `wards.name` string the point-in-polygon audit matched — verified byte-for-byte against Supabase before writing, not retyped from memory.

| Station | OpenAQ id | Ward assigned |
|---|---|---|
| DTU, New Delhi | 5626 | `POOTH KHURD` |
| NSIT Dwarka, New Delhi | 5622 | `KAKROLA` |
| Shadipur, New Delhi | 5630 | `MOTI NAGAR` |
| Siri Fort, New Delhi | 5586 | `CHIRAG DELHI` |
| Dr. Karni Singh Shooting Range, Delhi | 6934 | `SANGAM VIHAR-B` |
| Jawaharlal Nehru Stadium, Delhi | 6957 | `ANDREWS GANJ` |
| Nehru Nagar, Delhi | 8365 | `LAJPAT NAGAR` |
| Sri AurobindoMarg | 10484 | `HAUZ KHAS` |
| Burari Crossing, New Delhi | 5541 | `DHIRPUR` |
| CRRI Mathura Road, New Delhi | 5627 | `SRI NIWAS PURI` |
| North Campus, DU, New Delhi | 5610 | `BALJEET NAGAR` |
| Major Dhyan Chand National Stadium, Delhi | 6929 | `New Delhi (NDMC)` — flagged, see §4 |
| MandirMarg, New Delhi | 6358 | `New Delhi (NDMC)` — flagged, see §4 |
| IGI Airport Terminal - 3, New Delhi | 5650 | `New Delhi (NDMC)` — flagged, see §4 |
| Lodhi Road, New Delhi | 5634 | `New Delhi (NDMC)` — flagged, see §4 |

**Not added** (per explicit instruction): ITO, Pusa (DPCC), Pusa (IMD) — remain absent from `stations.yaml`, exactly as before this pass.

## 4. `geometry_matched_but_admin_boundary_needs_review` warning

The 4 stations matched into `New Delhi (NDMC)` (wards.id=516) each carry an inline comment tag in `stations.yaml`:

```yaml
  - ward: New Delhi (NDMC)
    openaq_location_id: 6929   # Major Dhyan Chand National Stadium, Delhi - DPCC
                                # geometry_matched_but_admin_boundary_needs_review
```

Same tag on the MandirMarg, IGI Airport Terminal-3, and Lodhi Road entries. A longer explanation sits just above the four entries: the point-in-polygon match itself is correct and safe (each station's coordinate is genuinely, unambiguously inside this polygon) — what needs review is that the polygon named `New Delhi (NDMC)` is actually OSM's much larger "New Delhi District" (admin_level 5, ~162 km²), not the true NDMC municipal jurisdiction (~43 km²), per its own `metadata.osm_official_name`. Four stations spread across a real ~11km span (Lodhi Road to IGI Airport) now share this one ward for forecasting purposes. Imported as-is, per the audit's own "safe" classification — flagged for whoever next touches ward-level forecast attribution for this ward, not blocked here.

## 5. Skipped: 3 manual-review stations, Mayapuri, Pitampura

- **ITO, Pusa (DPCC), Pusa (IMD)** — not imported. Still require a human decision on a higher-precision source per the geospatial audit (ITO's ~30m boundary margin; both Pusa stations landing inside two genuinely-overlapping ward polygons). No change to `stations.yaml` for these three.
- **Mayapuri** — unchanged, still `openaq_location_id: null` with its existing explanatory comment. No official CPCB/DPCC/IMD station exists for it and none was fabricated here either.
- **Pitampura** — unchanged, still absent from `stations.yaml` entirely. No OpenAQ match exists.

## 6. Dry-run (before writing)

For all 15 candidates: confirmed (a) not already in Supabase by `external_ref`, (b) each matched ward name exists in `wards`, (c) live OpenAQ metadata resolves. Estimated row counts via a live `get_sensor_hours` probe on each station's pm25 sensor (60-day window) — estimates ranged 1,181–1,333 rows, closely matching the real run's actual per-station totals (1,288–1,346). Dry-run was clean; proceeded to the real import.

## 7. Backfill results (including the mid-run rate limit)

**First run** (`--days 60`, default pause) — 15 stations targeted:

```
== done: 13252 hourly rows across 15 station(s) written ==
```

10 of 15 completed cleanly. The other 5 hit OpenAQ's rate limit partway through:
- **`BALJEET NAGAR`** (North Campus, DU): the station row *was* created (its metadata fetch succeeded before the limit hit), but all per-sensor historical requests then 429'd — **0 readings** written.
- **`New Delhi (NDMC)`** × 4 (Major Dhyan Chand, MandirMarg, IGI Airport T3, Lodhi Road): each one's very first OpenAQ call (station metadata) hit 429 — **no station row created at all** for any of the four.

Verified directly against Supabase (not inferred from the log) that this was exactly the state: station count was 30, not 34, after the first run.

**Second run** (`--days 60 --pause 2.0`, targeting only the 5 incomplete stations) — completed cleanly, no further 429s:

```
== done: 6582 hourly rows across 5 station(s) written ==
```

`BALJEET NAGAR` correctly found its existing station row (no "+ registered" line, no duplicate) and backfilled 1,326 rows. The 4 `New Delhi (NDMC)` stations were freshly created (one station row each, correctly sharing `ward_id=516`) and backfilled.

**Combined total: 13,252 + 6,582 = 19,834 rows**, matching the final row-count delta exactly (§8).

## 8. Validation

**Row counts:**

| | Before | After | Δ |
|---|---|---|---|
| `stations` | 19 | 34 | +15 |
| `readings` (total) | 25,109 | 44,943 | +19,834 |

**Existing 19 stations untouched:** every one of the 19 pre-existing stations' reading counts is byte-identical before and after this entire import (checked programmatically against a pre-run snapshot, 0 mismatches) — nothing was overwritten or disturbed.

**No duplicate stations:** 34 stations, 34 distinct `external_ref` values, 0 duplicates.

**Full (paginated, not sampled) data-quality scan of all 19,834 new rows, per station:**

| Station | Rows | Duplicate (station_id,ts) | Misaligned timestamps | Negative values | Date range |
|---|---|---|---|---|---|
| DTU | 1,344 | 0 | 0 | 0 | 2026-05-22 → 2026-07-21 |
| NSIT Dwarka | 1,306 | 0 | 0 | 0 | 2026-05-22 → 2026-07-21 |
| Shadipur | 1,344 | 0 | 0 | 0 | 2026-05-22 → 2026-07-21 |
| Sirifort | 1,343 | 0 | 0 | 0 | 2026-05-22 → 2026-07-21 |
| Dr. Karni Singh Shooting Range | 1,295 | 0 | 0 | 0 | 2026-05-22 → 2026-07-21 |
| Jawaharlal Nehru Stadium | 1,299 | 0 | 0 | 0 | 2026-05-22 → 2026-07-21 |
| Nehru Nagar | 1,342 | 0 | 0 | 0 | 2026-05-22 → 2026-07-21 |
| Sri Aurobindo Marg | 1,323 | 0 | 0 | 0 | 2026-05-22 → 2026-07-21 |
| Burari Crossing | 1,310 | 0 | 0 | 0 | 2026-05-22 → 2026-07-21 |
| CRRI Mathura Road | 1,346 | 0 | 0 | 0 | 2026-05-22 → 2026-07-21 |
| North Campus, DU | 1,326 | 0 | 0 | 0 | 2026-05-22 → 2026-07-21 |
| Major Dhyan Chand National Stadium | 1,339 | 0 | 0 | 0 | 2026-05-22 → 2026-07-21 |
| Mandir Marg | 1,288 | 0 | 0 | 0 | 2026-05-22 → 2026-07-21 |
| IGI Airport (T3) | 1,320 | 0 | 0 | 0 | 2026-05-22 → 2026-07-21 |
| Lodhi Road | 1,309 | 0 | 0 | 0 | 2026-05-22 → 2026-07-21 |
| **Total** | **19,834** | **0** | **0** | **0** | |

**Pollutant coverage:** all 6 pollutants (`pm25/pm10/no2/so2/co/o3`) present with plausible null rates per station (a null means that hour's sensor didn't report, not a mapping error). **5 of the 15 (Burari Crossing, CRRI Mathura Road, North Campus DU, IGI Airport T3, Lodhi Road — all IMD-operated) have `so2` null in effectively every row** — consistent with the same pattern already documented for Aya Nagar in the prior expansion report: these IMD stations simply aren't instrumented for SO₂, not a data defect.

**Idempotency, verified by actually re-running, not just reasoning about it:** re-ran the backfill for 5 of the 15 stations (including all 4 sharing the `New Delhi (NDMC)` ward — the case most likely to reveal a duplication bug). Station count stayed at 34 (no new rows created, no "+ registered" log lines), every re-checked station's reading count was byte-identical before and after, and the database-wide total stayed at 44,943. The upsert-on-`(station_id, ts)` pattern holds exactly as it has in every prior pass.

## 9. Checks

| Check | Result |
|---|---|
| `ingest` Python tests (`pytest`) | **37 passed** |
| `web` typecheck + build (`tsc -b && vite build`) | **Passed** |
| `web` unit tests (`vitest run`) | **176 passed** |
| Secret scan | No dedicated scanner installed; manual grep for `SUPABASE_SERVICE_ROLE_KEY=`, `OPENAQ_API_KEY=`, JWT/`eyJ...`, `sk-...` across the changed file and this report — no matches. `.env`/`.env.local` confirmed git-ignored. |

Only `ingest/stations.yaml` and this report changed — no UI, schema, or RLS files touched.

## 10. Final readiness for forecast audit

- **Delhi station universe now stands at 34** (19 before this pass + 15 here), all with real 60-day backfills clearing `forecast.py`'s `MIN_TRAIN_ROWS = 240` threshold with wide margin (lowest count: 1,288, Mandir Marg — still ~5.4x the threshold).
- **3 official Delhi stations remain deliberately unimported** (ITO, Pusa DPCC, Pusa IMD) pending a human call on the near-boundary/overlap cases the geospatial audit flagged.
- **1 open data-modeling question**: whether the 4 stations sharing the oversized `New Delhi (NDMC)` polygon should eventually be split into more granular wards (would need better boundary data for that specific jurisdiction, not something this pass can produce).
- **Mayapuri and Pitampura remain honest, structural gaps** — no station, nothing fabricated, unchanged from every prior report in this series.

Recommended next step: a forecast-readiness audit (mirroring `openaq-backfill-verification.md`'s structure) confirming `forecast.py` trains real per-ward models for all 15 newly-added wards, same as already verified for the earlier cohorts.
