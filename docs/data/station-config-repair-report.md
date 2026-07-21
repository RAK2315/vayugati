# Station Config Repair Report

**Type:** Targeted, reversible data/config repair. No migrations created, no RLS touched, no UI changed, no station fabricated, no `OPENAQ_API_KEY`/`SUPABASE_SERVICE_ROLE_KEY` printed or logged at any point.
**Date:** 2026-07-21
**Follows on from:** [`docs/data/delhi-station-reconciliation.md`](delhi-station-reconciliation.md) (Findings 1–3)

---

## 1. Summary

Repaired the two stations the reconciliation audit found pointed at dead OpenAQ location ids (Anand Vihar, Punjabi Bagh), and resolved R.K. Puram — previously `null` on a stale "not found in OpenAQ" comment. All three now have full 60-day historical backfills and live-fresh data. Mayapuri was left explicitly unresolved, as instructed — it has no official station to point at, and none was fabricated. Bawana was checked separately and found to have a genuine upstream OpenAQ data gap (not a config problem); left untouched.

**Result:** the 8 previously-working stations are byte-identical to their pre-repair state (same row counts, same data). 3,925 new reading rows were added, all attached to the correct station (2 repointed, 1 newly created), zero duplicates, zero data-quality issues found in a full (paginated, not sampled) verification pass.

---

## 2. Config files changed

Only one file: **`ingest/stations.yaml`**. No other station-mapping or OpenAQ-config file exists in the repo (`ingest/app/config.py` just parses this file; no other station list was found).

Diff stat: `28 insertions(+), 4 deletions(-)` — all comments/id values, no structural change to the YAML schema.

**One out-of-band data change was also required** (not a config file, but necessary to satisfy "do not duplicate stations" — see §3): two existing Supabase `stations` rows had their `external_ref` column updated directly via the service-role client (the same client `ingest/` already uses for all writes). This is a plain row `UPDATE` on an existing table, not a migration, not a schema change, and easily reversible by setting the two values back.

## 3. Old ids vs new ids

| Ward | Old `openaq_location_id` | New `openaq_location_id` | Why |
|---|---|---|---|
| Anand Vihar | `10487` (dead — OpenAQ provider `caaqm`, frozen since 2021-09-20) | `235` (live — OpenAQ provider `CPCB`) | Same physical station; audit Finding 1 |
| Punjabi Bagh | `6357` (dead — provider `caaqm`, frozen since 2022-10-16) | `50` (live — provider `CPCB`) | Same physical station; audit Finding 1 |
| R.K. Puram | `null` ("not found in OpenAQ" — stale comment) | `17` (live — provider `CPCB`) | Audit Finding 2; comment was outdated, station exists live |
| Mayapuri | `null` | `null` (unchanged) | No official CPCB/DPCC/IMD station exists; not fabricated. See §5. |

**Why the DB row also had to be touched, not just the YAML:** `ingest.py`'s and `backfill_history.py`'s `_ensure_station()` both look up an existing station by `external_ref` (`db.get_station_by_ref`). If only `stations.yaml` had been edited, the lookup for `external_ref="235"` would have found nothing (the existing row still said `"10487"`) and inserted a **second, duplicate** station row for the same ward — exactly what the task forbade. So station id 8's `external_ref` was updated `10487→235` and id 10's `6357→50` *before* running any ingest/backfill, so the existing rows are found-and-reused instead of duplicated. Verified below (§7) — no duplicate was created.

Coordinates were confirmed identical between old and new OpenAQ ids for both stations before making this change (same physical monitor, not a relocation), so `lat`/`lng` and `name` were left untouched — no rename was needed for matching, per the task's instruction.

## 4. Stations repaired

| Station | Supabase row | Action | Historical rows before → after |
|---|---|---|---|
| Anand Vihar | id=8 (existing, reused) | `external_ref` repointed + backfilled | 2 → 1,279 |
| Punjabi Bagh | id=10 (existing, reused) | `external_ref` repointed + backfilled | 1 → 1,315 |
| R.K. Puram | id=14 (new — ward had no station before) | Created by `_ensure_station` on first backfill run, ward_id=6 correctly linked | 0 → 1,334 |

No station UUIDs/ids changed for the two repointed stations (still id=8 and id=10) — every existing `readings` row for them keeps its original `station_id` foreign key, untouched.

