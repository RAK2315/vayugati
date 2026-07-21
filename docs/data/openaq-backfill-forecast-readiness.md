# OpenAQ Backfill & PM2.5 Forecast-Readiness Audit

**Type:** Read-only audit. No migrations, no RLS changes, no UI changes, no writes to Supabase, no destructive operations. `OPENAQ_API_KEY` was not used in this pass (Supabase-only analysis via the existing service-role client); nothing was printed or logged.
**Date:** 2026-07-21
**Follows on from:** [`delhi-safe-station-import-report.md`](delhi-safe-station-import-report.md) (34 stations, 44,943 readings at that point)

---

## 1. Executive summary

**PM2.5 forecast MVP can proceed today.** Of 34 stations, **32/34 clear a 30-day PM2.5 readiness bar and 34/34 clear 60-day** (defined in §4). Data quality is clean: **0 duplicate `(station_id, ts)` pairs, 0 negative values, 0 impossible values, 0 misaligned timestamps, 0 non-UTC timestamps** across all 44,987 readings currently in the table (checked with a full paginated scan, not a sample).

One real finding surfaced along the way, not asked for but worth flagging: **a naive "earliest reading to latest reading" span calculation is badly misleading for this table** — 30 of 34 stations carry 1–5 stray rows dated around 2022-10-16/30/31 (a few even 2016/2018/2021), sitting far before each station's real 60-day backfill window. This is **not leftover seed/demo data** as an earlier report speculated — the same stray-row pattern showed up in stations created fresh *today*, in this session, which never existed before. It's a genuine upstream OpenAQ quirk (`/sensors/{id}/hours` occasionally returning one old point — most likely a legacy sensor's last recorded value — outside the requested date range). It has **zero practical impact**: `forecast.py`'s own `get_readings_history(hours=24*30)` never looks back further than 30 days, so these ~47 rows (0.1% of the table) are never touched by real training. This report's own readiness math is windowed specifically to not be fooled by them (§4); a naive full-history query would wrongly conclude the table is 96% empty.

**Recommended first forecast target: Rohini** (§11) — a hotspot ward, 9.4% missing-hours in the last 60 days, not stale, and the longest continuous real history of any station in the table.

---

## 2. Station coverage table

"Real rows" excludes the pre-2023 stray artifact (§1, §9) — this is genuine backfilled/live data only. "Stray rows" is the count of those excluded artifacts, shown for transparency, not hidden.

| id | Station | Ward | Real rows (last 65d) | Stray rows | Latest reading age (min) | Stale (>180min) |
|---|---|---|---|---|---|---|
| 1 | Narela, Delhi - DPCC | Narela | 1323 | 1 | 90 | no |
| 2 | Bawana, Delhi - DPCC | Bawana | 1304 | 1 | 2910 | **YES** |
| 3 | Mundka, Delhi - DPCC | Mundka | 1353 | 1 | 90 | no |
| 4 | Wazirpur, Delhi - DPCC | Wazirpur | 1334 | 2 | 90 | no |
| 5 | Rohini, Delhi - DPCC | Rohini | 1353 | 2 | 90 | no |
| 6 | Okhla Phase-2, Delhi - DPCC | Okhla | 1312 | 1 | 90 | no |
| 7 | Jahangirpuri, Delhi - DPCC | Jahangirpuri | 1333 | 2 | 90 | no |
| 8 | Anand Vihar, Delhi - DPCC | Anand Vihar | 1279 | 5 | 150 | no |
| 9 | Vivek Vihar, Delhi - DPCC | Vivek Vihar | 1310 | 1 | 90 | no |
| 10 | Punjabi Bagh, Delhi - DPCC | Punjabi Bagh | 1317 | 4 | 90 | no |
| 11 | Dwarka-Sector 8, Delhi - DPCC | Dwarka | 1348 | 1 | 90 | no |
| 14 | R K Puram, Delhi - DPCC | R.K. Puram | 1336 | 3 | 210 | **YES** |
| 15 | Alipur, Delhi - DPCC | ALIPUR | 1266 | 2 | 90 | no |
| 16 | Ashok Vihar, Delhi - DPCC | ASHOK VIHAR | 1308 | 2 | 90 | no |
| 17 | Najafgarh, Delhi - DPCC | NAJAFGARH | 1330 | 2 | 90 | no |
| 18 | Sonia Vihar, Delhi - DPCC | SONIA VIHAR | 1290 | 1 | 90 | no |
| 19 | Aya Nagar, New Delhi - IMD | AYA NAGAR | 1340 | 2 | 210 | **YES** |
| 20 | Patparganj, Delhi - DPCC | PATPAR GANJ | 1328 | 1 | 90 | no |
| 21 | IHBAS, Dilshad Garden, New Delhi - CPCB | DILSHAD GARDEN | 1328 | 1 | 90 | no |
| 22 | DTU, New Delhi - CPCB | POOTH KHURD | 1345 | 1 | 90 | no |
| 23 | NSIT Dwarka, Delhi - CPCB | KAKROLA | 1307 | 1 | 90 | no |
| 24 | Shadipur, Delhi - CPCB | MOTI NAGAR | 1345 | 1 | 90 | no |
| 25 | Sirifort, Delhi - CPCB | CHIRAG DELHI | 1344 | 0 | 90 | no |
| 26 | Dr. Karni Singh Shooting Range, Delhi - DPCC | SANGAM VIHAR-B | 1296 | 1 | 90 | no |
| 27 | Jawaharlal Nehru Stadium, Delhi - DPCC | ANDREWS GANJ | 1300 | 1 | 90 | no |
| 28 | Nehru Nagar, Delhi - DPCC | LAJPAT NAGAR | 1343 | 1 | 90 | no |
| 29 | Sri Aurobindo Marg, Delhi - DPCC | HAUZ KHAS | 1324 | 1 | 90 | no |
| 30 | Burari Crossing, New Delhi - IMD | DHIRPUR | 1311 | 1 | 90 | no |
| 31 | CRRI Mathura Road, New Delhi - IMD | SRI NIWAS PURI | 1347 | 1 | 90 | no |
| 32 | North Campus, DU, Delhi - IMD | BALJEET NAGAR | 1328 | 2 | 90 | no |
| 33 | Major Dhyan Chand National Stadium, Delhi - DPCC | New Delhi (NDMC)† | 1341 | 1 | 90 | no |
| 34 | Mandir Marg, New Delhi - DPCC | New Delhi (NDMC)† | 1288 | 0 | 270 | **YES** |
| 35 | IGI Airport (T3), Delhi - IMD | New Delhi (NDMC)† | 1320 | 0 | 270 | **YES** |
| 36 | Lodhi Road, New Delhi - IMD | New Delhi (NDMC)† | 1309 | 0 | 270 | **YES** |

*†4 stations share this ward — the `geometry_matched_but_admin_boundary_needs_review` case from the geospatial audit. Doesn't affect their individual data quality (checked per-station throughout this audit), only what "ward-level" means for that shared bucket.*

## 3. Pollutant coverage table (global, real rows only, 44,940 rows)

| Pollutant | Non-null rows | Null rows | Coverage |
|---|---|---|---|
| pm25 | 43,874 | 1,066 | **97.6%** |
| pm10 | 44,176 | 764 | 98.3% |
| no2 | 44,519 | 421 | 99.1% |
| so2 | 36,163 | 8,777 | **80.5%** |
| co | 44,289 | 651 | 98.6% |
| o3 | 44,357 | 583 | 98.7% |

SO₂'s lower coverage is fully explained, not a defect: 6 of 34 stations are IMD-operated and simply aren't instrumented for SO₂ (Aya Nagar, Burari Crossing, CRRI Mathura Road, North Campus DU, IGI Airport T3, Lodhi Road) — documented in both prior expansion reports. Every other pollutant, including PM2.5, is comfortably above 97%.

## 4. PM2.5 readiness table

Readiness definition used in this audit: **≤20% missing hours** within the window (i.e., ≥576 of 720 possible hours for 30 days, ≥1152 of 1440 for 60 days). This threshold is this audit's own judgment call, not a pre-existing project standard — chosen as a reasonable bar for real-world CAAQMS sensor uptime (no station in this dataset is anywhere near 100%; that's normal for hourly regulatory monitors, not a red flag).

