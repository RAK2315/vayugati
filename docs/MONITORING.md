# Monitoring

Last updated: 2026-07-25 (Phase 11 — re-verified during Delhi pilot
validation, one real performance finding added).

Provider-neutral by design (plan §10) — no external alerting SaaS is
configured or assumed. What exists: structured logs, database-backed job
health records, a command-centre System Health screen, and a health
endpoint. Wiring any of this into a real paging system (PagerDuty, Slack,
email) is future work — this phase builds the data and surfaces it, it does
not claim to page anyone.

## Structured logging

`ingest/app/logging_utils.py`'s `log_event(...)` emits one JSON line per
significant operation to stdout — the hosting platform (Render) captures
stdout and forwards it to its own log aggregation, so nothing here depends
on a specific logging vendor.

Fields (only the ones that apply to a given event; `None` values are
omitted): `timestamp`, `environment`, `service`, `operation`, `success`,
`duration_ms`, `city_id`, `incident_id`, `task_dispatch_id`,
`correlation_id`, `error_category`.

**Never logged**: citizen free-text content (report descriptions, recurrence
notes), credentials, raw error messages that might contain identifying
detail (only a coarse `error_category` — `network`/`timeout`/`validation`/
`database`/`unknown` — is recorded; the full exception is only ever printed
to the process's own stderr via `log.exception(...)`, not structured/
shipped).

Covered operations: ingestion, anomaly detection, forecasting, source
attribution, notification delivery, SLA escalation (via
`run_tracked(...)`, wrapping every scheduled job — see
`ingest/app/main.py`). Dispatch, routing, and impact evaluation are
on-demand RPC calls triggered by a command action, not scheduled jobs — they
already write an immutable `incident_events` audit row for every state
change (see [DATA_MODEL.md](DATA_MODEL.md)), which is the more appropriate
audit trail for a human-triggered action than a job-run log line.

## Job-run tracking (`job_runs` table)

One row per scheduled-job attempt: `job_name`, `city_code` (null = not
per-city), `status` (`running`/`completed`/`failed`), `started_at`,
`completed_at`, `duration_ms`, `rows_processed`, `error_message`
(truncated to 2000 chars), `error_category`, `attempt`, `correlation_id`.

A **partial unique index** (`job_name, city_code where status='running'`) is
the actual overlap guard — not just application logic, a real database
constraint that makes two concurrent runs of the same job+city structurally
impossible (`start_job_run` returns `null` rather than a row id when
contended; the caller must skip its work, never retry in a tight loop).

Six tracked job names: `ingest`, `anomaly_detection`, `forecast`,
`attribution` (Phase 7's source-attribution engine — the older wind-rose
`attribution.py` module is a smaller, secondary signal and runs untracked,
still logged on failure via plain Python logging), `notifications`,
`escalation`.

RLS: commander/admin read-only; no authenticated write policy at all — only
the service_role connection (which bypasses RLS) ever writes a row, via
`start_job_run`/`complete_job_run`/`fail_job_run`.

## System Health

`system_health_summary()` (SQL function, commander/admin only) rolls up the
latest run of every job+city into `job_name`, `city_code`, `last_status`,
`last_started_at`, `last_completed_at`, `last_error_message`, `is_stale`.
"Stale" means: still `running` after 2 hours (likely crashed mid-run without
reaching `fail_job_run`), or the last successful run is older than 3x its
expected cadence (3h for ingest/forecast/anomaly_detection/attribution, 30m
for notifications/escalation), or the last run simply `failed`.

**Command-centre screen**: `/ops` (Settings in the icon rail, commander/
admin only) — `web/src/pages/OpsView.tsx`'s "System health" section reads
this same function, so the dashboard and the ingest service's own
`/health` endpoint can never disagree about what "healthy" means.

## `/health` endpoint (ingest service)

`GET /health` returns:

```json
{
  "status": "ok | degraded | down",
  "environment": "...",
  "checks": {
    "database": { "status": "ok | down" },
    "reading_freshness": { "status": "ok | stale | no_data", "latest_reading_age_minutes": 12.3 },
    "jobs": { "forecast": { "status": "ok | stale", "last_status": "...", "last_completed_at": "..." }, ... }
  },
  "last_run": {...}, "last_intel": {...}, "last_ops": {...}
}
```

`down` only when the database itself is unreachable. `degraded` when
readings are stale (>3h old) or any job is stale/errored — this is the
literal "return degraded status when dependencies are partially
unavailable" requirement, not a bare up/down. See `ingest/app/
health_checks.py` (unit tested against a mocked client, `ingest/tests/
test_health_checks.py`).

Render's own `healthCheckPath: /health` only looks at the HTTP status code
(`/health` always returns 200 unless the process itself is down) — a
`degraded` body still reads as "healthy" to Render. Watch the response body
via the System Health screen or your own polling, not Render's built-in
check alone, if you want to be paged on `degraded`.

## What would trigger each pilot-grade alert condition (plan §10), and where to see it today

| Condition | Where it's visible today | Real alert delivery |
|---|---|---|
| No new pollution readings | `/health`'s `reading_freshness`, System Health screen | Not configured — would need a real alerting integration |
| Repeated ingestion failure | `job_runs` (`ingest`, `status='failed'`), structured logs | Not configured |
| Forecast/anomaly-detection/attribution worker failure | `job_runs`, System Health screen | Not configured |
| Notification backlog | `notifications` table (`status='pending'`, growing `retry_count`) — no dedicated view yet, direct query | Not configured |
| Dispatch escalation worker failure | `job_runs` (`escalation`) | Not configured |
| Database connection exhaustion | Would surface as `/health`'s `database.status = "down"` | Not configured |
| Unusually high error rate | Would need to be computed from `job_runs`/structured logs over a window — not computed yet | Not configured |
| Storage nearing limits | Supabase dashboard's own storage usage view — not surfaced in this app | Not configured |

Honest summary: this phase built the **data** every one of these conditions
needs (structured logs, `job_runs`, `system_health_summary()`, `/health`) and
a place to **look** at it (the System Health screen). It did not wire up a
real paging integration — doing so needs a provider (Slack webhook, email,
PagerDuty) this environment has no credentials for, matching the standing
"do not fake integrations" rule applied throughout every phase.

## Phase 11: real-scale performance verification

`/health`'s reading-freshness check was measured with `EXPLAIN (ANALYZE,
BUFFERS)` at realistic Delhi pilot volume (~24,000 readings across 11
stations) — it was doing a 5.6ms sequential scan, since no plain
`(ts)` index existed on `readings`, only station-scoped composite
indexes. Fixed via `readings_ts_idx on readings (ts desc)`
(`20260726000000_pilot_validation_performance.sql`); confirmed 0.1ms
index-only scan afterward. No other monitored query (incident queue,
dispatch queue, notification queue, `system_health_summary()` source
data) showed a sequential scan at this volume.

**Stated pilot performance targets** (the first ever documented for this
system): incident-queue and dispatch-queue reads should stay under 50ms
through at least ~5,000 open incidents / ~2,000 active dispatches (10x
this phase's own test volume); `/health`'s freshness check should stay
under 10ms through at least a year of continuous hourly ingestion
(~96,000 readings), now that the index above exists. See
[PILOT_READINESS_REPORT.md](PILOT_READINESS_REPORT.md) section 6 for the
full measurement table.
