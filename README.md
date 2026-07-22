# Vayu Gati

*जानकारी से कार्यवाही तक* — From information to action.

## What Vayu Gati Is

Vayu Gati is an air-quality incident response and enforcement intelligence
platform.

It does not replace official AQI dashboards such as CPCB. Instead, it converts
monitoring data into ward-level risk, source hypotheses, evidence requests,
field missions, agency routing, dispatch tracking, and action evaluation.

CPCB tells cities what the air quality is.
Vayu Gati helps cities decide what to do, who should act, and whether the
action worked.

## How Vayu Gati Differs from an AQI Dashboard

| Capability | CPCB / AQI Dashboard | Vayu Gati |
|---|---|---|
| Official station AQI | Yes | Uses as input |
| Pollutant sub-indexes | Yes | Uses as input |
| Ward-level operational risk | Limited | Yes |
| Forecast-based alerts | Limited / not action-first | Yes |
| Source hypothesis | No / limited | Yes |
| Evidence request workflow | No | Yes |
| Field officer mobile workflow | No | Yes |
| Agency routing | No | Yes |
| Dispatch/task tracking | No | Yes |
| Impact evaluation | No | Yes |
| Forecast trust / model validation | Not visible | Yes |

## Vayu Gati Action Loop

**Monitor → Detect → Predict → Attribute → Verify → Dispatch → Track → Evaluate**

- **Monitor** — reads AQ data from station networks.
- **Detect** — identifies threshold breaches and abnormal local excess.
- **Predict** — forecasts pollutant risk over the next 12–48 hours.
- **Attribute** — suggests likely source categories such as road dust,
  construction dust, vehicular, industrial, or waste.
- **Verify** — requests field/citizen evidence before escalation.
- **Dispatch** — routes tasks to the responsible authority.
- **Track** — monitors SLA, status, and evidence.
- **Evaluate** — checks whether action reduced pollution or needs follow-up.

## Current Launch Scope

The current launch build is Delhi-focused (the "Delhi City Pack").

Available:
- 252 ward/boundary geometries
- 34 AQ monitoring stations
- 45k+ readings
- PM2.5, PM10, and NO₂ forecast pipeline
- Strict baseline-validated forecast gate (LightGBM is used only when it beats
  the strongest of several simple baselines; otherwise a safer baseline
  forecast is used and shown as such — never mislabelled as ML)
- Incident, evidence, dispatch, and analytics workflows
- Commander desktop workflow
- Citizen and field-officer mobile workflows

Known limitations:
- Vayu Gati does not replace CPCB or official regulatory dashboards.
- Mayapuri has no direct station-backed data and is treated as
  unresolved/proxy-only.
- Pitampura is unavailable through OpenAQ in the current pipeline.
- ITO/Pusa ward assignment requires manual review.
- FIRMS, OSM, and weather/wind layers are planned but not part of the current
  launch build.
- Source attribution is a probable signal, not a confirmed violation.

## Why Governments Would Use Vayu Gati

Air-quality data already exists, but action coordination is fragmented.

Vayu Gati helps city teams:
- prioritise hotspot wards,
- detect predicted deterioration,
- identify likely source categories,
- request field evidence,
- route cases to the right agency,
- track response status,
- measure whether action worked,
- and maintain an auditable response trail.

## Recommended Demo Flow

1. **Overview** — citywide risk, station health, and forecast trust.
2. **Map** — ward boundaries, station readings, forecast context, and spatial
   risk.
3. **Incidents** — open a predicted or detected incident.
4. **Source Attribution** — show probable source and evidence gaps.
5. **Evidence** — request field/citizen verification.
6. **Dispatch** — show routing blockers or assigned authority.
7. **Sensors** — show data health and station freshness.
8. **Analytics** — show forecast trust, recurrence, source mix, and agency
   performance.

---

## Project history (Phases 0–4)

The section below documents the original phased build-out that the current
Delhi City Pack launch grew out of. Full plan: [docs/build-plan.md](docs/build-plan.md).

- **P0** — auth + role routing, shared map, hourly ingestion of station readings
  (OpenAQ v3) and weather (Open-Meteo) into Supabase.
- **P1** — the loop: citizen reports a source → Claude classifies it → it lands in
  the ward officer's queue → officer advances it to resolved; every status change
  writes a timestamped `report_events` row (the Gati metric).
- **P2** — per-ward 48h PM2.5 forecast on the *local excess* above the city
  baseline (LightGBM once ~10 days of history exists, diurnal-persistence until
  then; RMSE vs persistence is always logged).
- **P3** — directional source attribution via a pollution rose (which wind sector
  is carrying the load into each ward), shown as the field officer's compass.