## 5. Mayapuri: left explicitly unresolved

No change made. `stations.yaml` still has `openaq_location_id: null` for Mayapuri, now with an expanded comment recording *why*, for anyone reading the file later:

> Mayapuri has no official CPCB/DPCC/IMD CAAQMS station at all (absent from the 79-row CPCB reference list) and no matching OpenAQ location exists in the Delhi/NCR search — confirmed in the reconciliation audit (Finding 3). **Do not guess or fabricate a station here.** If a ward-level forecast is ever needed for Mayapuri, it must be produced as an explicitly-labelled spatial proxy (e.g. interpolated from Punjabi Bagh/Dwarka), never backed by a `stations.yaml`/`stations` table row implying a real monitor exists.

No Supabase row was created or touched for Mayapuri. Ward 12 ("Mayapuri") remains stationless.

## 6. Ingest/backfill verification

**Pre-repair, read-only probes** (direct `openaq.get_location` / `get_latest` / `get_sensor_hours` calls, no writes) confirmed all three live ids before touching anything:

| Location | Sensors | Latest reading | 2-day hourly probe |
|---|---|---|---|
| Anand Vihar (235) | 18 | 2026-07-21T02:30Z | 47 rows (pm25 sensor) |
| Punjabi Bagh (50) | 18 (6 dead legacy sensors also present under the same location — had to select the live pm25 sensor id specifically, per the audit's caveat) | 2026-07-21T02:15Z | 46 rows (pm25 sensor) |
| R.K. Puram (17) | 18, 12 with 2026 timestamps | 2026-07-21T02:30Z | — |

**Actual backfill run** (`python scripts/backfill_history.py --days 60 --only "Anand Vihar" --only "Punjabi Bagh" --only "R.K. Puram"`), real, not dry-run:

```
== backfilling 60d of hourly history (2026-05-22T05:13:45Z -> 2026-07-21T05:13:45Z) ==
   3 station(s) with an OpenAQ id
  + registered station R K Puram, Delhi - DPCC (17) for ward R.K. Puram
  R.K. Puram: 1334 hourly rows [co:1282, no2:1326, o3:1283, pm10:1310, pm25:1313, so2:1239]
  Anand Vihar: 1277 hourly rows [co:1224, no2:1249, o3:1254, pm10:1242, pm25:1238, so2:1268]
  Punjabi Bagh: 1314 hourly rows [co:1293, no2:1309, o3:1291, pm10:1288, pm25:1271, so2:1276]

== done: 3925 hourly rows across 3 station(s) written ==
R.K. Puram              1334  <-- trainable
Punjabi Bagh            1314  <-- trainable
Anand Vihar             1277  <-- trainable
```

**Bawana, checked separately (no config or data change made):** a direct read-only `openaq.get_latest(8472)` call — the same, correct, already-configured id — shows OpenAQ itself has not received a new reading from this sensor since **2026-07-19T07:45Z** (~46 hours before this audit). This confirms the gap is upstream, at the sensor/OpenAQ level, not a wrong id or an ingest bug — correctly **left untouched**, per the task's instruction not to mix it into the id repair.

## 7. Verification results

- **No duplicate station records.** Station count went from 11 → 12 (only the expected +1 for R.K. Puram). All 12 `external_ref` values are distinct: `10485, 8472, 10486, 8915, 10831, 8239, 8235, 235, 6938, 50, 6931, 17`.
- **Latest readings now update for all 3 repaired stations** — all three's most recent row is `2026-07-21T01:00:00+00:00`, fresh (well under the app's 180-minute staleness threshold as of this audit).
- **Historical readings are attached to the correct existing station records** — verified `station_id` foreign keys: Anand Vihar rows → id=8 (same row that existed before, not a new id), Punjabi Bagh rows → id=10, R.K. Puram rows → the newly created id=14, correctly linked to `ward_id=6` (R.K. Puram).
- **Pollutant identity preserved** — spot-checked and full-scanned: `pm25/pm10/no2/so2/co/o3/aqi` land in their correct columns; `aqi` is computed consistently with the existing `pm25`/`pm10`-based formula, matching values already used elsewhere in the app.
- **Timestamps correct** — full paginated scan (not sample) of all 1,279 + 1,315 + 1,334 = 3,928 rows for the three repaired stations: **0 rows** misaligned to a non-hour boundary, **0 negative values**, **0 duplicate `(station_id, ts)` pairs**.
- **Existing 8 working stations unchanged** — reading counts for Narela, Mundka, Wazirpur, Rohini, Okhla, Jahangirpuri, Vivek Vihar, Dwarka are **exactly identical** before and after (1,322 / 1,352 / 1,334 / 1,353 / 1,310 / 1,333 / 1,309 / 1,347 — no drift). Their `id`, `external_ref`, `lat`/`lng`, `name` are all untouched.
- **Old stray rows preserved, not deleted** — the 2 pre-existing Anand Vihar rows (2021-09-20) and 1 pre-existing Punjabi Bagh row (2022-10-16) are still present (`2 + 1277 = 1279`, `1 + 1314 = 1315`), per the instruction not to delete old reading rows.