| id | Station | 30d rows/expected | 30d missing% | 30d ready | 60d rows/expected | 60d missing% | 60d ready |
|---|---|---|---|---|---|---|---|
| 1 | Narela | 628/720 | 12.8% | YES | 1302/1440 | 9.6% | YES |
| 2 | Bawana | 556/720 | 22.8% | **no** | 1233/1440 | 14.4% | YES |
| 3 | Mundka | 615/720 | 14.6% | YES | 1297/1440 | 9.9% | YES |
| 4 | Wazirpur | 625/720 | 13.2% | YES | 1288/1440 | 10.6% | YES |
| 5 | Rohini | 634/720 | 11.9% | YES | 1304/1440 | 9.4% | YES |
| 6 | Okhla Phase-2 | 608/720 | 15.6% | YES | 1282/1440 | 11.0% | YES |
| 7 | Jahangirpuri | 596/720 | 17.2% | YES | 1255/1440 | 12.8% | YES |
| 8 | Anand Vihar | 626/720 | 13.1% | YES | 1237/1440 | 14.1% | YES |
| 9 | Vivek Vihar | 617/720 | 14.3% | YES | 1279/1440 | 11.2% | YES |
| 10 | Punjabi Bagh | 624/720 | 13.3% | YES | 1271/1440 | 11.7% | YES |
| 11 | Dwarka-Sector 8 | 609/720 | 15.4% | YES | 1296/1440 | 10.0% | YES |
| 14 | R K Puram | 634/720 | 11.9% | YES | 1311/1440 | 9.0% | YES |
| 15 | Alipur | 591/720 | 17.9% | YES | 1241/1440 | 13.8% | YES |
| 16 | Ashok Vihar | 623/720 | 13.5% | YES | 1285/1440 | 10.8% | YES |
| 17 | Najafgarh | 605/720 | 16.0% | YES | 1282/1440 | 11.0% | YES |
| 18 | Sonia Vihar | 579/720 | 19.6% | YES | 1234/1440 | 14.3% | YES |
| 19 | Aya Nagar | 642/720 | 10.8% | YES | 1326/1440 | 7.9% | YES |
| 20 | Patparganj | 624/720 | 13.3% | YES | 1312/1440 | 8.9% | YES |
| 21 | IHBAS, Dilshad Garden | 619/720 | 14.0% | YES | 1297/1440 | 9.9% | YES |
| 22 | DTU | 615/720 | 14.6% | YES | 1304/1440 | 9.4% | YES |
| 23 | NSIT Dwarka | 648/720 | 10.0% | YES | 1290/1440 | 10.4% | YES |
| 24 | Shadipur | 611/720 | 15.1% | YES | 1297/1440 | 9.9% | YES |
| 25 | Sirifort | 639/720 | 11.3% | YES | 1328/1440 | 7.8% | YES |
| 26 | Dr. Karni Singh Shooting Range | 640/720 | 11.1% | YES | 1269/1440 | 11.9% | YES |
| 27 | Jawaharlal Nehru Stadium | 647/720 | 10.1% | YES | 1288/1440 | 10.6% | YES |
| 28 | Nehru Nagar | 583/720 | 19.0% | YES | 1242/1440 | 13.7% | YES |
| 29 | Sri Aurobindo Marg | 627/720 | 12.9% | YES | 1306/1440 | 9.3% | YES |
| 30 | Burari Crossing | 613/720 | 14.9% | YES | 1283/1440 | 10.9% | YES |
| 31 | CRRI Mathura Road | 645/720 | 10.4% | YES | 1332/1440 | 7.5% | YES |
| 32 | North Campus, DU | 609/720 | 15.4% | YES | 1288/1440 | 10.6% | YES |
| 33 | Major Dhyan Chand National Stadium | 619/720 | 14.0% | YES | 1295/1440 | 10.1% | YES |
| 34 | Mandir Marg | 567/720 | 21.3% | **no** | 1179/1440 | 18.1% | YES |
| 35 | IGI Airport (T3) | 640/720 | 11.1% | YES | 1317/1440 | 8.5% | YES |
| 36 | Lodhi Road | 648/720 | 10.0% | YES | 1307/1440 | 9.2% | YES |