- **P4** — command intelligence: predictive-GRAP alerts (wards forecast to cross
  severe within 36h), team allocation weighted by predicted local excess, and the
  signal-to-action (Gati) dashboard.

The forecast + attribution job runs at minute :25 each hour, after ingestion.
`POST /intel` recomputes both on demand; `POST /classify` classifies a report.

The repo layout, setup, and deploy instructions below predate the ward/station
expansion described in "Current Launch Scope" above (they describe the
original 13-hotspot-ward pilot) — still accurate for local setup, just not
reflective of the current Delhi City Pack's real ward/station counts.

## Repo layout

```
vayugati/
├── Makefile                        # Supabase CLI convenience targets
├── supabase/
│   ├── schema.sql               # the database baseline (run first, verbatim)
│   └── migrations/              # additive changes, CLI-managed going forward
│       └── 20260714000000_weather.sql   # weather table (idempotent)
├── ingest/                      # Python 3.11 + FastAPI, hourly ingestion
│   ├── stations.yaml            # station list — adding a station is one line
│   ├── requirements.txt
│   ├── .env.example
│   └── app/
│       ├── main.py              # FastAPI app + hourly scheduler
│       ├── ingest.py            # one ingestion pass
│       ├── openaq.py            # OpenAQ v3 client
│       ├── open_meteo.py        # Open-Meteo client
│       ├── aqi.py               # Indian (CPCB) AQI from PM2.5/PM10
│       ├── db.py                # Supabase writes (service_role)
│       └── config.py
├── web/                         # React 18 + TS + Vite + Tailwind + MapLibre
│   ├── .env.example
│   └── src/
│       ├── lib/supabase.ts      # anon-key client
│       ├── lib/auth.tsx         # session + profile (role, ward)
│       ├── components/
│       │   ├── MapView.tsx      # ONE shared map (Delhi placeholder)
│       │   ├── WardCard.tsx     # ONE shared ward card
│       │   ├── ViewShell.tsx    # Phase 0 layout: card + map
│       │   └── RequireRole.tsx  # role-gated routes
│       └── pages/               # Login, CitizenView, FieldView, CommandView
└── docs/build-plan.md
```

## Manual setup (do these once)

### 1. Supabase project

1. Create a project at https://supabase.com/dashboard.
2. SQL editor → paste and run `supabase/schema.sql` (creates enums, tables,
   RLS, and seeds the 13 hotspot wards).
3. SQL editor → paste and run `supabase/migrations/20260714000000_weather.sql`.
   (Or apply it with the CLI — see *Supabase CLI* below. It's idempotent, so
   running it both ways is harmless.)
4. Settings → API: note the **Project URL**, **anon key**, and
   **service_role key**.

### 2. OpenAQ

- Get a free v3 API key: https://explore.openaq.org/register
- Fill in `ingest/stations.yaml` with the OpenAQ **location ids** of the 13
  hotspot stations (search each station at https://explore.openaq.org — the id
  is the number in the URL). Stations with a null id are skipped until filled.

### 3. Env files

```bash
cp ingest/.env.example ingest/.env      # SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, OPENAQ_API_KEY
cp web/.env.example web/.env.local      # VITE_SUPABASE_URL, VITE_SUPABASE_ANON_KEY
```

The web app uses the **anon key only**. The ingest service uses the
**service_role key** (it writes readings/weather, bypassing RLS) — keep it
server-side, never in `/web`.

### 4. Test users and roles

Sign up in the web app (or create users in Authentication → Users). A profile
row is auto-created on first login with role `citizen`. Promote roles and
assign wards in the SQL editor:

```sql
update profiles set role = 'field_officer',
  ward_id = (select id from wards where name = 'Bawana')
where id = (select id from auth.users where email = 'officer@example.com');

update profiles set role = 'commander'
where id = (select id from auth.users where email = 'commander@example.com');
```

## Run

### Ingest (start this first — history accumulates from day one)

```bash
cd ingest
python3.11 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/uvicorn app.main:app --port 8000
```

- Pulls once at startup, then at minute :10 of every hour (UTC).
- `GET /health` — status + last run summary. `POST /run` — trigger a pass now.
- Deploy: any small Python host (Railway / Render / Fly), same env vars.

### Web

```bash
cd web
npm install
npm run dev
```

Login routes by role: `citizen → /citizen`, `field_officer → /field`,
`commander`/`admin` → `/command`.
- **Citizen** — ward AQI + 48h forecast, report a source (photo + geotag, Claude
  classifies it), and a status timeline for their own reports.
- **Field** — ward AQI, forecast, the attribution compass, a daily roll-up, and
  the action queue ranked by predicted impact (with the AI-drafted note).
