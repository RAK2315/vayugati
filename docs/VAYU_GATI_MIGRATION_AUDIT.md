# Vayu Gati — Migration Audit (Phase 0)

Date: 2026-07-17
Source of truth: [docs/vayu-gati-product-plan-v2.md](vayu-gati-product-plan-v2.md)
Superseded plan (kept for history): [docs/build-plan.md](build-plan.md)

This document is the required first deliverable of the migration: a factual audit
of the repository as it exists today, followed by the gap analysis and phased plan
used to drive Phase 1 (shell) and the safest slice of Phase 2 (incident schema).

---

## 1. Current stack

| Layer | Technology | Notes |
|---|---|---|
| Web app | React 18 + TypeScript + Vite 5 + Tailwind 3 + `react-router-dom` 6 | SPA, root at `web/` |
| Map | MapLibre GL 4 | `demotiles` public style, Delhi-centered |
| Auth/DB | Supabase (Postgres + Auth + Storage) | anon key on client, service_role only in `ingest/` |
| Ingest/intel service | Python 3.11 + FastAPI + APScheduler | hourly cron: OpenAQ ingest, Open-Meteo weather, LightGBM/persistence forecast, wind-rose attribution, Claude (Anthropic) report classification |
| Deployment | Vercel (web, static) + Render/Railway/Fly (ingest, Docker, always-on) | `web/vercel.json`, `ingest/render.yaml`, `ingest/Dockerfile`, `ingest/Procfile` |
| DB migrations | Supabase CLI, `supabase/schema.sql` (baseline) + `supabase/migrations/*.sql` (additive) | `Makefile` wraps CLI via `npx --prefix web supabase` |

No test suite exists in either `web/` or `ingest/` (no `*.test.*`, no `pytest`/`vitest` config, no CI workflow under `.github/`). This is a real gap, noted below.

## 2. Repository structure (as-is)

```
vayugati/
├── Makefile                     # supabase CLI targets (link, db-push, db-diff, gen-types)
├── package.json                 # stray root artifact — only pins `supabase` CLI, unused by app code
├── ingest/                      # Python FastAPI ingestion + intelligence service
│   ├── app/{main,ingest,openaq,open_meteo,aqi,forecast,attribution,classify,db,config}.py
│   ├── stations.yaml            # 13 Delhi hotspot → OpenAQ location id map (several ids null/TODO)
│   ├── requirements.txt, Dockerfile, Procfile, render.yaml
├── supabase/
│   ├── schema.sql                # baseline: enums, tables, RLS, seed (13 Delhi wards)
│   ├── migrations/
│   │   ├── 20260714000000_weather.sql        # additive `weather` table
│   │   └── 20260714010000_report_photos.sql  # storage bucket + policies
│   └── config.toml
├── web/
│   ├── supabase/{config.toml,.gitignore}     # stray duplicate CLI init, untracked — housekeeping debt
│   ├── src/
│   │   ├── lib/{supabase.ts, auth.tsx, data.ts}
│   │   ├── components/{AppShell,AqiBadge,AttributionArrow,ForecastChart,MapView,RequireRole,ui}.tsx
│   │   └── pages/{Login,CitizenView,FieldView,CommandView}.tsx
│   └── vite.config.ts, tailwind.config.js, vercel.json
└── docs/{build-plan.md, vayu-gati-product-plan-v2.md}
```

## 3. Routes and role behaviour

Defined in [web/src/App.tsx](../web/src/App.tsx), gated by [web/src/components/RequireRole.tsx](../web/src/components/RequireRole.tsx):

| Route | Roles allowed | Page |
|---|---|---|
| `/` | any (redirect only) | → role home or `/login` |
| `/login` | public | `Login.tsx` — Supabase email/password sign-in + sign-up |
| `/citizen` | `citizen`, `admin` | `CitizenView.tsx` |
| `/field` | `field_officer`, `admin` | `FieldView.tsx` |
| `/command` | `commander`, `admin` | `CommandView.tsx` |
| `*` | any | → `/` |

