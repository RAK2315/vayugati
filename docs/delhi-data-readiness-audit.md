# Delhi Data Readiness Audit

**Type:** Read-only inspection and planning report. No code changes, data imports, migrations, or Supabase modifications were made while producing this document — see [Section 11](#11-risks-and-honesty-notes) for the explicit constraints this audit operated under.
**Date:** 2026-07-20
**Scope:** Vayu Gati is a pan-India air-incident-response platform; Delhi is the first operational "City Pack." This audit inventories what Delhi-specific data, files, database structure, frontend wiring, and API integrations already exist, and what is still needed for a hackathon-ready Delhi MVP.
**Companion document:** [docs/DELHI_DATA_GAP_REPORT.md](DELHI_DATA_GAP_REPORT.md) already covers *operational* data gaps (responsibility registry, field officers, SLA rules, playbooks) in detail dated 2026-07-25 — this audit does not repeat that content and instead focuses on raw geospatial files, CAAQMS/DPCC source documents, satellite/OSM ingestion, database geometry storage, and frontend map data-flow, which that report doesn't cover.

---

## 1. Executive summary

Vayu Gati's Delhi City Pack is **operationally real but geospatially thin**. The database, RLS, ingestion pipeline, and frontend are built on genuine multi-city architecture (`city_config`/`city_connectors`, not a hardcoded Delhi branch) and 13 real hotspot wards are wired to real OpenAQ stations with live PM2.5/PM10/NO2 readings. However:

- **None of the raw files named in the audit request exist in this repository.** `/data/delhi/raw/` and `/data/delhi/processed/` do not exist at all — no `archive.zip`, no `delhi_wards_2022_opencity.zip`, no CPCB CAAQMS PDF, no DPCC point-source PDF, anywhere in the repo. A full-repo search for any `.zip`, `.pdf`, `.kml`, `.shp`, or `.geojson` file returned **zero results**.
- **Ward boundary polygons do not exist anywhere usable.** The `wards.boundary jsonb` column exists in the schema but is never populated by any seed or migration, and the Map page's boundary layer toggle is permanently disabled with the message *"No boundary geometry has been captured for these wards yet."* One real-looking 290-ward Delhi GeoJSON was found on this machine, but it belongs to an unrelated project outside this repo — see [Section 11](#11-risks-and-honesty-notes) before treating it as available.
- **FIRMS (NASA fire/thermal-anomaly) integration is completely unbuilt.** Zero code, zero config, zero documentation references it anywhere in the repo (`NASA_FIRMS_MAP_KEY` does not appear in any file). This is a from-scratch Phase 4 item, not a partially-built one.
- **OSM/Overpass integration is completely unbuilt.** No roads, schools, hospitals, or construction/industrial land-use ingestion exists; "OpenStreetMap" appears exactly once in the codebase, as basemap tile attribution text, not as a data source.
- **OpenAQ and MapTiler integrations are real and working.** `OPENAQ_API_KEY` is fully wired (config, client, `.env.example`, docs); `VITE_MAPTILER_KEY` is fully wired and optional (graceful degrade to a keyless CARTO basemap when unset).
- **No PostGIS.** Confirmed zero occurrences of `postgis`, `geometry(`, or `geography(` anywhere in `supabase/schema.sql` or any migration. All spatial data is plain `lat`/`lng` numeric columns or unused `jsonb`.

**Bottom line for the hackathon MVP:** the app doesn't need ward polygons or FIRMS/OSM layers to function — it already runs on real point data (13 wards, 11 resolved stations, real incidents/tasks/analytics). The missing pieces are additive visual/context layers, not blockers. The single highest-leverage next step is sourcing a real, provenance-clean Delhi ward boundary file (see [Section 6](#6-what-is-missing) and [Section 10](#10-recommended-implementation-sequence-not-executed) Phase 1).

---

## 2. What we already have

| Item | Status |
|---|---|
| Multi-city schema (`city_config`, `city_connectors`) | Real, migrated, Delhi is one row (`city_code = 'delhi'`) |
| 13 seeded Delhi hotspot wards | Real, in `supabase/schema.sql` seed data, `city_id`-scoped |
| 13 configured OpenAQ station mappings (`ingest/stations.yaml`) | Real; 11 of 13 resolved to real OpenAQ v3 location IDs, 2 (R.K. Puram, Mayapuri) explicitly left `null` with a `DO NOT GUESS` comment rather than fabricated |
| Live PM2.5/PM10/NO2/SO2/CO/O3 ingestion from OpenAQ v3 | Real, working (`ingest/app/openaq.py`, `ingest/app/ingest.py`) |
| Real weather ingestion (Open-Meteo) | Real, working (`ingest/app/open_meteo.py`, `weather` table) |
| Incidents, source attribution, task dispatches, intervention playbooks, impact evaluations | Real tables + real RLS + real frontend pages, all Supabase-backed (not seed/mock) |
| Responsibility registry (agency contacts) | Real but partial — 4 rows, sourced but unverified; see [DELHI_DATA_GAP_REPORT.md](DELHI_DATA_GAP_REPORT.md) |
| Delhi map viewport (center, bounds, coordinate validation) | Real, in `web/src/lib/mapRules.ts` (`DELHI_CENTER`, `DELHI_BOUNDS`, `isValidDelhiCoordinate`) |
| MapTiler basemap integration | Real, optional, gracefully degrades without a key |
| Raw geospatial files (ward/zone boundaries, CAAQMS PDF, DPCC PDF) | **None found anywhere in the repo** |
| FIRMS fire/thermal-anomaly integration | **None — zero references anywhere** |
| OSM/Overpass integration (roads, schools, hospitals, land-use) | **None — zero references anywhere** |
| Ward boundary polygons (rendered or stored) | **None — column exists, never populated, layer permanently disabled** |
| Dataset/file import registry | **None — no table tracks one-off manual imports; `job_runs` only tracks scheduled *jobs*, not file imports** |

---

## 3. What is usable immediately

Nothing new was found this audit that's ready to use immediately beyond what's already wired into the app (OpenAQ, Open-Meteo, the 13-ward/13-station config). No raw file in the repo needs conversion because **no raw file exists in the repo** to begin with.

The one candidate item — a 290-ward Delhi municipal-boundary GeoJSON found on this machine — is explicitly **not** counted as "usable immediately" because it lives outside this repository in an unrelated project and its provenance/licensing has not been confirmed. See [Section 11](#11-risks-and-honesty-notes).

---

## 4. What needs conversion

Not applicable this cycle — there is no raw file in the repo to convert (no `.zip`/`.kml`/`.shp`/`.pdf`). This section is a placeholder for when real source files are actually added; the conversion plan is still specified in [Section 10](#10-recommended-implementation-sequence-not-executed) Phase 1 so it's ready the moment a file lands.

---

## 5. What needs API ingestion

| Data | API | Status |
|---|---|---|
| CAAQMS station metadata (coordinates, agency) | OpenAQ v3 `/locations` | Partially done — 11/13 stations resolved; 2 unresolved by design (`DO NOT GUESS`) |
| Latest AQ readings | OpenAQ v3 `/locations/{id}/latest` | Done, live, working |
| Historical AQ readings | OpenAQ v3 | **Only fixture-based replay exists** (`ingest/scripts/historical_replay.py` replays a static Dec-2018 JSON fixture, not a live historical-range fetch) — a real historical-range ingestion path does not exist |
| Weather / wind | Open-Meteo | Done, live, working, but city-wide (not per-ward/per-station) |
| Fire/thermal hotspots | NASA FIRMS | **Not started — no code, no config, no docs** |
| Roads, schools, hospitals, construction/industrial land-use | Overpass/OSM | **Not started — no code, no config** |

---

## 6. What is missing

- **Ward (and zone) boundary polygons** — no source file, no populated column, no rendering path.
- **CPCB CAAQMS PDF-derived station reference list** — file not present; cannot cross-check the 2 unresolved stations (R.K. Puram, Mayapuri) against it without first obtaining the file.
- **DPCC point-source inventory PDF** — file not present; cannot extract hotspot/source/department rows for source-attribution or agency-routing enrichment.
- **FIRMS fire/thermal-anomaly ingestion** — no implementation at any layer (client, config, table, docs).
- **OSM/Overpass ingestion** (roads, schools, hospitals, construction/industrial land-use) — no implementation at any layer.
- **A real historical AQ ingestion path** — today's "historical" capability is a single hardcoded fixture replay, not a general historical-range fetcher.
- **A dataset/file-import registry** — no table records "what manual file was imported, when, by whom." `city_connectors` tracks live API connector status; `job_runs` tracks scheduled job runs; neither tracks one-off file imports.
- **Population/exposure grid layer** — not referenced anywhere in code or docs.

---

## 7. Current app/database readiness

### Schema (from `supabase/schema.sql` + all `supabase/migrations/*.sql`)

20 tables confirmed via direct grep of every `create table`/`create table if not exists` statement: `wards`, `stations`, `profiles`, `readings`, `forecasts`, `attributions`, `reports`, `actions`, `report_events`, `weather`, `city_config`, `city_connectors`, `incidents`, `incident_evidence`, `incident_source_hypotheses`, `evidence_missions`, `responsibility_registry`, `intervention_playbooks`, `incident_events`, `action_evidence`, `impact_evaluations`, `anomaly_candidates`, `task_dispatches`, `sla_rules`, `notifications`, `incident_recurrence_reports`, `admin_audit_events`, `forecast_runs`, `job_runs`.

- **City/jurisdiction scoping is real, not hardcoded.** `wards.city_id`, `incidents.city_id`, `responsibility_registry.city_id`, `intervention_playbooks.city_id`, `anomaly_candidates.city_id` all reference `city_config(id)`. RLS policies in at least 7 migration files (`incidents_core`, `incident_workflow`, `anomaly_detection`, `authority_routing_and_dispatch`, `admin_audit_events`, `unified_forecasting`, `production_hardening`) filter by `city_id`, confirming this is genuine multi-tenant scoping rather than a Delhi-only code path.
- **No PostGIS, no geometry/geography columns.** `grep -rni "postgis\|geometry(\|geography("` across the full schema and every migration returns zero hits. The only spatial storage is plain numeric `lat`/`lng` columns (on `wards`, `stations`, `incidents`, `reports`) plus one unused `wards.boundary jsonb` column intended for a GeoJSON polygon but never populated by any seed or migration, and never read by any app code.
- **`database.types.ts` is authoritative and current** — CI's `database` job (`.github/workflows/ci.yml`) regenerates types from a disposable Postgres built from `schema.sql` + every migration and fails the build on any diff against the committed file. There is no drift risk to report.
- **Existing import scripts** are limited to the live-API ingestion pipeline (`ingest/app/ingest.py` for OpenAQ, `ingest/app/open_meteo.py` for weather) plus one fixture-replay script (`ingest/scripts/historical_replay.py`). No script exists for importing a one-off geospatial file (ward boundaries, PDF-derived tables).
- **No dataset/file-import registry table.** `job_runs` is scoped by a fixed `job_name` check-constraint (`'ingest','anomaly_detection','forecast','attribution','notifications','escalation'`) — it logs *scheduled job* reliability, not *manual file import* provenance. `city_connectors` tracks live API connector enable/sync state, also not file imports. This is a genuine, real gap if the team wants an auditable log of "who imported what file when."

---

## 8. API/key readiness table

| API | Purpose | Key required? | Env var | Caller | Refresh frequency | Target table(s) | Status | Missing work |
|---|---|---|---|---|---|---|---|---|
| MapTiler | Frontend basemap styles (Operational Dark, Satellite Hybrid, Terrain, Minimal Grey GIS) | Optional | `VITE_MAPTILER_KEY` | Frontend (`web/src/lib/basemaps.ts`) | N/A (tile requests) | None (visual only) | **Already used, working, graceful degrade without a key** | None |
| NASA FIRMS | Fire/thermal-anomaly evidence layer | Yes | `NASA_FIRMS_MAP_KEY` | Backend/server-side only | Not yet designed | New table (none exists) | **Not started** — key obtained by user per their note, but zero code references it; not logged or printed by this audit | Full client, config wiring, Delhi/NCR bounding-box clip, storage table, frontend layer |
| OpenAQ | Station metadata, latest readings, (fixture-only) historical | Yes | `OPENAQ_API_KEY` | Backend/server-side (`ingest/app/openaq.py`) | Latest: per ingest cycle | `stations`, `readings` | **Metadata + latest readings done and live**; real historical-range fetch **not built** (fixture replay only) | A general historical-range fetch path, if needed beyond the Dec-2018 replay fixture |
| Open-Meteo | Wind/weather/forecast | No | — | Backend/server-side (`ingest/app/open_meteo.py`) | Per ingest cycle | `weather` | **Done, live** | City-wide granularity only, not per-ward/per-station — acceptable simplification per prior documentation |
| Overpass/OSM | Roads, schools, hospitals, construction/industrial land-use | No | — | Backend, one-time/cached | New table(s) (none exist) | **Not started** | Full client, one-time fetch + cache strategy, storage schema, frontend layer |

**Confirmed via search of the entire repo (secrets never printed, only presence checked):**
- `VITE_MAPTILER_KEY`: referenced in `web/.env.example` (commented, optional), `web/src/vite-env.d.ts`, `web/src/lib/basemaps.ts`, `web/src/components/map/BasemapSwitcher.tsx`.
- `OPENAQ_API_KEY`: referenced in `ingest/.env.example`, `ingest/app/config.py`, `ingest/app/openaq.py`, `docs/ENVIRONMENT_VARIABLES.md`, `README.md`.
- `NASA_FIRMS_MAP_KEY`: **zero occurrences anywhere in the repository** — not in any `.env.example`, config file, docs, or code.

**Optional/later APIs** (not evaluated in depth this cycle, per the audit's scope): Sentinel Hub / Google Earth Engine (satellite imagery beyond FIRMS), dedicated traffic APIs, gridded population/exposure data sources. None are referenced anywhere in the repo today.

---

## 9. Delhi City Pack gap table

| # | Item | Status | Current source | MVP-needed? | Later-needed? | Recommended next action | Risk/limitation |
|---|---|---|---|---|---|---|---|
| 1 | City config | Ready | `city_config` row, `city_code = 'delhi'` | Yes | Yes | None | None |
| 2 | Ward boundaries | Missing | None (column unpopulated) | No | Yes | Source a provenance-clean ward GeoJSON/shapefile, convert to WGS84 GeoJSON, import to `wards.boundary` | Map's ward-boundary layer stays disabled until this exists |
| 3 | Zone boundaries | Missing | None | No | Yes | Define scope (municipal zones vs. traffic zones vs. AQI zones) before sourcing | Undefined scope — needs a decision, not just a file |
| 4 | CAAQMS station metadata | Partially ready | `ingest/stations.yaml` + OpenAQ | Yes | Yes | Obtain CPCB CAAQMS PDF to cross-check/resolve R.K. Puram & Mayapuri | 2 of 13 stations have no OpenAQ location id; do not guess |
| 5 | Latest AQ readings | Ready | OpenAQ v3, `readings` table | Yes | Yes | None | Depends on OpenAQ uptime/coverage |
| 6 | Historical AQ readings | Partially ready | Fixture replay only (Dec 2018) | No | Yes | Build a real historical-range OpenAQ fetch if trend analytics are needed | Fixture is a single fixed month, not general-purpose |
| 7 | Weather/wind | Ready | Open-Meteo, `weather` table | Yes | Yes | None | City-wide granularity, not per-ward |
| 8 | FIRMS fire hotspots | Missing | None | No | Yes | Build Phase 4 client once key is confirmed available server-side | Zero existing code; full build from scratch |
| 9 | Major roads | Missing | None | No | Yes | Overpass one-time fetch + cache | Zero existing code |
| 10 | Construction land-use/risk proxies | Missing | None | No | Yes | Overpass one-time fetch + cache (construction tags) | Zero existing code; tag-quality varies by OSM coverage |
| 11 | Industrial source layer | Missing | None (DPCC PDF not in repo) | No | Yes | Obtain DPCC point-source PDF; extract source/department table | Cannot start without the file |
| 12 | Waste-burning/dumping hotspots | Missing | None | No | Yes | Likely DPCC PDF or a separate dataset — undetermined | No known source identified yet |
| 13 | Schools | Missing | None | No | Yes (exposure context) | Overpass fetch | Zero existing code |
| 14 | Hospitals | Missing | None | No | Yes (exposure context) | Overpass fetch | Zero existing code |
| 15 | Population/exposure layer | Missing | None | No | Yes | Identify a source (e.g. gridded population data) — none referenced anywhere yet | No known source identified yet |
| 16 | Agency registry | Partially ready | `responsibility_registry`, 4 real rows | Yes | Yes | See [DELHI_DATA_GAP_REPORT.md](DELHI_DATA_GAP_REPORT.md) | Sourced but unverified contacts; 0 field officer profiles |
| 17 | Intervention playbooks | Ready | `intervention_playbooks`, 6 rows | Yes | Yes | None | See DELHI_DATA_GAP_REPORT.md for detail |
| 18 | Dataset registry/import logs | Missing | None (`job_runs` covers scheduled jobs only) | No | Yes | Design a lightweight import-log table if manual file imports become routine | No auditable record of one-off file imports today |
| 19 | User jurisdiction/access model | Ready | RLS policies scoped by `city_id`/role across 7+ migrations | Yes | Yes | None | Genuinely multi-city, not Delhi-hardcoded |

---

## 10. Recommended implementation sequence (NOT executed)

The following is a plan only — nothing below was run or applied during this audit.

1. **Normalize manual files.** Once a real ward boundary file is sourced: convert KML/shapefile → GeoJSON, validate/reproject to WGS84 (EPSG:4326), map fields (`Ward_Name`/`Ward_No` or equivalent → the app's `wards.name`/`wards.id`), write an explicit import plan before touching the database.
2. **Station metadata reconciliation.** Fetch full OpenAQ Delhi `/locations` list, cross-reference against a real CPCB CAAQMS PDF once obtained, and attempt to resolve the 2 currently-`null` stations (R.K. Puram, Mayapuri) — only with a verifiable match, never a guess.
3. **Live readings.** Already built and running; no new work required beyond what exists (`ingest/app/openaq.py` → `readings` table, linked to `stations`).
4. **FIRMS ingestion.** Build a backend-only fetcher using `NASA_FIRMS_MAP_KEY`, clip results to the Delhi/NCR bounding box already defined in `web/src/lib/mapRules.ts` (`DELHI_BOUNDS`), store as thermal-anomaly evidence in a new table, surface as an optional Map layer.
5. **Weather.** Already built and running (Open-Meteo); no new work required for MVP-level granularity.
6. **OSM/Overpass ingestion.** Fetch and cache roads, schools, hospitals, and construction/industrial land-use tags for the Delhi/NCR bounding box; design storage and a refresh cadence (this data changes slowly, so a one-time or infrequent cached fetch is appropriate, not a live per-request call).
7. **DPCC source/action extraction.** Once the DPCC point-source PDF is obtained: extract hotspot–source–department rows, build or extend a source registry, wire into agency-routing and playbook logic.
8. **App integration.** Enable the Map's ward-boundary layer once real polygons exist; extend Sensors/Incidents to reference the resolved station set; wire Tasks to any newly-extracted agency data; extend Analytics once new outcome data types exist.

---

## 11. Risks and honesty notes

- **No raw Delhi geospatial or PDF files exist in this repository.** `/data/delhi/raw/` and `/data/delhi/processed/` do not exist; a full-repo search for `.zip`/`.pdf`/`.kml`/`.shp`/`.geojson` returned zero matches. If these files exist somewhere outside this workspace (a laptop, a downloads folder, cloud storage), they were not visible to this audit and must be added to the repo (or pointed to explicitly) before Phase 1 of the plan above can begin.
- **A candidate ward boundary file was found, but it is explicitly out of scope for this project.** `/workspaces/.codespaces/.persistedshare/dotfiles/urban-hydrology-engine/backend/data/delhi_wards.geojson` (734,870 bytes) is a valid `FeatureCollection` with 290 `Polygon` features, each carrying `Ward_Name`/`Ward_No` properties — structurally exactly what Vayu Gati needs, and far more granular than the app's 13 seeded hotspot wards. However: **it belongs to a different, unrelated project** ("urban-hydrology-engine") persisted in this codespace's dotfiles share, not to Vayu Gati. Its data provenance, license, and accuracy have not been verified by this audit. It must **not** be treated as "already available Delhi data" — using it would require the user's explicit review and approval to copy it into this project, and independent confirmation of where it originally came from.
- **`NASA_FIRMS_MAP_KEY` was checked for presence only, per the audit's security constraint — no value was read, logged, or printed.** It does not appear in any file in this repository, which means the key (if the user has obtained one, per their note) has not yet been wired into any `.env.example`, config, or code.
- **The "historical AQ readings" capability is narrower than it may sound.** `ingest/scripts/historical_replay.py` replays one fixed, real fixture (December 2018 Delhi OpenAQ data) for demo/testing purposes — it is not a general historical-range fetcher. Do not present this as "historical ingestion is done" without that caveat.
- **This audit deliberately did not duplicate [DELHI_DATA_GAP_REPORT.md](DELHI_DATA_GAP_REPORT.md).** That report already covers responsibility-registry sourcing, field-officer profiles (0 today), and SLA/playbook completeness in detail — treat the two reports as complementary, not overlapping.
- **Process constraints observed throughout:** no code was changed, no data was imported, no migration was created, no Supabase project was modified, and nothing was committed while producing this report. This markdown file is the only file created during this audit.

---

## 12. Exact next prompts/tasks recommended

1. *"Here are the real Delhi ward boundary files [attach/point to them] — validate their format, coordinate system, and field names, and propose (but do not run) an import plan."* — only once real files are actually supplied; do not proceed using the unrelated-project GeoJSON file found in Section 11 without explicit review and approval.
2. *"Here is the CPCB CAAQMS PDF — extract the station list (names, agencies, coordinates if present) and tell me which of our 13 configured stations it confirms, and whether it can resolve R.K. Puram or Mayapuri."*
3. *"Here is the DPCC point-source inventory PDF — extract the hotspot/source/department table and propose (but do not create) a source-registry and agency-routing enrichment plan."*
4. *"Implement the NASA FIRMS backend fetcher (Phase 4 of the sequence above) — confirm `NASA_FIRMS_MAP_KEY` is present in the environment first, then wire config → client → storage table → optional Map layer."*
5. *"Implement a one-time cached Overpass fetch for Delhi/NCR roads, schools, hospitals, and construction/industrial land-use tags (Phase 6) — propose the storage schema before writing any migration."*
6. *"Design a lightweight dataset/file-import registry table (item 18) so future manual imports — ward boundaries, PDF-derived tables — have an auditable record, separate from `job_runs`' scheduled-job tracking."*
7. *"Build a real historical-range OpenAQ fetch to replace/extend the current Dec-2018-only fixture replay, if trend analytics beyond the current window are needed."*
