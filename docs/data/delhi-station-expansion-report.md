# Delhi Official CAAQMS Station Expansion Report

**Type:** Targeted, idempotent config/data expansion. No migrations created, no RLS touched, no UI changed, no station fabricated, no `OPENAQ_API_KEY`/`SUPABASE_SERVICE_ROLE_KEY` printed or logged.
**Date:** 2026-07-21
**Follows on from:** [`delhi-station-reconciliation.md`](delhi-station-reconciliation.md) and [`station-config-repair-report.md`](station-config-repair-report.md)

---

## 1. Summary

Starting from **12 loaded stations**, added **7 more official Delhi CAAQMS stations** — every station that (a) is in the CPCB reference's 38-station Delhi list, (b) has a verified-live OpenAQ location, and (c) has a safe, non-guessed ward to attach to in this codebase's schema. **19 stations are now loaded, 25,068 total readings (+9,175 from this pass), zero duplicates, zero data-quality issues.** All 12 pre-existing stations are confirmed byte-identical (same row counts) — nothing was overwritten or disturbed.

**18 further official Delhi stations are verified live on OpenAQ but were deliberately *not* imported** — none of them has a ward name in this app's `wards` table that matches without guessing (see §5). They're flagged "needs manual review," not silently skipped. **1 station (Pitampura) has no OpenAQ match at all.** **Mayapuri remains unresolved**, as instructed — no station exists for it, none was fabricated.

## 2. Official Delhi station universe