Role is read from `profiles.role` ([web/src/lib/auth.tsx](../web/src/lib/auth.tsx)). First login auto-creates a `citizen` profile row (self-insert allowed by RLS); promotion to `field_officer`/`commander`/`admin` and ward assignment is manual SQL (documented in `README.md`). There is no in-app role/ward management UI — this is a real operational gap versus the plan's `city_config`/administrator surfaces.

`admin` is allowed on all three views — it is a superuser role, not a distinct "senior administrator" surface as described in plan §4/§18. No senior-admin metrics view exists yet.

## 4. Database: tables, relations, migrations, storage, RLS

### Baseline (`supabase/schema.sql`)

- **Enums**: `user_role` (citizen/field_officer/commander/admin), `report_status` (submitted/verified/assigned/acted/resolved/rejected), `source_category` (construction_dust/road_dust/open_burning/industrial/vehicular/waste/other).
- **Tables**: `wards` (seeded with the 13 official Delhi hotspots, hardcoded lat/lng + `dominant_source`), `stations` (→ ward, external ref for OpenAQ), `profiles` (1:1 with `auth.users`, role + ward), `readings` (time series: pm25/pm10/no2/so2/co/o3/aqi, unique per station+ts), `forecasts` (per ward/horizon: pm25_pred, baseline_pred, local_excess, confidence, model_version), `attributions` (per ward: jsonb breakdown, direction, confidence, method), `reports` (citizen submission: photo, description, `ai_category`, `ai_meta` jsonb, status), `actions` (assignment/enforcement queue, references `reports`, priority_score, evidence jsonb, proof_url), `report_events` (append-only audit trail — the current "Gati" timing instrument).
- **Migrations**: `20260714000000_weather.sql` (additive `weather` table, per ward/hour), `20260714010000_report_photos.sql` (public `report-photos` storage bucket + per-user-folder RLS policies). Both written idempotently (`if not exists` / `drop policy if exists`).

### RLS posture

- `auth_role()` / `auth_ward()` are `security definer` helper functions reading `profiles`.
- Reference/intelligence tables (`wards`, `stations`, `readings`, `forecasts`, `attributions`, `weather`) are readable by any authenticated user; writes only via the ingest service's `service_role` key (bypasses RLS) — correct posture for now, but means **no city/ward scoping on read** (any citizen can read all wards' data — acceptable today since only Delhi exists, but this is exactly what plan §20's `city_config`/tenancy model must fix before a second city is added).
- `reports`: citizen inserts/reads own; field officer reads/updates within their own ward; commander/admin see all. `actions`: same ward-scoping pattern. `report_events`: insert by any authenticated actor (no author check), read follows report visibility.
- No RLS distinguishes "suspected" vs "officially verified" data, no responsibility/ownership table, no SLA/approval concept — none of this exists yet (expected, this is precisely what the plan calls "no negotiable rule" work).

### Storage

- One bucket, `report-photos`, public-read, authenticated write scoped to `storage.foldername(name)[1] = auth.uid()`. Reasonable posture; no virus/type scanning, no size limit enforced at the DB layer (Storage default limits apply from the Supabase project settings, not from a migration).

### Security note (flag, not fixed here)

`web/.env.example` and `web/.env.local` contain a **real** Supabase project URL and anon key (not a placeholder). Anon keys are meant to be public in a browser bundle, so this is low severity as long as RLS is correct — which it materially is — but committing a live-looking key to an "example" file is bad hygiene and reveals the project ref. Recommendation: replace the value in `.env.example` with an obvious placeholder (`https://YOUR_PROJECT.supabase.co`) in a later pass; not changed in this phase because it wasn't in scope for Phase 1/2 and rotating/editing it without confirming the project owner's intent is a judgment call for the user, not this migration.

## 5. Working data integrations

