# Delhi Manual Files — Phase 1 Validation Report

**Type:** Phase 1 execution report (manual file intake and validation). Files were inspected, converted, and processed **outside Supabase** — no migration was created, no app behavior was changed, nothing was imported into a database, and nothing has been committed yet (see [Section 8](#8-what-was-not-done-per-scope)).
**Date:** 2026-07-20
**Companion documents:** [docs/delhi-data-readiness-audit.md](../delhi-data-readiness-audit.md) (read-only audit that identified these files were missing), [docs/DELHI_DATA_GAP_REPORT.md](../DELHI_DATA_GAP_REPORT.md) (operational-data gaps), [docs/data/dpcc_point_source_extraction_notes.md](dpcc_point_source_extraction_notes.md) (full DPCC extraction detail).

---

## 1. Files found

The three files referenced in the audit had not yet reached the local working tree — they existed in an unmerged commit (`d0fa9e4 "data sets"`) on `origin/main`, added at the repo root under their original names. That commit was fast-forward merged (a normal, non-destructive `git pull`) to bring them local, then moved into the requested folder structure:

| Original location/name (as pulled) | New location (this phase) |
|---|---|
| `archive.zip` | `data/delhi/raw/delhi_wards_opencity_archive.zip` |
| `cpcb_caaqms_list_delhi_ncr.pdf` | `data/delhi/raw/cpcb_caaqms_list_delhi_ncr.pdf` (name unchanged) |
| `book_inventory_of_major_point_air_pollution_sources_in_delhi_merged.pdf` | `data/delhi/raw/dpcc_major_point_sources_delhi_2023.pdf` |

All three are real, non-empty, well-formed files:

| File | Size | Format |
|---|---|---|
| `delhi_wards_opencity_archive.zip` | 1,933,906 bytes | ZIP containing one KML file |
| `cpcb_caaqms_list_delhi_ncr.pdf` | 149,717 bytes | PDF, 2 pages |
| `dpcc_major_point_sources_delhi_2023.pdf` | 5,188,965 bytes | PDF, 48 pages |

Folders confirmed/created: `data/delhi/raw/`, `data/delhi/processed/`, `docs/data/`.

**No unverified external GeoJSON was used anywhere in this phase.** The 290-ward GeoJSON flagged in the prior audit (belonging to an unrelated project outside this repo) was not touched, referenced, or copied.

---

## 2. Files converted / extracted

| Raw input | Output | Method |
|---|---|---|
| `delhi_wards_opencity_archive.zip` → `delhi_wards.kml` | `data/delhi/processed/delhi_wards.geojson` | Unzipped, parsed with Python's standard-library `xml.etree.ElementTree` (no reprojection needed — KML coordinates are always WGS84/EPSG:4326 by spec) |
| `cpcb_caaqms_list_delhi_ncr.pdf` | `data/delhi/processed/cpcb_caaqms_station_reference.csv` | Extracted via `pdfplumber`'s table extraction; operating agency assigned per row using the document's own running "AGENCY-N" markers, cross-validated against the document's own printed subtotals |
| `dpcc_major_point_sources_delhi_2023.pdf` | `docs/data/dpcc_point_source_extraction_notes.md` + `data/delhi/processed/dpcc_hotspot_sources_draft.csv` | Manual reading of extracted PDF text (automated table extraction was unreliable on this document's multi-column layout — see [Section 6](#6-station-reference--dpcc-extraction-result)) |

---

## 3. Ward boundary conversion result

**Source:** `delhi_wards.kml` (7,173,765 bytes uncompressed), a real Schema-tagged KML with 251 `Placemark` elements.

- **Ward count: 251** (all 251 placemarks converted successfully; 0 rejected).
- **Geometry validity: 251/251 valid.** Every feature has a closed ring (first point == last point, ≥4 points) and a real `Polygon` or `MultiPolygon` geometry. 0 features had missing/malformed geometry.
- **Coordinate validation: 251/251 pass.** Every coordinate in every ring falls inside the Delhi/NCR bounding box already used by the app (`web/src/lib/mapRules.ts`'s `DELHI_BOUNDS`: lng 76.7–77.7, lat 28.2–29.0). 0 out-of-bounds points.
- **Projection: WGS84 / EPSG:4326**, unchanged from source — KML coordinates are defined as WGS84 by the KML spec itself, so no reprojection step was needed or performed.
- **Uniqueness:** `Ward_No` and `FID` are both unique across all 251 features (0 duplicates in either).

### Available properties and likely field mapping

| Source field | Present on | Likely role | Notes |
|---|---|---|---|
| `Ward_No` | 251/251 | **Ward number** | Integer, e.g. `100`. Recommended unique key. |
| `WardName` | 251/251 | **Ward name** | String, e.g. `FATEH NAGAR`. |
| `WNo_SEC` | 251/251 | (redundant) | Identical to `Ward_No` on all 251 features — not a distinct field. |
| `FID` | 251/251 | **Unique id** (alternative) | Sequential GIS feature id (0-indexed), also unique. `Ward_No` is the more semantically meaningful key. |
| `AC_No`, `AC_No_1` | 251/251 | Not a ward zone | Assembly Constituency number — a different administrative unit (state legislative constituency), not a municipal "zone." |
| `AC_Name` | 251/251 | Not a ward zone | Assembly Constituency name — same caveat as above. |
| `TotalPop`, `SC_Pop` | 251/251 | Population context | Real per-ward population figures (2011 Census-derived, unverified vintage) — not requested by this phase's schema, kept in the output as-is. |
| `NW2022` | 251/251 | Composite label | `"<Ward_No>, <WardName>"` string — redundant with the two fields above. |

**No "zone" field exists in the source data.** Per instruction, this is reported honestly rather than invented — if a municipal-zone grouping (e.g. the 12 MCD zones) is needed later, it must come from a separate source or a manual mapping exercise, not fabricated here.

**Ward count vs. app's existing seed data:** the app currently seeds only 13 "hotspot" wards (`supabase/schema.sql`). This file's 251 wards represent the full municipal ward set — importing it would be a significant expansion in granularity, not a like-for-like replacement, and needs an explicit decision on scope before any import.

---

## 4. Processed outputs created

| File | Rows/features | Status |
|---|---|---|
| `data/delhi/processed/delhi_wards.geojson` | 251 features | Ready for review — see [Section 9](#9-recommended-next-step-for-supabase-import-not-executed) before import |
| `data/delhi/processed/cpcb_caaqms_station_reference.csv` | 79 stations | Ready for review |
| `data/delhi/processed/dpcc_hotspot_sources_draft.csv` | 67 source rows (13 official hotspots only) | Draft — partial by design, see [Section 6](#6-station-reference--dpcc-extraction-result) |
| `docs/data/dpcc_point_source_extraction_notes.md` | — | Complete for its stated scope |

---

## 5. Station reference extraction result

**Source:** `cpcb_caaqms_list_delhi_ncr.pdf`, a 2-page official CPCB list titled "CAAQM Stations in Delhi-NCR."

- **79 stations extracted**, all with `station_name`, `operating_agency`, `city_or_region`, `source_document`, `notes`.
- **Agency assignment is document-derived, not guessed:** the PDF prints running "AGENCY-COUNT" markers (e.g. `CPCB-06`, `DPCC-24`, `IMD-08`) at section boundaries. Agencies were assigned per-row using these markers and cross-validated against the document's own printed subtotals — every derived count matched exactly: CPCB=6, DPCC=24, IMD=10 (8 Delhi + 1 Haryana + 1 UP), HSPCB=21, UPPCB=16, RSPCB=2.
- **Coverage: wider than Delhi alone.** 38 stations are within Delhi proper; the remaining 41 cover Haryana (22), Uttar Pradesh (17), and Rajasthan (2) — this is a Delhi-**NCR** list, as titled, not Delhi-only.
- **Coordinates: absent from this document entirely.** Every row's `notes` field is marked `"Coordinates not present in source document - missing"` — none were invented.
- **Cross-check against `ingest/stations.yaml`'s 2 unresolved stations:** R.K. Puram appears in this list (row 25, DPCC). **Mayapuri does not appear anywhere in this document** — a genuine finding, not an extraction gap (the DPCC PDF's own independent 40-station district list, checked separately, also does not include Mayapuri; see the extraction notes). This is useful, concrete evidence for why that station remains unresolved in `stations.yaml`.

---

## 6. DPCC extraction result

**Source:** `dpcc_major_point_sources_delhi_2023.pdf`, a 48-page official DPCC document ("Inventory of major point air pollution sources in Delhi: Hotspots and other priority areas", 2023).

- **Automated table extraction was tried first and found unreliable** on this document — its multi-column layout (source description / department / personal-contact-info columns) interleaves under `pdfplumber`'s table detector on several pages, producing jumbled row order. Manual reading of the extracted page text was used instead for anything where accuracy mattered.
- **Full extraction completed for all 13 official Delhi hotspots** (Anand Vihar, Ashok Vihar, Bawana, Dwarka, Jahangirpuri, Mundka, Narela, Okhla, Punjabi Bagh, R.K. Puram, Rohini, Vivek Vihar, Wazirpur) — the same 13 wards already seeded in the app. **67 identified-source rows** captured with source description + concerned department(s), zero personal data.
- **"Other priority areas" (24 more locations) were only spot-checked** (6 of 24 read in full: Alipur, Aya Nagar, Burari Crossing, CRRI Mathura Road, KSSR, Patparganj) to confirm the document's structure and check for additional coordinates — **not** included in the draft CSV, to keep that file internally consistent rather than a partial mix. Extracting the rest is a mechanical repeat of the same method, not a new one.
- **Coordinates found: 4 total**, all incidental (embedded inline in a source description, not in a structured field), all at illegal-dumping-site locations, none at hotspot centers or CAAQMS stations:
  - Narela / Bhorgarh dumping site: `28.8335, 77.0931`
  - Narela / Gate No. 3 Industrial Area dumping site: `28.8267, 77.0982`
  - KSSR / near Sangam Vihar colony dumping site: `28.50540502, 77.25875604`
  - Patparganj / Narvana Road dumping site: `28.623105, 77.288956`
- **Department/action data is real and usable**, covering MCD, PWD, DJB, DSIIDC, DDA, Delhi Traffic Police, NHAI, DMRC, NCRTC, NBCC, Indian Railways, Fire Services, DUSIB, Industries Department, Revenue/SDM, and I&FC — a genuine candidate list for extending `responsibility_registry`.
- **CAAQMS station × district cross-reference** (Section V of this document, 40 stations) was captured qualitatively in the extraction notes — an independent list from the CPCB PDF's, with an added `district` field the CPCB PDF lacks.
- **Personal data handling:** the source document contains extensive real personal names and mobile numbers (a "Nodal JEE" contact plus multiple department officials per row, on nearly every one of its 48 pages). **None of this was extracted into any CSV or the notes file** — verified by a post-hoc scan of both outputs for 10-digit number patterns (0 matches in either). Per instruction, this is treated as requiring its own governance/privacy review before any future extraction attempt, not as an oversight to fix here.

---

## 7. Missing fields (honesty summary)

| Dataset | Missing field | Status |
|---|---|---|
| Ward boundaries | Municipal zone | Not present in source — **not fabricated** |
| Ward boundaries | Ward-to-hotspot linkage | Hotspot names (DPCC PDF) are not linked to `Ward_No`/`WardName` by any ID in either source — would require name-matching, not attempted |
| CPCB station reference | Coordinates | Not present in source — every row marked `missing`, **none invented** |
| DPCC hotspot sources | Coordinates (except 4 incidental points) | Not present in source for the other 63 rows — left blank, **none invented** |
| DPCC hotspot sources | Stable source-category taxonomy / severity rating | Not present in source — only free-text descriptions exist |
| DPCC "other priority areas" | 18 of 24 locations | Not extracted in this pass — explicitly out of scope, not silently dropped |

---

## 8. What was not done (per scope)

Per the explicit constraints for this phase, none of the following were done:

- No Supabase migration was created.
- No data was imported into any Supabase table.
- No app/frontend code was changed.
- No RLS policy was touched.
- No production data was modified.
- **Nothing was committed.** The three raw files are currently **staged** (via `git mv`, as part of relocating them into the requested folder structure) but not committed; the processed outputs and this report are untracked. A commit should only happen once this validation report — and anyone reviewing it — is satisfied the outputs are clean, per the original instruction ("do not commit until the validation report is clean").

## 9. Risks and limitations

- **251 wards vs. the app's 13 seeded hotspot wards is a scope decision, not just a data question.** Importing the full ward set changes what "ward" means in the app (city-wide administrative boundary vs. hotspot-only pollution focus) — this needs a product decision before Phase 2.
- **No zone field exists** — if MCD's 12 administrative zones are needed for routing/reporting, they are not derivable from this file and need a separate source.
- **DPCC hotspot-to-ward name matching hasn't been attempted** — "Anand Vihar" (DPCC hotspot) and the corresponding `WardName` in `delhi_wards.geojson` need to be matched by name during Phase 2/7, and Delhi ward names in the KML are official MCD ward names which may not exactly equal DPCC's informal hotspot names (e.g. hotspot "R K Puram" vs. potential ward name variants).
- **CPCB CAAQMS list has zero coordinates** — resolving actual station coordinates still depends entirely on the OpenAQ API (already the case per the main audit), not on any file inspected in this phase.
- **The DPCC draft CSV excludes 24 "other priority area" hotspots' full detail** (18 of 24 not yet read) — treat it as a partial-but-honest artifact, not a complete dataset.
- **Personal data in the raw DPCC PDF remains in `data/delhi/raw/`** (unavoidable — it's the original document) but was deliberately kept out of every processed output. Anyone handling the raw PDF directly should be aware it contains real individuals' names and phone numbers.

## 10. Recommended next step for Supabase import (NOT executed)

This section is a recommendation only — nothing below was run.

1. **Decide ward scope** before writing any migration: import all 251 wards (expanding `wards` beyond the current 13), or derive a 13-row subset matching the existing hotspot wards by name-matching against the DPCC hotspot list. This is a product decision, not a technical one — flag to the user before proceeding.
2. Once scope is decided: write a migration adding/populating `wards.boundary` (the existing but empty `jsonb` column) from `delhi_wards.geojson`, plus new nullable columns for `ward_no`/`total_pop`/`sc_pop` if those are wanted.
3. Cross-reference `cpcb_caaqms_station_reference.csv` against live OpenAQ `/locations` data (per the main audit's Phase 2) to attempt resolving the 2 unresolved `stations.yaml` entries — Mayapuri's absence from both official station lists checked in this phase suggests it may need a different naming search on OpenAQ, not a coordinate guess.
4. Treat `dpcc_hotspot_sources_draft.csv` as seed material for extending `responsibility_registry` (department-level, no personal contacts) — a schema/governance decision for a later phase, not this one.
5. Any import script should be idempotent and logged — as flagged in the main audit, there is currently no dataset/file-import registry table; consider whether Phase 1's import needs one before it happens.

**This report finds the ward GeoJSON and CPCB station CSV clean and ready for review; the DPCC draft CSV is explicitly partial and should be treated as a starting point, not a complete dataset.**