`data/delhi/processed/cpcb_caaqms_station_reference.csv` lists **38 official Delhi-city stations** (6 CPCB, 24 DPCC, 8 IMD) among its 79 total rows (the other 41 are wider-NCR — Haryana/UP/Rajasthan — correctly excluded from this pass per the task's scope).

**On the "CPCB 38-station vs DPCC 40-station" note:** I searched the repo for any DPCC-sourced station list (as opposed to this CPCB-PDF-derived CSV) and found none — no file, no doc, no fixture references a 40-station DPCC list anywhere in this codebase. I am flagging this as a known discrepancy worth investigating (DPCC's own live station count has grown over time in the real world and can differ from an archived CPCB PDF snapshot), but per "do not guess missing stations," **I did not invent what the extra 1–2 DPCC-only stations might be**. If a live DPCC source is added to the repo later (e.g. `data/delhi/processed/dpcc_station_reference.csv`), it should go through the same reconciliation process as the CPCB CSV before anything is imported from it.

## 3. Station classification (all 38 official Delhi stations)

| Category | Count | Stations |
|---|---|---|
| **Already loaded** (before this pass) | 12 | Narela, Bawana, Mundka, Wazirpur, Rohini, Okhla, Jahangirpuri, Anand Vihar, Vivek Vihar, Punjabi Bagh, Dwarka, R.K. Puram |
| **Newly added** (this pass) | 7 | Alipur, Ashok Vihar, Najafgarh, Sonia Vihar, Aya Nagar, Patparganj, IHBAS (Dilshad Garden) |
| **Needs manual review** (verified live on OpenAQ, no safe ward match) | 18 | See §5 |
| **Not available via OpenAQ** | 1 | Pitampura |
| **Total** | **38** | |

## 4. Newly added stations

Each was matched to an **existing** `wards` row by exact name (or the same class of trivial spacing/typo normalization already accepted for Mundaka→Mundka and VivekVihar→Vivek Vihar in the prior reconciliation) — never by geographic proximity or inference. These are MCD administrative wards (all-caps naming, imported separately from the 13 Title-Case hotspot wards — see `supabase/migrations/20260731000000_delhi_ward_boundaries_import_support.sql`), not new hotspot wards.

| Official CPCB name | Agency | Matched ward | OpenAQ id | Match basis |
|---|---|---|---|---|
| Alipur | DPCC | `ALIPUR` (id 177) | 6932 | Exact name |
| Ashok Vihar, Delhi | DPCC | `ASHOK VIHAR` (id 49) | 8917 | Exact name |
| Najafgarh, Delhi | DPCC | `NAJAFGARH` (id 165) | 10488 | Exact name |
| Sonia Vihar, Delhi | DPCC | `SONIA VIHAR` (id 141) | 8475 | Exact name |
| Aya Nagar, New Delhi | IMD | `AYA NAGAR` (id 81) | 5570 | Exact name |
| Patparganj, Delhi | DPCC | `PATPAR GANJ` (id 100) | 6960 | Trivial spacing difference only |
| IHBAS, Dilshad Garden, New Delhi | CPCB | `DILSHAD GARDEN` (id 147) | 6359 | Locality named directly in the station's own official name |

None of these 7 wards had a pre-existing station, so no ward now has two stations competing for its ward-level forecast.

### New Supabase rows

| Station id | Name | ward_id | external_ref | Coordinates |
|---|---|---|---|---|
| 15 | Alipur, Delhi - DPCC | 177 | 6932 | 28.815329, 77.15301 |
| 16 | Ashok Vihar, Delhi - DPCC | 49 | 8917 | 28.695381, 77.181665 |
| 17 | Najafgarh, Delhi - DPCC | 165 | 10488 | 28.570173, 76.933762 |
| 18 | Sonia Vihar, Delhi - DPCC | 141 | 8475 | 28.710508, 77.249485 |
| 19 | Aya Nagar, New Delhi - IMD | 81 | 5570 | 28.474261, 77.131606 |
| 20 | Patparganj, Delhi - DPCC | 100 | 6960 | 28.623748, 77.287205 |
| 21 | IHBAS, Dilshad Garden,New Delhi - CPCB | 147 | 6359 | 28.6811736, 77.3025234 |

## 5. Stations skipped: "needs manual review" (18)

All 18 were verified live and reporting current data in the prior reconciliation audit (same day). Every one of them lacks a `wards` row whose name matches without guessing — importing them would require either inventing a ward mapping (explicitly forbidden) or a schema change to let a station exist without a ward (a bigger change than this task authorized: "do not create migrations unless absolutely required"). Left out, not silently dropped:

| Official CPCB name | Agency | Verified live OpenAQ id | Why skipped |
|---|---|---|---|
| DTU, New Delhi | CPCB | 5626 | No matching ward name |
| ITO, New Delhi | CPCB | 5613 | No matching ward name |
| NSIT Dwarka, New Delhi | CPCB | 5622 | Ambiguous — 3 Dwarka sub-wards (`DWARKA-A/B/C`) plus the hotspot `Dwarka`; none uniquely named "NSIT Dwarka" |
| Shadipur, New Delhi | CPCB | 5630 | No matching ward name |
| Siri Fort, New Delhi | CPCB | 5586 | No matching ward name |
| Dr. Karni Singh Shooting Range, Delhi | DPCC | 6934 | No matching ward name |
| Jawaharlal Nehru Stadium, Delhi | DPCC | 6957 | No matching ward name |
| Major Dhyan Chand National Stadium, Delhi | DPCC | 6929 | No matching ward name |
| MandirMarg, New Delhi | DPCC | 6358 | No matching ward name |
| Nehru Nagar, Delhi | DPCC | 8365 | No matching ward name |
| Pusa, DPCC Delhi | DPCC | 6356 | No matching ward name (also: a second, distinct IMD-operated "Pusa" station exists nearby — see next row) |
| Sri AurobindoMarg | DPCC | 10484 | No matching ward name |
| Burari Crossing, New Delhi | IMD | 5541 | `BURARI` ward exists but "Burari Crossing" is a distinct landmark within/near it — accepting this would require a geographic guess this pass declined to make |
| CRRI Mathura Road, New Delhi | IMD | 5627 | No matching ward name |
| IGI Airport Terminal - 3, New Delhi | IMD | 5650 | No matching ward name |
| Lodhi Road, New Delhi | IMD | 5634 | No matching ward name |
| North Campus, DU, New Delhi | IMD | 5610 | No matching ward name |
| Pusa, New Delhi | IMD | 5404 | No matching ward name |

**Recommendation:** these 18 are all real, live, importable data — the blocker is entirely architectural (station requires a ward). A future pass could either (a) do a proper point-in-polygon match of each station's OpenAQ coordinates against the ~250 MCD ward boundary polygons already imported (`wards.boundary`), which would resolve most or all of these correctly without guessing, or (b) introduce a "citywide monitoring" station category not tied to a ward — both are schema/product decisions bigger than this task's scope, not attempted here.

## 6. Pitampura: still unavailable via OpenAQ

Unchanged from the original reconciliation audit — no OpenAQ location named "Pitampura" (or any recognizable variant) exists in the Delhi/NCR search. Not in a hotspot ward; lowest priority.

## 7. Mayapuri: still honestly unresolved

No change. `stations.yaml` still has `openaq_location_id: null` for Mayapuri with the explanatory comment from the prior repair pass (no official CPCB/DPCC/IMD station exists; no OpenAQ match; do not fabricate). Untouched by this expansion — it isn't in the CPCB reference at all, so it was never a candidate here either.

## 8. Backfill results

**Dry-run first** (genuine read-only preview, not `backfill_history.py --dry-run` — that flag still creates the station row as a side effect even in dry-run mode, a script quirk worth knowing; see below): for each of the 7 candidates, confirmed via direct `openaq.get_location`/`get_latest` calls that (a) the station wasn't already in Supabase by `external_ref`, and (b) estimated row counts via a live `get_sensor_hours` probe on the pm25 sensor alone. Estimates (1,235–1,339 pm25 rows) matched the real run closely.

**Real run** (`python scripts/backfill_history.py --days 60 --only "ALIPUR" --only "ASHOK VIHAR" --only "NAJAFGARH" --only "SONIA VIHAR" --only "AYA NAGAR" --only "PATPAR GANJ" --only "DILSHAD GARDEN"`):

```
== backfilling 60d of hourly history (2026-05-22T05:32:58Z -> 2026-07-21T05:32:58Z) ==
   7 station(s) with an OpenAQ id
  + registered station Alipur, Delhi - DPCC (6932) for ward ALIPUR
  ALIPUR: 1264 hourly rows [co:1262, no2:1203, o3:1263, pm10:1240, pm25:1241, so2:1258]
  + registered station Ashok Vihar, Delhi - DPCC (8917) for ward ASHOK VIHAR
  ASHOK VIHAR: 1306 hourly rows [co:1292, no2:1306, o3:1305, pm10:1293, pm25:1285, so2:1300]
  + registered station Najafgarh, Delhi - DPCC (10488) for ward NAJAFGARH
  NAJAFGARH: 1327 hourly rows [co:1314, no2:1324, o3:1317, pm10:1289, pm25:1283, so2:1319]
  + registered station Sonia Vihar, Delhi - DPCC (8475) for ward SONIA VIHAR
  SONIA VIHAR: 1287 hourly rows [co:1178, no2:1258, o3:1264, pm10:1253, pm25:1235, so2:1259]
  + registered station Aya Nagar, New Delhi - IMD (5570) for ward AYA NAGAR
  AYA NAGAR: 1339 hourly rows [co:1313, no2:1316, o3:1334, pm10:1322, pm25:1328]
  + registered station Patparganj, Delhi - DPCC (6960) for ward PATPAR GANJ
  PATPAR GANJ: 1326 hourly rows [co:1320, no2:1321, o3:1324, pm10:1304, pm25:1313, so2:1314]
  + registered station IHBAS, Dilshad Garden,New Delhi - CPCB (6359) for ward DILSHAD GARDEN
  DILSHAD GARDEN: 1326 hourly rows [co:1322, no2:1295, o3:1313, pm10:1301, pm25:1298, so2:1321]

== done: 9175 hourly rows across 7 station(s) written ==
```

**Note on Aya Nagar:** its `so2` column is `null` in all 1,339 rows — not a data-quality defect. This IMD-operated station has 12 OpenAQ sensors (vs. 17–18 for the DPCC stations), and none of them is SO₂ — it simply isn't instrumented for that pollutant. Every other pollutant is populated normally.

## 9. Validation

**Row counts:**

| Table | Before | After | Δ |
|---|---|---|---|
| `stations` | 12 | 19 | +7 |
| `readings` (total) | 15,893 | 25,068 | +9,175 (exact match to the backfill's own reported total, and to the sum of all 19 per-station counts) |

**No duplicate stations / external_refs:** 19 stations, 19 distinct `external_ref` values, zero duplicates.

**Pre-existing 12 stations byte-identical:** every one of the 12 pre-existing stations' reading counts is exactly unchanged (spot-checked, not sampled — full comparison against a pre-run snapshot): Narela 1,322, Bawana 1,305, Mundka 1,352, Wazirpur 1,334, Rohini 1,353, Okhla 1,310, Jahangirpuri 1,333, Anand Vihar 1,279, Vivek Vihar 1,309, Punjabi Bagh 1,315, Dwarka 1,347, R.K. Puram 1,334 — no drift.

**Full (paginated, not sampled) data-quality scan of all 9,175 new rows**, per new station:

| Station | Rows | Duplicate (station_id,ts) | Misaligned timestamps | Negative values | Date range |
|---|---|---|---|---|---|
| Alipur | 1,264 | 0 | 0 | 0 | 2026-05-22 → 2026-07-21 |
| Ashok Vihar | 1,306 | 0 | 0 | 0 | 2026-05-22 → 2026-07-21 |
| Najafgarh | 1,327 | 0 | 0 | 0 | 2026-05-22 → 2026-07-21 |
| Sonia Vihar | 1,287 | 0 | 0 | 0 | 2026-05-22 → 2026-07-21 |
| Aya Nagar | 1,339 | 0 | 0 | 0 | 2026-05-22 → 2026-07-21 |
| Patparganj | 1,326 | 0 | 0 | 0 | 2026-05-22 → 2026-07-21 |
| IHBAS (Dilshad Garden) | 1,326 | 0 | 0 | 0 | 2026-05-22 → 2026-07-21 |

**Pollutant identity preserved:** `pm25/pm10/no2/so2/co/o3` land in their correct columns for all 7 stations; null rates vary by station/sensor (expected — a null means that hour's sensor reading wasn't reported, not a mapping error) and are itemized per-station in §8's backfill log.

**Staleness (as of this report, 2026-07-21T05:43 UTC):** the newest reading across **all 19 stations, old and new alike**, is `2026-07-21T01:00:00Z` — a ~4h43m lag exceeding the app's 180-minute staleness threshold uniformly. This is a live DPCC/CPCB publish-cadence lag affecting the whole feed at this moment, not something specific to the newly-added stations (verified: the pre-existing "fresh" stations show the identical latest timestamp) — nothing to fix here, just an honest timestamp note, not a regression.

**Idempotency check:** `_ensure_station()` looks up by `external_ref` before inserting — re-running this exact command again would find all 7 existing rows and skip straight to backfilling (which itself upserts on `(station_id, ts)`), producing zero duplicate stations and zero duplicate readings. Not re-run a second time in this pass (no need — the single real run's results were already verified clean), but the mechanism is the same one already proven idempotent in the prior repair report.

**Script quirk worth flagging:** `backfill_history.py --dry-run` still calls `_ensure_station()` unconditionally, which inserts a new station row even in dry-run mode — only the `readings` write is skipped. This pass's dry-run step deliberately used separate read-only OpenAQ probes instead of the script's own `--dry-run` flag, specifically to avoid this side effect. Worth a small fix in a future pass (skip `_ensure_station`'s insert when `dry_run=True`), not made here since it's outside this task's scope.

## 10. Checks

| Check | Result |
|---|---|
| `ingest` Python tests (`pytest`) | **37 passed** |
| `web` typecheck + build (`tsc -b && vite build`) | **Passed** |
| `web` unit tests (`vitest run`) | **176 passed** |
| Secret scan | No dedicated scanner installed; manual grep for `SUPABASE_SERVICE_ROLE_KEY=`, `OPENAQ_API_KEY=`, JWT/`eyJ...`, `sk-...` across the changed file and this report — no matches. `.env`/`.env.local` confirmed git-ignored. |

(Full output logged in the same run as the rest of this session — see the change diff for `ingest/stations.yaml`, the only file this expansion touched.)

## 11. Recommendation: forecast-readiness audit

The station set has grown enough (12 → 19, +9,175 readings, all clean) that a proper forecast-readiness audit — mirroring [`openaq-backfill-verification.md`](openaq-backfill-verification.md)'s structure — is now warranted before prediction work starts, to:

1. Confirm `forecast.py` actually trains real per-ward LightGBM models (not the diurnal-persistence fallback) for the 7 new wards, same as it already does for the 9 originally-verified ones.
2. Re-check the Bawana live-feed gap (flagged stale in the reconciliation audit) and the current whole-feed ~4h45m publish lag noted in §9 — both are live-ops questions, not blockers to this expansion.
3. Decide on the 18 "needs manual review" stations (§5) — specifically whether a point-in-polygon match against the MCD ward boundaries is worth the schema/scope expansion to unlock them.
4. Decide Mayapuri's and Pitampura's fate (unchanged from the prior reports).
