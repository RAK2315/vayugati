# Deployment

Last updated: 2026-07-25 (Phase 11 — Delhi pilot validation; hosted
migration completed this phase, after finding and fixing a genuine
migration-ordering bug and two genuine bugs in the smoke test script).

**Current hosted status, verified live this phase**: a hosted Supabase
project exists, reachable both via `supabase db push` (the project
owner's own CLI, with a personal access token) and via the service_role
key already present in this environment's `ingest/.env` (read/write
through PostgREST, no CLI needed). **All 12 migrations are now applied
and committed** — `python3 supabase/scripts/check_hosted_drift.py
--strict` confirms zero drift. The first `db push` attempt failed
partway with a genuine migration-ordering bug (see "Known hosted-push
issue, found and fixed" below); that migration's transaction rolled back
cleanly with zero data loss, the bug was fixed, and the re-run completed
successfully. A row-count comparison across every preserved table
(wards, stations, profiles, readings, forecasts, reports, actions,
weather) captured before the push and re-checked after confirms **zero
change** — real accumulated Delhi data is fully intact.

The hosted end-to-end smoke test (`supabase/scripts/hosted_smoke_test.py`)
was then run against the migrated project and found two further real
bugs in the script itself (not the product) — see that script's own
comments and [PILOT_READINESS_REPORT.md](PILOT_READINESS_REPORT.md)
section 10a for the full writeup. Both fixed; a clean re-run passed
13/13 checks with zero orphaned fixtures.

The Supabase CLI itself is still not linked in THIS environment (no
`SUPABASE_ACCESS_TOKEN`, no `supabase/.temp/project-ref`) — `db push` and
`gen types --linked` were run from the project owner's own machine, not
here. **`database.types.ts` should be regenerated** (`make gen-types`)
and committed now that hosted matches every local migration.

Hosted migration is no longer the blocker for
[PILOT_READINESS_REPORT.md](PILOT_READINESS_REPORT.md)'s final decision
— the remaining conditions for PILOT READY are real Delhi operational
data (`responsibility_registry`, field-officer accounts) and a human
runbook walkthrough, not deployment mechanics.

### Known hosted-push issue, found and fixed this phase

`supabase db push` applies each migration FILE inside its own single
transaction — unlike this repo's local test harness
(`supabase/tests/run.sh`, bare `psql -f`), which auto-commits each
STATEMENT independently. Postgres refuses to use a newly-added enum value
until the transaction that added it has committed, even later in the same
transaction. `20260722000000_source_attribution.sql` used to both add
three new `source_category` enum labels AND use them (in
`get_incident_responsible_authority`) in the same file — this worked
under `psql -f` (masking the bug through all of Phase 11's own local
testing) but failed under `supabase db push` with `unsafe use of new
value ... (SQLSTATE 55P04)`.

**Fixed**: the three `alter type ... add value` statements now live in
their own, earlier-committed migration,
`20260721500000_source_attribution_enum.sql`, which runs and commits
before `20260722000000_source_attribution.sql` (which no longer contains
them) ever executes. Re-run `supabase db push` with this fix in place —
it should now apply cleanly through all 12 migrations. Full detail in
that new file's own header comment and
[DATA_MODEL.md](DATA_MODEL.md)'s Phase 11 section.

**Do not read anything below as "already done to hosted."** Every migration,
test, and check in this repo has been verified against a disposable local
Postgres (`supabase/tests/run.sh`), never against the real hosted project.

## 1. Environments

Four environments, each a **separate Supabase project and separate
deployment** — not one project switched at runtime:

| Environment | Supabase project | Frontend | Ingest service |
|---|---|---|---|
| **local** | disposable Docker Postgres (`supabase/tests/run.sh`) | `vite dev` | `uvicorn` on your machine |
| **test** | same disposable Postgres, torn down after each run | not deployed | not deployed (pytest mocks everything) |
| **staging / pilot** | a real Supabase project, isolated from production | a separate Vercel project/branch | a separate Render service |
| **production** | a real Supabase project, never touched by test data | the real Vercel production deployment | the real Render production service |

**Recommendation for this repo's specific situation**: the one hosted project
that already exists (project ref `xpinidergyqkunoiukal`) has been silently
accumulating real ingest data at the base schema for a while. Treat it as
**staging/pilot**, not production, until Phase 2-9 are applied and verified
there (see §2-3) — do not point a "production" domain at it yet. Create a
genuinely separate Supabase project for production before any real citizen
traffic depends on this system, so a staging mistake can never touch
production data. See [ENVIRONMENT_VARIABLES.md](ENVIRONMENT_VARIABLES.md) for
exactly which values differ per environment.

## 2. Migration safety plan (plan §2)

All 10 migrations (`supabase/migrations/*.sql`, Phases 0-10) are:

- **Additive only** — every `alter table` is `add column if not exists`;
  every `create table`/`create type` is `if not exists`/wrapped in
  `do $$ ... exception when duplicate_object ...`; no migration in this repo
  has ever dropped a column, table, or row of production data. Verified by
  reading every migration's own header comment, which states this
  explicitly, and by the idempotency check below actually re-applying each
  one 3x with zero errors.
- **Explicitly ordered** — filenames are `YYYYMMDDHHMMSS_description.sql`;
  `supabase db push` (and `run.sh`) apply them in that exact lexical order.
  Never renumber or edit an already-applied migration's content — a new
  migration always corrects forward (this repo has already done this once:
  Phase 10 tightens `report-photos` storage policies originally set by the
  Phase 1 migration, via a NEW migration, not an edit to the old file).
- **Idempotent** — `supabase/tests/run.sh` re-applies every migration a
  second and third time after the initial full build and fails loudly on
  any error. Run it yourself before trusting this claim; it is not a static
  assertion.
- **Lock-risk reviewed** — every `add column` uses `if not exists` with no
  data backfill in the same statement (new columns default nullable or to a
  cheap constant), so these are fast metadata-only changes on Postgres, not
  full-table rewrites. The two `not valid` + `validate constraint` pairs in
  the Phase 10 migration (bounded-length checks on already-small text
  columns) are the only constraint additions on existing tables, and both
  use the `not valid` pattern specifically so the `alter table` itself never
  takes a blocking scan lock — `validate constraint` does the actual row
  scan afterward, without blocking concurrent writers.
- **No destructive enum changes** — every enum in this schema only ever
  gains new values (`incident_status`, `task_dispatch_status`, etc.); no
  migration has ever removed or renamed an enum value, which is the one
  genuinely unsafe enum operation in Postgres (removing a value that's still
  in use fails outright; renaming silently breaks anything hardcoding the
  old name).
- **Functions/triggers verified after deployment** — `supabase/tests/run.sh`
  doesn't just apply migrations, it exercises every trigger and function
  through 10 SQL test files (10-110) covering RLS, business rules, and (as
  of Phase 10) an automated introspection check that every `SECURITY
  DEFINER` function pins `search_path`.

**Rollback / forward-fix strategy**: every migration's own header comment
states what dropping it would revert to (see each migration file, or
[DATA_MODEL.md](DATA_MODEL.md)'s per-phase "Rollback" notes). Because
everything is additive, the practical rollback for a bad deploy is almost
always a **forward-fixing migration** (add a corrective one), not reverting
schema — reverting an additive migration only ever means dropping something
nothing yet depends on.

**Data backfill plan**: no migration in this repo has ever required
backfilling existing rows — every new column has a safe default (`not null
default ...` or nullable) and every new table starts empty. If a future
migration ever needs a real backfill, it should run the backfill in
batches inside its own transaction-safe migration, not as a one-off manual
script against production.

### Preflight drift check

```bash
python3 supabase/scripts/check_hosted_drift.py
```

Read-only (never writes anything) — checks one marker table/column/bucket
per migration against the hosted project via the service_role key's REST
API, and reports exactly which migrations have and haven't reached hosted.
Requires `SUPABASE_URL`/`SUPABASE_SERVICE_ROLE_KEY` (env or `--env-file`).
Use `--strict` to exit 1 if anything is missing (useful in a pre-deploy
script). Does **not** need the Supabase CLI to be linked.

## 3. Hosted Supabase deployment — exact manual steps required

This repo's tooling cannot do this without your own Supabase access token.
From a machine with that token:

```bash
# 1. Authenticate the CLI (opens a browser, or use SUPABASE_ACCESS_TOKEN)
npx supabase login

# 2. Link this repo to the hosted project (ref already in the Makefile)
make link

# 3. Compare local migrations against hosted's migration history
make db-diff

# 4. Apply every pending migration — additive, per §2 above
make db-push

# 5. Regenerate TypeScript types from the now-current hosted schema
make gen-types
git diff web/src/lib/database.types.ts   # review before committing

# 6. Verify (read-only, safe)
python3 supabase/scripts/check_hosted_drift.py --strict

# 7. Only once verified: run the hosted smoke test (creates and deletes
#    its own uniquely-tagged fixtures — see its own docstring)
python3 supabase/scripts/hosted_smoke_test.py
```

**Never run `supabase db reset` against hosted** — that recreates the
database from migrations, discarding every row of real data (the 13 wards,
11 stations, 25 readings, 432 forecasts, and 1 profile already there). This
repo's own tooling never calls it against a hosted project; `run.sh` only
ever targets the disposable local Docker container.

After `make db-push`, manually verify in the Supabase dashboard (SQL editor
or Table Editor) that: every table from `docs/DATA_MODEL.md` exists, RLS is
enabled on all of them (`select relrowsecurity from pg_class where
relname = '...'`), and the two storage policies removed by Phase 10
(`report_photos_update`/`report_photos_delete`) are actually gone.

## 4. Frontend deployment

Vercel (`web/vercel.json` — Vite framework preset, SPA rewrite to
`index.html`). Environment variables (Vercel dashboard, per-environment):
`VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY` (never the service_role key —
see [SECURITY.md](SECURITY.md)), `VITE_INGEST_URL`, `VITE_ENVIRONMENT`. See
[ENVIRONMENT_VARIABLES.md](ENVIRONMENT_VARIABLES.md).

Set up **two Vercel projects** (or two environments within one project, with
separate env var sets) — one tracking a `staging` branch pointed at the
staging Supabase project, one tracking `main` pointed at production. Never
let the same Vercel deployment's build point at two different Supabase
projects depending on which branch triggered it — that is how staging data
and production data end up cross-contaminated.

## 5. Ingest service deployment

Render (`ingest/render.yaml` blueprint + `ingest/Dockerfile`). One
always-on web service — the in-process APScheduler needs a long-lived
process, not a serverless function. Required env vars are declared with
`sync: false` in the blueprint (set them in the Render dashboard after first
deploy, per-service): `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`,
`OPENAQ_API_KEY`, `ANTHROPIC_API_KEY`, `SMTP_*` (optional — see
[MONITORING.md](MONITORING.md) on what happens when unset), `ENVIRONMENT`
(`staging` or `production`, per deployed instance — the same blueprint file
is reused for both).

Deploy **two separate Render services** from this one blueprint — a staging
instance pointed at the staging Supabase project, a production instance
pointed at production. `healthCheckPath: /health` is already configured;
Render will report the service unhealthy if `/health` ever returns a
non-2xx status (it currently always returns 200 with a `status` field of
`ok`/`degraded`/`down` in the body — Render's own health check only looks at
the HTTP status code, so a `degraded` body still reads as healthy to Render
itself; watch the body via the System Health screen or your own alerting,
not just Render's built-in check).

## 6. What this phase did NOT do

- Did not apply any migration to hosted (no access token available).
- Did not create a second (production) Supabase project — only one project
  is known to this environment.
- Did not configure any real Vercel/Render deployment — no accounts/tokens
  available here either. Configs are ready; deployment is a manual step.
- Did not configure SMTP, so `ingest/app/notifications.py` uses the
  development-safe mock email adapter wherever it eventually runs, until
  someone sets `SMTP_HOST` etc.

See [PILOT_RUNBOOK.md](PILOT_RUNBOOK.md) for the full step-by-step sequence
tying all of the above together, and
[IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md) for the complete,
itemized list of remaining manual steps and credentials.
