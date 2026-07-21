# Delhi AQI / CAAQMS Station Reconciliation Audit

**Type:** Read-only audit. No migrations created, no RLS touched, no UI changed, no rows written to Supabase, no data imported. `OPENAQ_API_KEY` and `SUPABASE_SERVICE_ROLE_KEY` were used only in request headers for read (`select`/`GET`) calls — never printed, logged, or committed.
**Date:** 2026-07-21
**Sources inspected:**
- `data/delhi/processed/cpcb_caaqms_station_reference.csv` (79 rows, CPCB's official Delhi-NCR CAAQMS list)
- Supabase `stations`, `readings`, `wards` tables (live, via `ingest/app/db.py`)
- `ingest/stations.yaml`, `ingest/app/openaq.py`, `ingest/app/ingest.py`
- Live OpenAQ v3 API (`/locations` bbox search + `/locations/{id}`, `/locations/{id}/latest`, `/sensors/{id}/hours` — all read-only GETs)

---

## 1. Summary

**11 station rows are loaded in Supabase.** Of those:
- **8 are healthy** — correct OpenAQ id, fresh data (last reading within the app's own 180-minute staleness window as of this audit).
- **1 (Bawana) is loaded correctly but currently stale** — no reading since 2026-07-19, a ~46-hour gap, most likely a transient ingestion miss rather than a wrong configuration.
- **2 (Anand Vihar, Punjabi Bagh) are loaded but pointed at dead OpenAQ location ids.** This directly contradicts the prior conclusion in [`openaq-backfill-verification.md`](openaq-backfill-verification.md#6-root-cause-anand-vihar--punjabi-bagh-have-zero-history) that this was an unfixable "upstream OpenAQ gap." It is not — see **Finding 1**, verified live in this audit.

Of the **38 official Delhi CAAQMS stations** in the CPCB reference (CPCB + DPCC + IMD), **27 are entirely absent from Supabase**. Of those 27, **26 are live and importable from OpenAQ today**, including **R.K. Puram** — one of the 13 declared hotspot wards, whose `stations.yaml` entry is `null` with a comment saying it wasn't found on OpenAQ. That comment is now stale (**Finding 2**). Only **Pitampura** (IMD) has no matching OpenAQ location at all.

**Mayapuri**, the other `null` hotspot ward, is a different situation: it is not a CPCB/DPCC/IMD station at all — it does not appear anywhere in the 79-row official reference, and no OpenAQ location named "Mayapuri" exists in the Delhi/NCR search. It is a ward the app defined as a pollution hotspot, but no official regulatory monitor exists there (**Finding 3**).

**Net effective coverage of the app's 13 declared hotspot wards right now: 8/13 (62%) have fresh, trustworthy live data.** A well-scoped follow-up (repoint 2 wrong ids, add 1 new station, investigate 1 stale gap) would bring that to **12/13**; the 13th (Mayapuri) has no official station to point at.

---

## 2. Current Supabase station inventory (11 rows)

| id | Name | ext_ref (OpenAQ loc id) | Ward | Coordinates | Pollutants in latest row | Latest reading (UTC) | Historical rows | Status |
|---|---|---|---|---|---|---|---|---|
| 1 | Narela, Delhi - DPCC | 10485 | Narela | 28.822836, 77.101981 | pm25, pm10, no2, so2, co, o3 | 2026-07-21T02:00 | 1,322 | Fresh |
| 2 | Bawana, Delhi - DPCC | 8472 | Bawana | 28.7762, 77.051074 | pm25, pm10, no2, so2, co, o3 | 2026-07-19T07:00 | 1,305 | **Stale (~46h gap)** |
| 3 | Mundka, Delhi - DPCC | 10486 | Mundka | 28.684678, 77.076574 | pm25, pm10, no2, so2, co, o3 | 2026-07-21T02:00 | 1,352 | Fresh |
| 4 | Wazirpur, Delhi - DPCC | 8915 | Wazirpur | 28.699793, 77.165453 | pm10, no2, so2, co, o3 | 2026-07-21T02:00 | 1,334 | Fresh |
| 5 | Rohini, Delhi - DPCC | 10831 | Rohini | 28.732528, 77.11992 | pm25, pm10, no2, so2, co, o3 | 2026-07-21T02:00 | 1,353 | Fresh |
| 6 | Okhla Phase-2, Delhi - DPCC | 8239 | Okhla | 28.530785, 77.271255 | pm25, pm10, no2, so2, co, o3 | 2026-07-21T02:00 | 1,310 | Fresh |
| 7 | Jahangirpuri, Delhi - DPCC | 8235 | Jahangirpuri | 28.73282, 77.170633 | pm25, pm10, no2, so2, co, o3 | 2026-07-21T02:00 | 1,333 | Fresh |
| 8 | Anand Vihar, Delhi - DPCC | 10487 | Anand Vihar | 28.646835, 77.316032 | pm10, no2, so2, co, o3 | 2021-09-20T07:00 | 2 | **Broken — dead id** |
| 9 | Vivek Vihar, Delhi - DPCC | 6938 | Vivek Vihar | 28.672342, 77.31526 | pm25, pm10, no2, so2, co, o3 | 2026-07-21T02:00 | 1,309 | Fresh |
| 10 | Punjabi Bagh, Delhi - DPCC | 6357 | Punjabi Bagh | 28.674045, 77.131023 | pm25, pm10, no2, so2, co, o3 | 2022-10-16T14:00 | 1 | **Broken — dead id** |
| 11 | Dwarka-Sector 8, Delhi - DPCC | 6931 | Dwarka | 28.5710274, 77.0719006 | pm10, no2, so2, co, o3 | 2026-07-21T02:00 | 1,347 | Fresh |

All 11 have `is_active = true` and `sensor_type = 'regulatory'` in Supabase — note `is_active` is a manual admin flag (`set_station_active` RPC), not automatically tied to data freshness, which is why Anand Vihar/Punjabi Bagh still show `is_active = true` despite years-old data. The app's own web UI (`web/src/lib/ops.ts`) separately computes `is_stale` from `latest_reading_age_minutes > 180`; by that definition **3 of 11** (Bawana, Anand Vihar, Punjabi Bagh) are currently stale, not 2.

Audit run at **2026-07-21T04:56 UTC**; "Fresh"/"Stale" above is relative to that timestamp.

---

## 3. Finding 1 (major): Anand Vihar and Punjabi Bagh are fixable, not an OpenAQ gap

The prior audit ([`openaq-backfill-verification.md`](openaq-backfill-verification.md), 2026-07-20) diagnosed these two stations' empty history as an "upstream OpenAQ gap... not a bug in this codebase," based on `get_sensor_hours()` returning 0 rows for the *configured* location ids (10487, 6357).

This audit found the real cause: **OpenAQ has two separate location records for each of these physical stations** — an old one (provider `caaqm`) frozen years ago, and a newer live one (provider `CPCB`) that is currently reporting. `stations.yaml` and Supabase are both pointed at the dead one.

| Station | Configured id (dead) | Live id (verified) |
|---|---|---|
| Anand Vihar | **10487** — provider `caaqm`, frozen 2021-09-20, 6 sensors | **235** — provider `CPCB`, 18 sensors, latest 2026-07-21T02:30, `pm25` sensor 12235610 returned 47 hourly rows for 2026-07-19→21 |
| Punjabi Bagh | **6357** — provider `caaqm`, frozen 2022-10-16, 6 sensors | **50** — provider `CPCB`, 18 sensors, latest 2026-07-21T02:15, `pm25` sensor 12234796 returned 46 hourly rows for 2026-07-19→21 |

Both verified directly against the live OpenAQ API in this audit (`get_location`, `get_latest`, and `get_sensor_hours` all called and inspected — read-only, nothing written).

**Caveat for whoever fixes this:** location id=50 (Punjabi Bagh) has *both* the old dead sensors (e.g. sensor id 396 for pm25, frozen at 2018-02-21) and the new live ones (sensor id 12234796) coexisting under the same location. `openaq.py`'s `get_location()` keys its sensor dict by sensor id, so both appear — a naive "grab the first pm25 sensor" will silently pick the dead one even after the location id is corrected. Anand Vihar's live location (235) does not have this trap (all 18 sensors are current).

**This is the highest-value, lowest-risk fix available** — it only requires updating two `openaq_location_id` values in `stations.yaml` (10487→235, 6357→50) and re-running the existing backfill script; no schema change, no new station.

---

## 4. Finding 2: R.K. Puram's "not found in OpenAQ" comment is stale

`ingest/stations.yaml` has:
```yaml
- ward: R.K. Puram
  openaq_location_id: null   # not found in OpenAQ India stations
```

Live OpenAQ search in this audit found **R K Puram, Delhi - DPCC** at id **17** (provider `CPCB`), currently reporting — `get_latest(17)` returned 12 of 18 sensors with a 2026-07-21T02:30 timestamp, including a live pm25 reading. This station exists today; the comment's premise no longer holds (whether it was wrong originally or the station was added to OpenAQ since is not knowable from here). This is the second lowest-risk fix: one new `stations.yaml` entry, same pattern as the other 11.

---

## 5. Finding 3: Mayapuri has no official monitoring station

Unlike R.K. Puram, **Mayapuri is not a gap in OpenAQ coverage — it is not a CPCB/DPCC/IMD CAAQMS station at all.** It does not appear in any of the 79 rows of `cpcb_caaqms_station_reference.csv` (checked across all agencies and all NCR regions, not just Delhi), and no OpenAQ location named "Mayapuri" exists anywhere in the Delhi/NCR bounding-box search (116 locations, zero matches).

`stations.yaml`'s `null` + "not found" comment for Mayapuri is **correct and still accurate** — this is not something OpenAQ can resolve. If ward-level data is still wanted for Mayapuri, the realistic options are: (a) spatial interpolation/nearest-neighbor from the closest loaded stations (Punjabi Bagh and Dwarka are the nearest hotspot-ward stations), (b) a citizen-sensor network like the several AirGradient/community stations this audit's OpenAQ search surfaced elsewhere in Delhi (e.g. "Santushti Apartments, Vasant Kunj", "Anand Lok" — none currently near Mayapuri specifically), or (c) treating it as a known, permanent gap in ward-level ground truth. None of these are "import from OpenAQ" — flagging for a product decision, not attempting a fix here.

---

## 6. Full reconciliation: Delhi's 38 official CAAQMS stations

CPCB's reference document lists 6 CPCB, 23 DPCC, and 8 IMD stations for Delhi city specifically (the wider CSV has 79 rows total across the whole NCR — Haryana, UP, Rajasthan towns — summarized separately in [§7](#7-wider-delhi-ncr-38-stations-outside-current-scope)).

| Official station name | Agency | Matched Supabase station | Matched OpenAQ location (live) | Coordinates available | Latest data | Historical data | Status |
|---|---|---|---|---|---|---|---|
| DTU, New Delhi | CPCB | — | `DTU, New Delhi - CPCB` (id=5626) | No (CSV has none) | — | — | missing |
| ITO, New Delhi | CPCB | — | `ITO, New Delhi - CPCB` (id=5613) | No (CSV has none) | — | — | missing |
| IHBAS, Dilshad Garden, New Delhi | CPCB | — | `IHBAS, Dilshad Garden,New Delhi - CPCB` (id=6359) | No (CSV has none) | — | — | missing |
| NSIT Dwarka, New Delhi | CPCB | — | `NSIT Dwarka, Delhi - CPCB` (id=5622) | No (CSV has none) | — | — | missing |
| Shadipur, New Delhi | CPCB | — | `Shadipur, Delhi - CPCB` (id=5630) | No (CSV has none) | — | — | missing |
| Siri Fort, New Delhi | CPCB | — | `Sirifort, Delhi - CPCB` (id=5586) | No (CSV has none) | — | — | missing |
| Alipur | DPCC | — | `Alipur, Delhi - DPCC` (id=6932) | No (CSV has none) | — | — | missing |
| Anand Vihar, Delhi | DPCC | `Anand Vihar, Delhi - DPCC` (id=8) | `Anand Vihar, New Delhi - DPCC` (id=235) | Yes (28.646835, 77.316032) | 2021-09-20T07:00Z | 2 rows | **needs manual review** |
| Ashok Vihar, Delhi | DPCC | — | `Ashok Vihar, Delhi - DPCC` (id=8917) | No (CSV has none) | — | — | missing |
| Bawana | DPCC | `Bawana, Delhi - DPCC` (id=2) | `Bawana, Delhi - DPCC` (id=8472) | Yes (28.7762, 77.051074) | 2026-07-19T07:00Z | 1,305 rows | loaded, stale |
| Dr. Karni Singh Shooting Range, Delhi | DPCC | — | `Dr. Karni Singh Shooting Range, Delhi - DPCC` (id=6934) | No (CSV has none) | — | — | missing |
| Dwarka-Sector 8, Delhi | DPCC | `Dwarka-Sector 8, Delhi - DPCC` (id=11) | `Dwarka-Sector 8, Delhi - DPCC` (id=6931) | Yes (28.5710274, 77.0719006) | 2026-07-21T02:00Z | 1,347 rows | loaded |
| Mundaka *(sic — see naming note)* | DPCC | `Mundka, Delhi - DPCC` (id=3) | `Mundka, Delhi - DPCC` (id=10486) | Yes (28.684678, 77.076574) | 2026-07-21T02:00Z | 1,352 rows | loaded |
| Jahangirpuri, Delhi | DPCC | `Jahangirpuri, Delhi - DPCC` (id=7) | `Jahangirpuri, Delhi - DPCC` (id=8235) | Yes (28.73282, 77.170633) | 2026-07-21T02:00Z | 1,333 rows | loaded |
| Jawaharlal Nehru Stadium, Delhi | DPCC | — | `Jawaharlal Nehru Stadium, Delhi - DPCC` (id=6957) | No (CSV has none) | — | — | missing |
| Major Dhyan Chand National Stadium, Delhi | DPCC | — | `Major Dhyan Chand National Stadium, Delhi - DPCC` (id=6929) | No (CSV has none) | — | — | missing |
| MandirMarg, New Delhi *(sic)* | DPCC | — | `Mandir Marg, New Delhi - DPCC` (id=6358) | No (CSV has none) | — | — | missing |
| Najafgarh, Delhi | DPCC | — | `Najafgarh, Delhi - DPCC` (id=10488) | No (CSV has none) | — | — | missing |
| Narela, Delhi | DPCC | `Narela, Delhi - DPCC` (id=1) | `Narela, Delhi - DPCC` (id=10485) | Yes (28.822836, 77.101981) | 2026-07-21T02:00Z | 1,322 rows | loaded |
| Nehru Nagar, Delhi | DPCC | — | `Nehru Nagar, Delhi - DPCC` (id=8365) | No (CSV has none) | — | — | missing |
| Okhla Phase-2, Delhi | DPCC | `Okhla Phase-2, Delhi - DPCC` (id=6) | `Okhla Phase-2, Delhi - DPCC` (id=8239) | Yes (28.530785, 77.271255) | 2026-07-21T02:00Z | 1,310 rows | loaded |
| Patparganj, Delhi | DPCC | — | `Patparganj, Delhi - DPCC` (id=6960) | No (CSV has none) | — | — | missing |
| Punjabi Bagh, Delhi | DPCC | `Punjabi Bagh, Delhi - DPCC` (id=10) | `Punjabi Bagh, Delhi - DPCC` (id=50) | Yes (28.674045, 77.131023) | 2022-10-16T14:00Z | 1 row | **needs manual review** |
| Pusa, DPCC Delhi | DPCC | — | `Pusa, Delhi - DPCC` (id=6356) | No (CSV has none) | — | — | missing |
| R K Puram, New Delhi | DPCC | — | `R K Puram, Delhi - DPCC` (id=17) | No (CSV has none) | — | — | **missing — resolvable (Finding 2)** |
| Rohini, Delhi | DPCC | `Rohini, Delhi - DPCC` (id=5) | `Rohini, Delhi - DPCC` (id=10831) | Yes (28.732528, 77.11992) | 2026-07-21T02:00Z | 1,353 rows | loaded |
| Sonia Vihar, Delhi | DPCC | — | `Sonia Vihar, Delhi - DPCC` (id=8475) | No (CSV has none) | — | — | missing |
| Sri AurobindoMarg *(sic)* | DPCC | — | `Sri Aurobindo Marg, Delhi - DPCC` (id=10484) | No (CSV has none) | — | — | missing |
| VivekVihar, Delhi *(sic)* | DPCC | `Vivek Vihar, Delhi - DPCC` (id=9) | `Vivek Vihar, Delhi - DPCC` (id=6938) | Yes (28.672342, 77.31526) | 2026-07-21T02:00Z | 1,309 rows | loaded |
| Wazirpur, Delhi | DPCC | `Wazirpur, Delhi - DPCC` (id=4) | `Wazirpur, Delhi - DPCC` (id=8915) | Yes (28.699793, 77.165453) | 2026-07-21T02:00Z | 1,334 rows | loaded |
| Aya Nagar, New Delhi | IMD | — | `Aya Nagar, New Delhi - IMD` (id=5570) | No (CSV has none) | — | — | missing |
| Burari Crossing, New Delhi | IMD | — | `Burari Crossing, New Delhi - IMD` (id=5541) | No (CSV has none) | — | — | missing |
| CRRI Mathura Road, New Delhi | IMD | — | `CRRI Mathura Road, New Delhi - IMD` (id=5627) | No (CSV has none) | — | — | missing |
| IGI Airport Terminal - 3, New Delhi | IMD | — | `IGI Airport (T3), Delhi - IMD` (id=5650) | No (CSV has none) | — | — | missing |
| Lodhi Road, New Delhi | IMD | — | `Lodhi Road, New Delhi - IMD` (id=5634) | No (CSV has none) | — | — | missing |
| North Campus, DU, New Delhi | IMD | — | `North Campus, DU, Delhi - IMD` (id=5610) | No (CSV has none) | — | — | missing |
| Pusa, New Delhi | IMD | — | `Pusa, Delhi - IMD` (id=5404) | No (CSV has none) | — | — | missing |
| Pitampura | IMD | — | **NOT FOUND** | No (CSV has none) | — | — | **not available via OpenAQ** |

*"Coordinates available" reflects the CPCB reference CSV only — it has none for any of the 79 rows (`notes` column: "Coordinates not present in source document — missing"). Every coordinate in this table came from Supabase (already-loaded stations) or OpenAQ location metadata, not from the CPCB CSV.*

**Naming mismatches** (CPCB source-document artifacts, not real station differences — each verified to be the same physical station): `Mundaka`→`Mundka`, `VivekVihar`→`Vivek Vihar`, `MandirMarg`→`Mandir Marg`, `Sri AurobindoMarg`→`Sri Aurobindo Marg`, `Siri Fort`→`Sirifort`. All are the CPCB PDF's word-spacing/spelling dropped during extraction (see the CSV's own `source_document` column crediting `cpcb_caaqms_list_delhi_ncr.pdf`).

**Duplicate/near-duplicate note:** the CPCB reference CSV itself contains one exact duplicate row — `Sector- 16A, Faridabad (HSPCB)` appears twice (rows 44 and 47) — a source-document artifact, not a Delhi station and not affecting the app. **No duplicates exist within Supabase's 11 stations** (11 distinct `external_ref` values, 11 distinct wards, 11 distinct names). **No Supabase station is absent from the CPCB reference** — every one of the 11 loaded stations matches an official CPCB/DPCC row by name (modulo the naming mismatches above), so there are no "rogue"/unofficial stations in the database.

**OpenAQ duplicate pattern (systemic, not Delhi-specific):** nearly every Delhi CPCB/DPCC station has *two* OpenAQ location ids — a frozen `caaqm`-provider one (mostly dead since 2018, a few since 2022) and a live `CPCB`-provider one. `stations.yaml`'s 9 correctly-configured stations already point at the live id; only Anand Vihar and Punjabi Bagh point at the dead one (Finding 1). Anyone adding a new station from this table must pick the `CPCB`-provider id with a 2026 `datetimeLast`, not the `caaqm` one — both are listed for cross-reference above.

---

## 7. Wider Delhi-NCR (41 stations outside current scope)

The CPCB CSV's other 41 rows cover Haryana (Bahadurgarh, Ballabgarh, Bhiwani, Dharuhera, Charkhi Dadri, Faridabad, Jind, Karnal, Mandikhera, Manesar, Narnaul, Palwal, Panipat, Rohtak, Sonipat, Gurugram), Uttar Pradesh (Baghpat, Bulandshahr, Ghaziabad, Greater Noida, Hapur, Meerut, Muzaffarnagar, Noida), and Rajasthan (Alwar, Bhiwadi) — none of which the app currently models (the 13 hotspot wards and the ~250 imported MCD ward boundaries are all within Delhi city limits).

The OpenAQ bbox search was scoped to Delhi + the immediate NCR ring (Gurugram/Noida/Ghaziabad/Faridabad, roughly 76.80–77.55°E, 28.30–28.95°N) to keep the audit targeted — it was **not** exhaustive for the outer NCR (Meerut, Alwar, Bhiwadi, Rohtak, Panipat, Sonipat, Bulandshahr, Baghpat all sit outside that box). Within the searched ring, most Haryana/UP stations that *were* in range did resolve to a live OpenAQ id (e.g. Vikas Sadan/Gurugram, Sector-51/Gurugram, Indirapuram/Ghaziabad, Loni/Ghaziabad). This section is a scope note, not a claim that the outer-NCR stations are unavailable — they were simply out of this audit's search radius. Not a current priority since the app has no ward model there.

---

## 8. Is the current station set enough for prediction?

Referencing the existing `forecast.py` threshold (`MIN_TRAIN_ROWS = 240`, ~10 days hourly, documented in [`openaq-backfill-verification.md §8`](openaq-backfill-verification.md#8-forecast-readiness)):

- **8 of 13 hotspot wards** (Narela, Mundka, Wazirpur, Rohini, Okhla, Jahangirpuri, Vivek Vihar, Dwarka) have 1,300+ historical rows each and a live feed — comfortably forecast-ready today, no action needed.
- **1 (Bawana)** has 1,305 historical rows (also forecast-ready on existing data) but has stopped receiving new readings for ~46 hours — worth a live-ingest check, since a continued gap will eventually degrade it from "ready" to "stale."
- **2 (Anand Vihar, Punjabi Bagh)** have essentially zero usable history (2 and 1 rows) despite being "loaded" — not because the physical stations lack data, but because the ingest pipeline points at dead OpenAQ ids (Finding 1). Fixing the two ids and re-running the backfill script would very likely bring these to parity with the other 9 immediately — CPCB/DPCC stations of this type typically have 60+ days of `/sensors/{id}/hours` history available once pointed at the correct sensor.
- **2 (R.K. Puram, Mayapuri)** have no data at all. R.K. Puram is resolvable the same way as the other 11 (Finding 2). Mayapuri has no official monitor to point at (Finding 3) and needs a product decision, not an import.

**Bottom line:** the station set is sufficient for prediction in 8 of the 13 declared hotspot wards today, and — with no new data source, only a `stations.yaml` correction and a backfill re-run — could reach 12 of 13 without waiting on any external dependency. Mayapuri is a structural gap, not a data-pipeline bug.

---

## 9. Recommended next steps (not executed — audit-only)

In priority order, by effort vs. confidence:

1. **Fix the two wrong OpenAQ ids** (Finding 1): `Anand Vihar 10487→235`, `Punjabi Bagh 6357→50` in `ingest/stations.yaml`, then re-run `scripts/backfill_history.py --only "Anand Vihar" --only "Punjabi Bagh"`. Highest confidence, verified live in this audit, zero new stations.
2. **Investigate the Bawana ~46h gap.** Could be a transient upstream outage (check `get_latest(8472)` again in a day) or something worth alerting on if it persists — not diagnosed further here since it's a live-ops question, not a reconciliation one.
3. **Add R.K. Puram** (Finding 2): `openaq_location_id: 17` in `stations.yaml`, remove the stale "not found" comment. Same pattern as the other 11 — no new code.
4. **Decide Mayapuri's fate** (Finding 3): no OpenAQ path exists. Needs a product call — interpolate from neighbors, seek an alternate sensor source, or explicitly document it as an unmonitored hotspot ward.
5. **Optional, larger scope:** the 26 other official Delhi CAAQMS stations available live on OpenAQ (§6) are outside the current 13 hotspot wards' boundaries — importing them would mean either expanding the hotspot ward set or adding a "citywide monitoring" station category not tied to a ward. That's a product/schema decision beyond this audit; flagged as an opportunity, not a recommendation to act on immediately.
6. **Pitampura**: no OpenAQ path found. Lowest priority since it isn't in a hotspot ward.