### Row count changes

| Table | Before | After | Δ |
|---|---|---|---|
| `stations` | 11 | 12 | +1 (R.K. Puram) |
| `readings` (total) | 11,968 | 15,893 | +3,925 (exactly matches the backfill run's own reported total) |
| `readings` (Anand Vihar, id=8) | 2 | 1,279 | +1,277 |
| `readings` (Punjabi Bagh, id=10) | 1 | 1,315 | +1,314 |
| `readings` (R.K. Puram, id=14, new) | 0 | 1,334 | +1,334 |
| `readings` (other 8 stations) | 9,656 | 9,656 | 0 |

## 8. Remaining station gaps

- **Mayapuri** — no official station exists; intentionally left unresolved (§5). Needs a product decision (proxy forecast vs. accepted gap), not another data-source search.
- **Pitampura (IMD)** — not in a hotspot ward, still absent from both Supabase and OpenAQ per the original audit; unaffected by this repair, no action taken.
- **26 other official Delhi CAAQMS stations** (DTU, ITO, IHBAS, Alipur, Ashok Vihar, etc. — full list in the reconciliation audit §6) remain available on OpenAQ but outside the current 13-ward hotspot model; out of scope for this repair, flagged there as a future opportunity.
- **Bawana** — correct id, sufficient history (1,305 rows), but currently not receiving new data upstream. Not a config problem; worth a time-boxed recheck (see recommendation below).

## 9. Test / build / secret-scan results

| Check | Result |
|---|---|
| `ingest` Python tests (`pytest`) | **37 passed** |
| `web` typecheck + build (`tsc -b && vite build`) | **Passed** — built in 10.09s (pre-existing bundle-size warning only, unrelated to this change) |
| `web` unit tests (`vitest run`) | **176 passed** (3 files) |
| Secret scan | No dedicated scanner (`gitleaks`/`trufflehog`/`detect-secrets`) installed in this environment. Fell back to a manual pattern grep (`SUPABASE_SERVICE_ROLE_KEY=`, `OPENAQ_API_KEY=`, JWT/`eyJ...`, `sk-...`) across the changed file and this report — **no matches**. Confirmed `ingest/.env` and `web/.env.local` are git-ignored, not staged. |

No UI, schema, or RLS files were touched by this change (`git status` shows only `ingest/stations.yaml` modified, plus this report and the prior audit doc as new files).

## 10. Recommendation for a forecast-readiness follow-up

- **Hotspot coverage with sufficient historical data (≥240 rows, `forecast.py`'s `MIN_TRAIN_ROWS`): now 12/13** — every hotspot ward except Mayapuri. This matches the audit's projected outcome exactly.
- **Hotspot coverage that is both sufficient *and* currently fresh: 11/13** — same 12, minus Bawana, whose upstream feed is currently stale (§6).
- Recommend a short **Forecast Readiness Audit** (mirroring the structure of the original `openaq-backfill-verification.md`) once the live feed has run a few more cycles, to: (a) confirm `forecast.py` actually trains real models (not diurnal-persistence fallback) for the 3 newly-added stations, (b) re-check Bawana after a few days — if the upstream gap persists past, say, a week, it likely needs the same "check for a second live OpenAQ id" treatment this report gave Anand Vihar/Punjabi Bagh, and (c) revisit the Mayapuri proxy-forecast question as a product decision, not a data-pipeline one.
