# Vayu Gati — Build Plan
### Jankari se Karyavahi Tak (from information to action)

---

## What we are building

Vayu Gati is the intelligence and accountability layer on top of Delhi's existing,
broken pollution-response loop.

Delhi already has the pieces. Citizens report sources through the Green Delhi app.
Officers are meant to act through SAMEER and the GRAP-CPCB nodal app. A control room
watches. The loop does not close. Complaints die, the AQI apps go dark during peak
season, and people escalate to NGT and RTI because the app-level loop delivers nothing.

Vayu Gati does not rebuild the complaint box. It makes the loop close, and it adds the
three things the government apps do not have:

1. A ward-level forecast (what will this ward's air do in the next 48 hours).
2. Live source attribution (where is this spike coming from, right now).
3. Prioritised action (which ward, which source, which action, ranked by impact).

It is one product with three role-scoped surfaces:

- **Citizen app** — my ward's air now and next 48 hours, report a source with a photo,
  watch my report move through to resolved.
- **Field app** — the ward officer's forecast, attribution, incoming reports, and a
  ranked action queue, with one-tap logging that closes the citizen's report and also
  generates the officer's daily roll-up.
- **Command dashboard** — all 13 hotspots at once, predictive alerts before GRAP would
  fire, and allocation of limited enforcement assets across wards.

---

## The one principle

Every feature makes the response **earlier in time or finer in space**. If it does
neither, cut it.

The product's single metric is Gati: time from signal to action. The government
baseline is days, or infinity when a complaint dies. The schema instruments this by
design, so every build decision is judged by whether it moves that number.

---

## Architecture

Three surfaces, one backend.

```
        CITIZEN            FIELD OFFICER           COMMANDER
        /citizen            /field                 /command
           \                   |                      /
            \                  |                     /
             \                 |                    /
        +---------------------------------------------------+
        |     React app (Vite + TS + Tailwind + MapLibre)   |
        |     one app, routes gated by role                 |
        +---------------------------------------------------+
                               |
                               | (Supabase JS client, RLS enforced)
                               v
        +---------------------------------------------------+
        |   SUPABASE  (Postgres + Auth + Storage + RLS)     |
        |   single source of truth:                         |
        |   profiles wards stations readings forecasts      |
        |   attributions reports actions report_events      |
        +---------------------------------------------------+
                       ^                    ^
        (writes readings/forecasts)   (classify + draft)
                       |                    |
        +-----------------------+   +-------------------------+
        |  PYTHON / FastAPI     |   |   Anthropic API (Claude)|
        |  1. ingest stations   |   |   - classify report     |
        |     + weather (cron)  |   |   - draft enforcement   |
        |  2. forecast + attrib |   |     note                |
        |     (writes back)     |   |   - Hindi advisory      |
        +-----------------------+   +-------------------------+
                 ^        ^
          OpenAQ v3   Open-Meteo   (Sentinel-5P via GEE, later)
```

- **Frontend**: one React app. Routes `/citizen`, `/field`, `/command`, gated by the
  user's role. Shared map component and ward-card component reused across all three.
- **App backend**: Supabase. One database, auth, photo storage, row-level security.
- **Compute**: one Python (FastAPI) service with two jobs. A scheduled ingestion job
  that pulls station and weather data into Supabase. A forecast + attribution job that
  computes and writes results back.
- **AI layer**: Anthropic API for classifying a report's photo and text into a source
  category, drafting the officer's enforcement note, and writing the Hindi advisory.

---

## Tech stack (locked)

- Frontend: React 18, TypeScript, Vite, Tailwind, MapLibre GL JS (deck.gl only if the
  command layer needs it)
- App backend: Supabase (Postgres, Auth, Storage, RLS, Edge Functions)
- Compute: Python 3.11, FastAPI, LightGBM, pandas, geopandas, scikit-learn
- AI: Anthropic API (Claude) — report classification, note drafting, Hindi advisory
- Deploy: Vercel (frontend), Supabase (managed), one small Python host with cron
  (Railway / Render / Fly) for the FastAPI service

---

## Data model

Full schema is in `schema.sql`. The spine:

- `wards` — seeded with the 13 official hotspots
- `stations`, `readings` — the ingested time series
- `forecasts` — per ward, includes `local_excess` so we forecast the controllable part,
  not the regional baseline
- `attributions` — per ward, directional and time-specific
- `reports` -> `actions` -> `report_events` — the loop and the metric

**Why `local_excess` matters.** A ward officer cannot move the regional baseline that
comes from stubble smoke and NCR transport. No 36-hour ward action touches that. What
they can move is the local excess sitting on top: dust, construction, burning, industry.
So we forecast and act on the delta above the city baseline. That is the part the
officer controls, and it is also the part you can measure success against after an
intervention. Never forecast "Bawana AQI 450." Forecast "Bawana local load will rise
120 above the city baseline in 36 hours, and that part is yours to kill."

**Why `report_events` matters.** Every status change writes a timestamped row with who
did it. Signal-to-action time is just `resolved_at - created_at`, computed from real
data, not claimed. Your entire pitch metric is a database query.

---

## The three views

**/citizen** (warm, big, Hindi-first, one primary action)
- Ward AQI now + 48h forecast, in plain language and Hindi
- Report a source: photo + geotag, Claude classifies the category
- My reports: status timeline (submitted, verified, acted, resolved)
- Permissions: create own reports, read own reports, read own ward's public data

**/field** (utilitarian ops tool, fast, works offline)
- Ward forecast + attribution (the directional "look here now" arrow)
- Incoming citizen reports for this ward
- Ranked action queue for tomorrow, evidence pre-attached, note pre-drafted
- Log action + upload proof, which closes the citizen's report
- Auto-generated daily roll-up (replaces the manual War Room report)
- Permissions: read reports/actions in assigned ward(s), update their status

**/command** (dark, dense control room, map-heavy)
- All 13 hotspots: current, forecast, trend
- Predictive-GRAP alerts: wards crossing severe in 36h before city average triggers GRAP
- Allocation of limited assets (anti-smog guns, teams) across wards — reuse the
  FloodReady linear-programming dispatch logic
- Signal-to-action metrics across wards
- Permissions: read everything, create and allocate actions across wards

---

## Data sources

- AQI: OpenAQ v3 (wraps CPCB and DPCC stations). Fallback: CPCB / data.gov.in.
- Weather: Open-Meteo (free, no key).
- Ward boundaries: open Delhi ward GeoJSON, or a 2km radius around each hotspot station.
- Satellite (later): Sentinel-5P NO2 columns via Google Earth Engine, as an overlay.
- **Demo-safe rule** (from FloodReady): cache a static snapshot so a rate limit or an
  app outage on the day cannot kill the live pull.

---

## ML approach (scoped honestly)

**Forecast.** LightGBM per pollutant, PM2.5 first. Features: lags, weather forecast,
time-of-day and day-of-week. Target: local excess above city baseline. Bar to clear:
beat a persistence baseline on RMSE. Log and report that number. It is the literal
evaluation metric and it goes on a slide.

**Attribution.** Pollution rose (which wind directions bring high pollution to this
station) + land-use regression (how much local variance is road vs construction vs
industry) + optional Sentinel-5P NO2 overlay. The output is directional and
time-specific: "this 2pm spike is coming from the north-west construction corridor,"
not a static annual "this ward is dust-dominant" that DPCC already publishes. Validate
against DPCC's known hotspot source labels, because agreement is a credibility number.
State the method's limits in the deck and in the UI. Honesty scores here.

---

## Build sequence

Each phase ends with a working vertical slice, not a layer that only makes sense later.

**Phase 0 — Foundations, and start ingesting now**
- Repo, Supabase project, run `schema.sql`, seed the 13 wards
- Auth with roles, React shell with role routing showing the right view per role
- Ingestion cron pulling OpenAQ + Open-Meteo into `readings` every hour
- Definition of done: three roles log in and land on their view; `readings` is filling
  up on its own. History starts accumulating today so the forecast has data later.

**Phase 1 — The loop (ships without ML, this is what you pilot)**
- Citizen report: photo + geotag, Claude classifies category
- Report lands in the field queue for that ward
- Officer logs action + uploads proof, which flips the report to resolved
- Citizen sees the status move
- Forecast is a placeholder here (just the latest reading or persistence)
- Definition of done: a report goes citizen -> field -> resolved end to end, and
  `report_events` shows the timestamps. You now have a real, demoable, pilotable loop.

**Phase 2 — Forecast**
- LightGBM per pollutant on the data Phase 0 has been collecting
- Local-excess framing, beat persistence baseline, store in `forecasts`
- Show the 48h forecast in citizen, field, and command views
- Definition of done: forecast RMSE beats persistence, and the number is logged.

**Phase 3 — Attribution**
- Pollution rose + land-use + optional Sentinel-5P overlay
- The directional "spike coming from the NW" pointer in the field view
- Definition of done: attribution renders per ward and matches DPCC labels on the
  static test.

**Phase 4 — Command intelligence**
- Predictive-GRAP alerts (ward crosses severe before city average does)
- LP allocation of assets across wards
- Signal-to-action dashboard
- Definition of done: command view ranks wards and allocates a fixed set of teams.

---

## Decisions made (override if you disagree)

- Single Supabase Postgres as system of record, instead of DuckDB + Supabase. One
  source of truth. Use DuckDB only locally for heavy model-training queries if you want.
- Build the loop before the ML. The loop is the product and is pilotable without a
  model. Ingestion runs from Phase 0 so history accumulates in parallel.

---

## What NOT to build (yet)

- Multi-city. Delhi only.
- All 250 wards. 13 hotspots, and 3 or 4 for the first build.
- Regional / stubble forecasting. Not the officer's lever.
- A replacement for Green Delhi. Coexist and add intelligence, do not compete on the
  complaint button.
- IVR, languages beyond Hindi, public displays. Later.
