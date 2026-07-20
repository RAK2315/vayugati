# DPCC Point-Source Extraction Notes

**Source document:** `data/delhi/raw/dpcc_major_point_sources_delhi_2023.pdf` — *"Inventory of major point air pollution sources in Delhi: Hotspots and other priority areas"*, Department of Environment, GNCTD (DPCC), 2023. 48 pages.
**Extraction method:** Direct manual reading of the extracted PDF text (via `pdfplumber`) for all 13 official-hotspot pages (Section VII) plus a representative sample of the "other priority areas" section (Section VIII). Automated table extraction on this document was tried first but produces column-jumbled output on its multi-column layout (personal-contact columns interleave with source/department columns) — manual reading was used instead wherever precision mattered, which is why this is a high-level summary rather than a fully automated parse.
**Privacy note:** This document contains extensive real personal data — named "Nodal JEE" officers and department officials with personal mobile numbers, attached to nearly every row. Per instruction, **none of that personal data is reproduced here or in the draft CSV** — only source category, description, and department are captured. If a future phase needs individual-officer contact routing, that requires its own explicit governance/privacy review, not a byproduct of this data-extraction pass.

---

## 1. Document structure

| Section | Content | PDF pages |
|---|---|---|
| I. Introduction | Delhi context, seasonal pollution drivers, source-apportionment study citations (IITK 2015, TERI-ARAI 2018, SAFAR) | 5-7 |
| II. CAAQMS overview | What a CAAQMS station is/monitors | 7 |
| III. National AQI | AQI bands and health impacts | 8 |
| IV. Air Quality Standards | NAAQS pollutant limit table | 9-10 |
| V. List of CAAQMS locations with Districts | 40 stations, grouped DPCC/CPCB/IMD/MOHUA, each with a Delhi district | 11 |
| VI. Hotspots | Origin/criteria for the 13 official hotspots (PM10 > 300 µg/m³ or PM2.5 > 100 µg/m³ annual average, identified Feb 2019) | 12 |
| VII. Inventorization at 13 Hotspots | Per-hotspot table: identified pollution sources, concerned department, concerned officials (personal data) | 13-31 |
| VIII. Inventorization at other priority areas | Same table format, 24 more locations | 32-48 |

## 2. Delhi hotspots (13) — matches the app's existing seeded wards

Anand Vihar, Ashok Vihar, Bawana, Dwarka, Jahangirpuri, Mundka, Narela, Okhla, Punjabi Bagh, R.K. Puram, Rohini, Vivek Vihar, Wazirpur.

These are the same 13 wards already seeded in `supabase/schema.sql` and configured in `ingest/stations.yaml` — this document is a direct, authoritative source for *why* each of those 13 wards is a hotspot and *what* DPCC has already identified as contributing pollution sources there.

**Full extraction for all 13 hotspots (67 identified-source rows total) is in the draft CSV:** `data/delhi/processed/dpcc_hotspot_sources_draft.csv`.

### Recurring source categories across the 13 hotspots

- **Road dust / unpaved roads / potholes** — the single most common category, present at every one of the 13 hotspots.
- **Construction & demolition (C&D) activity and waste** — major highway/metro projects (NHAI's UER-II corridor recurs at Bawana, Mundka, and Narela; DMRC/NCRTC/NBCC redevelopment projects recur at Ashok Vihar, Jahangirpuri, Mundka, Anand Vihar, R.K. Puram).
- **Illegal garbage dumping and open burning**, including biomass/chulha burning — present at 8 of the 13 hotspots.
- **Traffic congestion at specific named junctions/roads** — present at 10 of the 13 hotspots.
- **Industrial or informal-settlement fuel burning** (Jhuggi-Jhopdi clusters using wood/charcoal chulhas) — explicitly named at Jahangirpuri.

### Concerned departments named across the 13 hotspots

MCD, PWD, DJB (Delhi Jal Board), DSIIDC, DDA, Delhi Traffic Police, NHAI, DMRC, NCRTC, NBCC, Indian Railways, Fire Services, DUSIB, Industries Department, Revenue/SDM, I&FC (Irrigation & Flood Control). This is a real, usable candidate list for extending the app's `responsibility_registry` — see [DELHI_DATA_GAP_REPORT.md](../DELHI_DATA_GAP_REPORT.md) for that table's current state (4 rows today).

### Coordinates found

Point-level coordinates are **rare** in this document — only 2 pairs were found, both at the **Narela** hotspot, embedded inline in a source description (not in a structured coordinate column):

- Bhorgarh, Narela dumping site: `28.8335, 77.0931`
- Gate No. 3, Narela Industrial Area dumping site: `28.8267, 77.0982`

Both fall inside the app's Delhi/NCR bounds (`web/src/lib/mapRules.ts` `DELHI_BOUNDS`). No coordinates were found for hotspot centers or CAAQMS stations themselves anywhere in this document — those would need to come from OpenAQ station metadata instead (see the main audit's Section 8).