**32/34 stations are 30-day ready. 34/34 are 60-day ready.** All 34 comfortably clear `forecast.py`'s own `MIN_TRAIN_ROWS = 240` (~10 days) — the lowest 30-day row count in the table (Mandir Marg, 567) is still 2.4x that threshold.

## 5. Duplicate check

`readings` is a **wide** table (one row per `station_id, ts`, every pollutant its own column — `unique(station_id, ts)` enforced at the schema level, `supabase/schema.sql`), not a long/per-pollutant-row table. A "duplicate station + pollutant + timestamp" in this schema is exactly a duplicate `(station_id, ts)` pair — checked directly, across the full 44,987-row table (not sampled):

**0 duplicate `(station_id, ts)` pairs.** Confirmed both by the DB's own unique constraint (would reject an insert) and by an independent scan of every row.

## 6. Missing-hour / gap analysis

Covered in the readiness table (§4). Summary: 30-day missing-hour rates range 10.0%–22.8% across all 34 stations (median ~14%), 60-day rates 7.5%–18.1% (median ~10.5%) — 60-day rates are consistently lower than 30-day because the most recent ~2 days for every station sit inside a live-ingest catch-up window that hasn't fully settled yet (normal, not a defect). No station shows a catastrophic gap (>30% missing) in either window.