- **Command** — the Gati metric, predictive-GRAP alerts, team allocation, and all
  13 hotspots over a MapLibre map with colored AQI markers.

The web app calls the ingest service for `/classify`; set `VITE_INGEST_URL` to the
deployed service URL (defaults to `http://localhost:8000`).

## Deploy

Two pieces: the static web app on Vercel, and the always-on Python service on a
small host (Railway / Render / Fly). Keep the `service_role` and `ANTHROPIC` keys
on the Python side only.

### Web → Vercel

- Import the repo, set **root directory** to `web`.
- `web/vercel.json` handles the Vite build and the SPA rewrite (so deep links like
  `/field` don't 404 on refresh).
- Env vars: `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`, and `VITE_INGEST_URL`
  (the deployed ingest URL).
- In Supabase → Authentication → URL Configuration, set the **Site URL** to the
  Vercel domain so email links resolve.

### Ingest → Railway / Render / Fly (always-on, not serverless)

The in-process APScheduler runs ingestion at :10 and forecast+attribution at :25
each hour, so it needs a long-lived process — not a serverless function.

- **Render**: New → Blueprint → this repo; `ingest/render.yaml` defines the Docker
  web service. Fill the four secret env vars in the dashboard.
- **Railway / Fly / any Docker host**: build `ingest/Dockerfile` (it installs
  `libgomp1` for LightGBM and binds `$PORT`). `ingest/Procfile` covers buildpack
  hosts. Health check: `GET /health`.
- Env vars: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `OPENAQ_API_KEY`,
  `ANTHROPIC_API_KEY`.

## Connecting the project

Two independent ways to connect to Supabase. They do different jobs — the CLI
is a developer workflow, MCP gives an AI agent live access.

### Supabase CLI (developer workflow — migrations + typed client)

The model here: `schema.sql` is the one-time baseline you applied by hand;
`supabase/migrations/` holds additive changes, CLI-managed from now on and
written idempotently so a push is safe even against a manually-applied DB.

Run these on **your machine** (they need your token; never paste it in chat):

```bash
# 1. install the CLI (macOS shown; see supabase.com/docs for Linux/Windows/npx)
brew install supabase/tap/supabase

# 2. from the repo root — creates supabase/config.toml for your CLI version
#    (leaves schema.sql and migrations/ untouched)
supabase init

# 3. log in, then link this repo to your hosted project
supabase login
supabase link --project-ref <your-project-ref>   # ref = the subdomain in your project URL

# 4. apply migrations (safe even though weather was applied in the dashboard)
make db-push        # == supabase db push

# 5. generate a typed DB client for the web app
make gen-types      # writes web/src/lib/database.types.ts
```

After `make gen-types`, make the web client type-safe (optional, one line in
`web/src/lib/supabase.ts`):

```ts
import type { Database } from './database.types'
export const supabase = createClient<Database>(url, anonKey)
```

New schema changes from here on: `supabase migration new <name>`, edit the
generated file, `make db-push`. The linked project ref is stored in
`supabase/.temp/` (gitignored).

### Supabase MCP (live DB access for Claude)

This lets Claude read/inspect your database directly during a session — verify
the schema landed, confirm `readings` is filling once ingestion runs, run
ad-hoc queries. Configured project-scoped in `.mcp.json` (committed, so it
travels with the repo) and pinned to **read-only**.

The server is already in `.mcp.json`:

```json
{ "mcpServers": { "supabase": {
  "type": "http",
  "url": "https://mcp.supabase.com/mcp?project_ref=<ref>&read_only=true"
} } }
```

To use it, authenticate **in a local terminal** (not the IDE extension or a web
session — the OAuth flow needs a real terminal):

```bash
claude          # start Claude Code in the repo
/mcp            # select the supabase server → Authenticate
```

- `read_only=true` is deliberate: schema changes go through CLI migrations, not
  ad-hoc through Claude. Drop that param from `.mcp.json` only if you actually
  want Claude to be able to write.
- `project_ref` is not a secret (it's the subdomain of your project URL), so
  committing `.mcp.json` is safe. No token is stored in the repo — auth is
  per-user via the OAuth flow above.
- Optional Supabase agent skills: `npx skills add supabase/agent-skills`.

## Notes

- The `weather` migration is the only thing beyond `schema.sql`: the plan ingests
  Open-Meteo hourly but `readings` has no weather columns, so weather lands in
  its own additive `weather` table (per ward, per hour) — needed as forecast
  features in Phase 2. Nothing in `schema.sql` was modified.
- Basemap is the free MapLibre demo style — swap in a proper style (e.g.
  MapTiler) when the map starts carrying data.
- Phases 1–4 (report loop, forecast, attribution, command intelligence) are
  deliberately not built yet. See docs/build-plan.md.