## 3. CAAQMS station × district reference (Section V)

This document independently lists all 40 Delhi CAAQMS stations with their **district** (a field the CPCB PDF does not have). Useful as a cross-check/enrichment source for `data/delhi/processed/cpcb_caaqms_station_reference.csv`, not yet merged into it in this pass:

| Group | Stations | Districts covered |
|---|---|---|
| DPCC (24) | Alipur, Anand Vihar, Ashok Vihar, Bawana, Dr. Karni Singh Shooting Range, Dwarka, Jahangirpuri, JLN Stadium, Mandir Marg, Mundka, Najafgarh, Narela, National Stadium, Nehru Nagar, Okhla, Patparganj, Punjabi Bagh, Pusa, R.K. Puram, Rohini, Sonia Vihar, Sri Aurobindo Marg, Vivek Vihar, Wazirpur | North, North West, South West, South East, Shahdara, New Delhi, West, East, North East, South Delhi |
| CPCB (6) | Sirifort, DTU, IHBAS, ITO, NSIT, Shadipur | South, North West, Shahdara, Central, South West |
| IMD (9) | CRRI Mathura Road, IMD Lodhi Road, IITM Lodhi Road, Ayanagar, Pusa Central, DU North Campus, IGI T3, Chandni Chowk, Burari Crossing | South East, New Delhi, South, North, South West, North |
| MOHUA (1) | New Moti Bagh | South West |

**Cross-check against `stations.yaml`'s 2 unresolved stations:** this list confirms R.K. Puram and Mayapuri as intended real CAAQMS locations (R.K. Puram appears here; Mayapuri does not appear in this document at all, in either the CPCB PDF or this DPCC PDF — its absence from both official lists is itself a finding worth flagging, not something to guess around).

## 4. "Other priority areas" (24 locations, Section VIII)

Full list (from the document's own table of contents): Alipur (MGICCC), Ayanagar, Burari Crossing, CRRI Mathura Road, Dr. Karni Singh Shooting Range (KSSR), DTU, DU North Campus, IGI T3, IHBAS, ITO, JLN Stadium, Lodhi Road, Najafgarh (CBPACS), National Stadium (DCN), Nehru Nagar (PGDAV college), New Moti Bagh, NSIT/NSUT, Patparganj (Mother Dairy), Pusa (New Delhi), Pusa (Central), Shadipur, Sirifort, Sonia Vihar (DJB water treatment plant), Sri Aurobindo Marg (NITRD).

**This section was only spot-checked, not fully extracted**, for six locations (Alipur, Aya Nagar, Burari Crossing, CRRI Mathura Road, KSSR, Patparganj) to confirm the document's format is consistent throughout and to check for additional coordinates. It follows the same source/department/personal-contact table structure as the 13 hotspots. Two more inline coordinate pairs were found here:

- KSSR, near Sangam Vihar colony (illegal garbage dumping site): `28.50540502, 77.25875604`
- Patparganj, Narvana Road (garbage/C&D dumping site): `28.623105, 77.288956`

**Not included in the draft CSV** — extracting the remaining 18 unread priority-area locations was out of scope for this pass; doing so later is a mechanical repeat of the same manual-reading method used for the 13 hotspots, not a new technique.

## 5. What this document does NOT provide

- No hotspot-center or CAAQMS-station coordinates (only 4 incidental dumping-site coordinates across the whole document).
- No formal "source registry" with stable IDs, source categories/taxonomy codes, or severity ratings — everything is free-text description.
- No agency contact information suitable for automated routing without a privacy review (see above) — only department names, which are safe to use.
- No ward-boundary linkage — hotspot names are place names, not linked to the `wards` table's `Ward_No`/`WardName` by any ID in this document; matching would need to be done by name (e.g. "Anand Vihar" hotspot ↔ nearest `WardName` in `delhi_wards.geojson`), which was not attempted in this pass.