- **OpenAQ v3** ([ingest/app/openaq.py](../ingest/app/openaq.py)) — pulls latest sensor values per station id listed in `stations.yaml`. Several `openaq_location_id` entries are `null` (`R.K. Puram` confirmed missing) — ingestion silently skips those wards, so **not all 13 seeded wards actually receive live readings today**.
- **Open-Meteo** ([ingest/app/open_meteo.py](../ingest/app/open_meteo.py)) — current weather per ward centroid, written to the `weather` table.
- **Anthropic Claude** ([ingest/app/classify.py](../ingest/app/classify.py)) — classifies a citizen report's text + optional photo into `source_category` + a drafted officer note + a Hindi advisory. Falls back to an explicit stub (`category: other, confidence: 0`) with a clear "not configured" message when `ANTHROPIC_API_KEY` is absent — this *is* an example of the "explicit unavailable state" the plan requires, and is a good pattern to keep.
- **Forecast** ([ingest/app/forecast.py](../ingest/app/forecast.py)) — LightGBM once ~10 days of history exist, else diurnal-persistence baseline; RMSE-vs-persistence logged; `model_version` field distinguishes real model vs placeholder — another good existing pattern that maps directly onto plan §16 (compare against persistence, log error, tag model version).
- **Attribution** ([ingest/app/attribution.py](../ingest/app/attribution.py)) — wind-direction "pollution rose" only (single evidence type: wind sector correlated with load). This is a single-signal heuristic, not the multi-evidence fusion (traffic/construction/satellite/citizen/history) required by plan §8 — a major gap, expected to be Phase 3/4 work.

All three external integrations are Delhi/India-specific by construction (OpenAQ station ids in a flat YAML, Open-Meteo by lat/lng which is fine generically, Claude prompt hardcodes "Delhi, India" and Hindi). None are behind a swappable adapter interface yet.

## 6. Current report/action workflow

1. Citizen submits a `report` (description + optional GPS + optional photo) from `/citizen` → `insertReport` in [web/src/lib/data.ts](../web/src/lib/data.ts).
2. Client fires an async, best-effort call to the ingest service's `/classify` endpoint (Claude), which writes `ai_category`/`ai_meta` back onto the same `reports` row.
3. The report appears in the field officer's ranked queue on `/field` (client-side `priorityScore` = source-severity weight × AI confidence × age × ward forecast excess).
4. Officer advances status linearly: `submitted → verified → assigned/acted → resolved`, via `updateReportStatus`, which also appends a `report_events` row (used for the "Gati" — signal-to-action — metric).
5. Command dashboard (`/command`) aggregates: predictive-GRAP alerts (wards forecast ≥400 within 36h), team allocation by forecast local excess (largest-remainder apportionment), and the city-wide Gati median.

There is **no incident concept** — every report is an independent, ward-scoped item; there is no merge/dedupe, no distinction between suspected/corroborated/verified sourcing, no responsibility routing beyond "the officer assigned to that ward," no SLA/escalation, and `resolved` is a single binary state that conflates "officer says done" with "pollution actually went down." This is the core gap the product plan is asking to close.

## 7. Reusable components

Genuinely reusable and worth keeping through the migration:

- `AqiBadge.tsx` — India NAQI scale, colors, and advisory text as one source of truth (`aqiLevel()`), used by badge/gauge/map/chart. Good candidate to become the seed of the new "severity" design token, kept as-is.
- `MapView.tsx` — thin MapLibre wrapper, marker lifecycle handled correctly (added on `map.once('load')`, cleaned up on marker-list change and unmount).
- `ForecastChart.tsx` — no-dependency inline SVG chart; cheap, works, keeps bundle small.
- `data.ts` — all Supabase reads/writes centralized here (no ad hoc queries scattered in components) — this is the right shape to extend with `incidents`-aware functions.
- `RequireRole.tsx` / `auth.tsx` — small, correct role gate and profile fetch; reusable unchanged for the incident-centred model (roles don't change in Phase 1/2).
- `ui.tsx` primitives (`Card`, `CardHeader`, `Skeleton`, `Stat`, `EmptyState`, `Label`) — the right seed for the shared design system; extended in this phase rather than replaced.

## 8. Technical debt and security risks

1. **No tests, no CI.** Any refactor (including this one) is unverified beyond manual `tsc`/`build`/`eslint`-equivalent checks. Flagged; out of scope to build a full test suite in this pass, but noted as a gap in `docs/IMPLEMENTATION_STATUS.md`.
2. **Real-looking anon key committed in `web/.env.example`.** Low severity (anon key, RLS-protected) but should become an obvious placeholder.
3. **Stray artifacts**: root `package.json`/`package-lock.json` (only pins the `supabase` CLI, unused by any app code) and `web/supabase/` (a second, untracked `supabase init` output duplicating `supabase/config.toml`). Not deleted in this pass (avoiding destructive action on files that might be in-progress); flagged for cleanup.
4. **`stations.yaml` has unresolved TODOs** (`R.K. Puram` id null, explicit "DO NOT GUESS" comment) — one seeded ward silently never gets live data. Should be surfaced as a "stale/unavailable" state in the UI rather than silently showing "—", per plan's data-quality requirement.
5. **No city/tenancy boundary.** `wards`, station list, `source_category`, and the Claude system prompt are all Delhi-specific and not config-driven — this is the central structural gap versus plan §20 (City Pack model) and is addressed by the `city_config`/`city_connectors` tables added in this phase (schema only; connector adapters are Phase 4 work).
6. **CORS is `allow_origins=["*"]`** on the ingest FastAPI service (`main.py`) — acceptable for a pre-production single-tenant demo, called out in code comment as needing tightening before production; still open.
7. **`resolved` conflates operational and environmental outcomes** — the single largest product-logic gap the plan calls out explicitly (§15, "a photo proves activity occurred; it does not prove pollution reduction").
8. **Single-signal attribution and single-reading-adjacent detection** — `attribution.py` only correlates wind direction; there is no persistence/threshold/rate-of-increase incident-detection logic yet (plan §6). No incident is ever created from an isolated reading today because there's no incident concept at all yet — but once one is added, the detection rule must not regress to firing on one reading (enforced by design in the Phase 2 schema: `incidents` requires an explicit detection method, not a raw reading insert trigger).

## 9. Gaps against `vayu-gati-product-plan-v2.md`

| Plan requirement | Status |
|---|---|
| `incidents` as central object | Missing — Phase 2 of this migration adds the schema (this pass), UI linking follows |
| Source states: suspected / corroborated / officially_verified | Missing — added as enum in this pass's migration |
| Outcome states (7 states incl. `inconclusive`, `recurred`, etc.) | Missing — added as enum in this pass's migration |
| Evidence fusion / multi-signal attribution | Missing — only wind-direction heuristic exists today |
| Next-best-evidence missions | Missing |
| Responsibility registry / routing | Missing — table added in this pass, routing logic is Phase 3+ |
| Intervention playbooks | Missing — table added in this pass, selection logic is Phase 4+ |
| SLA / approval levels / escalation | Missing |
| Operational vs environmental verification split | Missing — `impact_evaluations` table added this pass (schema only) |
| Six-pollutant, data-quality metadata (freshness/completeness/calibration/confidence) per feed | Partial — `readings` stores all 6 pollutant columns already; no per-reading quality metadata columns yet |
| Connector-based adapters (pollution/weather/mobility/satellite/GIS) | Missing — integrations are direct provider calls, not behind an adapter interface |
| City Pack configurability | Missing — `city_config`/`city_connectors` tables added this pass (schema only); app still hardcodes Delhi wards/categories |
| M365/Outlook-style shared shell, design tokens | Missing — implemented this pass |
| Command list-detail-action workspace | Missing — current `/command` is a dashboard, not an incident queue; deferred to Phase 3 |
| Field offline-capable drafts | Missing — deferred to Phase 3 |
| Citizen missions / recurrence reporting / action verification | Missing — deferred to Phase 3/5 |

## 10. Phased migration plan (this repo, mapped to plan §23)

- **Phase 0 — Audit** (this document). Done.
- **Phase 1 — Shell** (this pass): design tokens, shared role-aware shell (top bar + icon rail + contextual nav), loading/empty/error/stale/offline states, brand placeholder assets. No behaviour change to existing pages beyond chrome.
- **Phase 2 — Incident schema (safest slice, this pass)**: additive migration introducing `incidents`, `incident_evidence`, `incident_source_hypotheses`, `evidence_missions`, `responsibility_registry`, `intervention_playbooks`, `incident_events`, `impact_evaluations`, `city_config`, `city_connectors`, plus nullable `incident_id` link columns on `reports` and `actions`. RLS mirrors existing role model. No existing data is touched; no existing column is dropped or renamed; the current report flow keeps working unchanged. UI linking (creating/merging incidents from reports, incident queue screens) is deferred to a following pass so this slice stays reviewable and reversible on its own.
- **Phase 3 — Role workflows**: command incident queue (list-detail-action), field offline-capable task flow, citizen missions/verification. Not started.
- **Phase 4 — Scientific adapters**: pollutant data-quality metadata, connector interfaces, incident-detection service (threshold/rate/persistence/local-excess), forecast/attribution uncertainty + model metadata. Not started.
- **Phase 5 — Evidence, routing, action**: clustering, source-hypothesis probabilities, next-best-evidence, responsibility routing, SLA/escalation, playbooks, automation-approval levels. Not started.
- **Phase 6 — Verified mitigation**: impact evaluation, outcome metrics dashboard. Not started.

## 11. Files changed in this pass (Phase 1 + safest Phase 2 slice)

**New:**
- `docs/VAYU_GATI_MIGRATION_AUDIT.md` (this file), `docs/ARCHITECTURE.md`, `docs/DATA_MODEL.md`, `docs/ROLE_WORKFLOWS.md`, `docs/DESIGN_SYSTEM.md`, `docs/DATA_QUALITY_AND_SCIENCE.md`, `docs/IMPLEMENTATION_STATUS.md`
- `web/src/design/tokens.ts` — central design tokens (color, type, spacing, radii, shadows, z-index, status)
- `web/public/brand/README.md` — documents required logo asset filenames (placeholder, not a real brand mark)
- `supabase/migrations/20260717000000_incidents_core.sql` — additive incident-centred schema

**Modified:**
- `web/tailwind.config.js` — brand color scale (brown/sky/cream), status colors, Segoe UI-first font stack, z-index scale
- `web/src/index.css` — base type stack, minor state helpers
- `web/src/components/AppShell.tsx` — rebuilt as the shared M365-style shell (top bar, icon rail, contextual nav, responsive workspace)
- `web/src/components/ui.tsx` — added `ErrorState`, `StaleBadge`, `PartialDataBadge`, `OfflineBanner`
- `web/src/pages/Login.tsx` — uses the new wordmark placeholder + brand tokens
- `web/index.html` — favicon reference, theme-color, font preconnect kept

No changes to `ingest/`, `supabase/schema.sql`, or any existing table/column in this pass.

## 12. Rollback strategy

- **Schema**: the Phase 2 slice is a single additive migration file (`20260717000000_incidents_core.sql`) that only creates new enums/tables/indexes/policies and adds two nullable columns (`reports.incident_id`, `actions.incident_id`). Rollback = a follow-up migration that drops those two columns and the new tables (no data loss on existing tables, since nothing existing is altered destructively); until such a migration is written, simply not running this migration (or running `supabase db diff`/reset against a branch) fully reverts the database to its current state. The migration is idempotent (`if not exists` / `drop ... if exists` guards) so re-running it is always safe.
- **Frontend shell**: `AppShell.tsx`, `ui.tsx`, and `tailwind.config.js` changes are isolated to presentation; every page (`CitizenView`, `FieldView`, `CommandView`, `Login`) keeps its existing data-fetching and business logic untouched, so a `git revert` of the shell commit alone fully restores the previous visual system without touching data flow.
- **Deployment**: no changes to `vercel.json`, `render.yaml`, `Dockerfile`, or environment variable contracts — a rollback of the app code requires no infrastructure change.
- **General**: every phase in this migration is designed to be revertible independently (small vertical slices, additive-only DB changes, no renamed/dropped columns) so a bad phase can be rolled back without unwinding later, unrelated phases.