## 7. Stale-station list

Per the app's own `STATION_STALE_MINUTES = 180` threshold (`web/src/lib/ops.ts`), as of this audit's run:

| Station | Latest reading age | Assessment |
|---|---|---|
| Bawana | 2,910 min (~48.5h) | **Persistent, known issue** — already flagged in the earlier reconciliation audit as a live upstream OpenAQ gap for this specific sensor, not a config problem. Unchanged status. |
| R K Puram | 210 min (~3.5h) | Marginal — 30 min past the threshold |
| Aya Nagar | 210 min (~3.5h) | Marginal — 30 min past the threshold |
| Mandir Marg | 270 min (~4.5h) | Marginal — also the weakest 30-day performer (§4) |
| IGI Airport (T3) | 270 min (~4.5h) | Marginal |
| Lodhi Road | 270 min (~4.5h) | Marginal |

The five "marginal" cases (210–270 min) are consistent with a pattern already documented in the prior expansion report: the whole DPCC/CPCB/IMD feed periodically runs 3–5 hours behind real time as a normal publish-cadence lag, not a per-station fault — at that report's own check, *every* station (old and new) showed the same lag simultaneously. Only **Bawana** is a genuine, isolated, persistent stale station.

## 8. Timestamp / timezone check

All 44,987 rows: **0 misaligned timestamps** (every `ts` lands exactly on the hour), **0 non-UTC timestamps** (every value stored with an explicit `+00:00` offset, consistent with `readings.ts` being `timestamptz` and the ingest pipeline's own `_hour_floor_utc()` helper). No timezone drift, no half-hour offsets, no naive/ambiguous timestamps found anywhere in the table.

## 9. Stations with upstream OpenAQ gaps

- **Bawana** (§7) — persistent live-feed staleness, upstream, not a config issue.
- **30 of 34 stations carry 1–5 pre-2023 stray rows** (§1) — a real, systemic OpenAQ history-API quirk (returns an old point outside the requested date range, most likely a legacy/decommissioned sensor's last value), confirmed to affect stations created fresh in this very session. Zero practical impact on training (outside any 30/60-day window this project ever queries) — flagged for completeness, not urgency. Correcting the earlier report's "looks like seeded demo data" theory: it isn't; it recurs in brand-new stations, so it's upstream, not local seed data.
- **6 IMD-operated stations lack SO₂ instrumentation entirely** (§3) — not a gap, a real characteristic of those sensors; excluding SO₂ from a pan-station model (or treating it as optional, as `city_config.pollutant_priority` already does) avoids this being mistaken for missing data.
- **Bawana and Mandir Marg** are the only 2 stations below this audit's 30-day readiness bar — both still comfortably clear the 60-day bar and `forecast.py`'s hard training minimum.

## 10. Forecast-readiness decision

**Yes — PM2.5-only modelling can proceed now.**

- 34/34 stations clear `MIN_TRAIN_ROWS` for real LightGBM training (vs. the diurnal-persistence fallback) with wide margin.
- 32/34 clear this audit's stricter 30-day bar; the 2 that don't (Bawana, Mandir Marg) still clear 60 days.
- PM2.5 itself has 97.6% row-level coverage where rows exist — no pollutant-specific data problem.
- Zero duplicates, zero negative/impossible values, zero timestamp defects anywhere in the table.
- PM2.5 is already `city_config.pollutant_priority`'s priority-1 pollutant and `aqi.compute_aqi()`'s primary input (per the earlier backfill-verification report) — consistent with proceeding PM2.5-first rather than opening multiple pollutants at once.

## 11. Best first forecast target

**Recommendation: Rohini** (station id=5, hotspot ward `Rohini`).

Reasoning, not just the lowest missing-hour number:
- **9.4% missing hours in the last 60 days** (top-5 in the whole table) and **11.9% in the last 30** — both comfortably inside the readiness bar.
- **Not stale** (90 min).
- **Longest real history of any station in the dataset** (`2026-05-21T13:00:00Z` onward, tied for earliest with 4 other original-cohort stations) — the most days of real hourly data to validate a model against.
- **One of the app's 13 declared hotspot wards** — the ward-level unit the entire product (Overview, Map, Incidents) is actually built around, unlike several of the newer non-hotspot "citywide monitoring" stations. A forecast pilot here is directly demoable in the existing UI, not just a backend metric.

**Strong technical runners-up** (marginally lower missing-hour %, but non-hotspot citywide stations, less central to current product surfaces): CRRI Mathura Road (7.5% 60d), Sirifort (7.8% 60d). Worth including in a broader multi-station validation set once a single-station pilot is proven, not as the very first target.

**Not recommended as a first target:** any of the 4 `New Delhi (NDMC)` stations — not because of their individual data quality (all fine), but because the ward-level admin-boundary question (§2 footnote, full detail in the geospatial audit) is still open; better to prove the modelling approach on an unambiguous ward first.

## 12. Recommended baseline modelling approach

1. **PM2.5-only, per-ward, starting with Rohini** — matches `forecast.py`'s existing design (per-ward LightGBM with a diurnal-persistence fallback) exactly as-is; no architecture change needed, this is a data-readiness question, not a code-readiness one.
2. **30-day rolling training window, as already implemented** (`get_readings_history(hours=24*30)`) — this audit's own 30-day readiness table confirms that window has enough real data for 32 of 34 stations today, and all 34 within 60 days as the live feed keeps accumulating.
3. **Exclude Bawana and Mandir Marg from the first validation pass**, not from the system entirely — both clear 60 days; re-include once their 30-day numbers catch up (which will happen automatically as live ingest continues, assuming Bawana's upstream gap resolves).
4. **Treat SO₂ as optional per-station** (already the codebase's existing pattern via `city_config.pollutant_priority`) rather than a blocking requirement — 6 IMD stations will never have it.

## 13. Exact next implementation task

Run a **live forecast validation pass for Rohini** (station id=5, ward `Rohini`): invoke `forecast.py`'s existing training path directly against real data (no code change), confirm it selects the LightGBM path over the diurnal-persistence fallback (it should, given 1,304 rows vs. the 240-row minimum), and record the validation metrics it already produces (per the pattern in `openaq-backfill-verification.md §8`) as the baseline this project can compare future stations against. This is a **verification run**, not a code change — `forecast.py` already supports everything this recommends; today's readiness gap was in the data, not the model code, and that gap is now closed for at least this one station.

---

## 14. Checks

| Check | Result |
|---|---|
| Full paginated scan of all 44,987 readings (not sampled) | Completed for every check in this report |
| Duplicate `(station_id, ts)` pairs | **0** |
| Negative values (any pollutant) | **0** |
| Impossible values (pm25>1000, pm10/no2/so2>2000, co>50, o3>1000) | **0** |
| Misaligned (non-hour-boundary) timestamps | **0** |
| Non-UTC timestamps | **0** |
| Secret scan | No dedicated scanner installed; manual grep for `SUPABASE_SERVICE_ROLE_KEY=`, `OPENAQ_API_KEY=`, JWT/`eyJ...` across this report and the analysis scripts used — no matches. No writes were made this pass, so no config file needed checking either. |

No files under `web/` or `ingest/app/` were touched — this was a pure read/analysis pass. `docs/data/openaq-backfill-forecast-readiness.md` (this file) is the only new artifact.
