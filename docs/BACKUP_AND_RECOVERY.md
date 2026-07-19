# Backup and Recovery

Last updated: 2026-07-25 (Phase 11 — an actual interrupted-migration
recovery was empirically tested this phase; see "Migration recovery"
below).

**No backup has been configured or verified by this phase.** Everything
below states what Supabase provides by default/plan tier and what this repo
already gives you for free (migrations as the schema's own backup) — it does
not claim a working, tested backup exists for the actual hosted project,
because that project's plan tier and backup settings were not inspectable
from this environment (no CLI link, no dashboard access).

## What to actually verify (do this before trusting any backup claim)

1. Open the Supabase dashboard → the project → Settings → Database →
   Backups. Confirm what tier-appropriate backup schedule is active (daily
   backups on paid tiers; the free tier has no automatic backups at all —
   check which tier this project is on).
2. If on a paid tier with Point-in-Time Recovery (PITR) available, confirm
   it is actually enabled — it is not automatic on every paid tier.
3. Take one manual backup/export now, before any Phase 2-9 migration is
   applied to hosted, as a rollback point that predates this repo's schema
   entirely.
4. Document the actual retention window and RPO/RTO your plan tier gives
   you (Supabase's own docs state this per tier) — do not assume "daily
   backups" means "1 day of data loss maximum" without checking.

## Database backup expectations

- **Schema**: fully reconstructable from `supabase/migrations/*.sql` at any
  time, on any Postgres — this is a real, working "backup" of the schema
  itself, verified every time `supabase/tests/run.sh` rebuilds it from
  scratch. This is not a substitute for a data backup.
- **Data**: depends entirely on the Supabase project's own backup
  configuration (see above) — this repo has no independent data backup
  mechanism of its own.
- **Point-in-time recovery**: only as good as what the Supabase plan tier
  and dashboard settings actually provide — verify, don't assume.

## Migration recovery

- A migration that fails partway on hosted: Postgres migrations run inside
  a transaction by default via the Supabase CLI, so a failed migration
  should roll back cleanly rather than leaving a half-applied schema —
  confirm this behavior for your specific CLI version before relying on it.
- Because every migration in this repo is additive, the practical recovery
  from "a migration didn't do what we wanted" is almost always a new
  forward-fixing migration, not a rollback (see [DEPLOYMENT.md](DEPLOYMENT.md)
  §2's migration safety plan).
- If a migration truly needs to be reverted, do it in the opposite order
  from application, and only when you've confirmed nothing added afterward
  actually depends on it (foreign keys will tell you this via constraint
  errors if you try).

### Empirically tested this phase: a genuinely interrupted migration

Phase 11 deliberately tested the "migration interrupted before completion"
failure mode (rather than only documenting a plan for it): applying the
Phase 10 migration file (`20260725000000_production_hardening.sql`) via
`psql -f` against a disposable local Postgres, cut off after only the
first ~450 of 912 lines, deliberately leaving a real partial schema state
(confirmed: some objects existed, others did not, including the very last
statement — Delhi's own feature-flag seed — genuinely absent). The FULL
migration file was then re-applied from scratch.

**Result**: every already-applied object was safely skipped (`if not
exists`/`if exists`/`create or replace` guards fired correctly with zero
errors) and the remainder of the migration completed normally, with no
manual intervention and no data loss. This is now real, tested evidence
for the "additive + idempotent = safely re-runnable after interruption"
claim made throughout this document, not just an assumption resting on
reading each migration's own header comment.

**Caveat, stated plainly**: this tested `psql -f`'s own auto-commit-per-
statement execution model locally (each statement commits independently
as it runs — confirmed by observing that everything before the cut point
had persisted even though the file as a whole never completed). It did
**not** independently confirm the real `supabase db push` mechanism's own
transaction behaviour against the actual hosted project, since hosted
deployment remains blocked this phase (see
[DEPLOYMENT.md](DEPLOYMENT.md)). The underlying safety property this test
demonstrates (idempotent, re-runnable migrations) applies regardless of
which execution mechanism is used, but the exact interruption/recovery
mechanics may differ.

## Storage backup

`report-photos` (Supabase Storage bucket, public-read) — no independent
backup mechanism configured by this repo. Whatever backup/redundancy
Supabase's Storage product provides at your plan tier is what you have;
check the dashboard, same as database backups.

## Configuration backup

`city_config.config` (jsonb — feature flags, anomaly thresholds, dispatch
settings, forecasting parameters) and every other admin-editable row
(`responsibility_registry`, `sla_rules`, `intervention_playbooks`,
`stations.is_active`) lives in the database itself, so it is covered by
whatever database backup exists — there is no separate configuration store
to back up independently. The Delhi seed values for all of these are also
reproducible from the migrations themselves (every phase's own seed block),
which is a real, working fallback if the actual configured values are ever
lost: re-running the seed blocks restores the documented DEFAULT
configuration, though any manual edits made since (via the OpsView pilot
admin screen or direct SQL) would be lost.

## Model artefact recovery

The LightGBM forecast model (`ingest/app/forecast.py`) is **retrained from
scratch on every scheduled run** — it is never persisted to disk or
Storage. There is no "corrupted model file" failure mode to recover from,
because there is no long-lived model artefact at all; a bad forecast run
simply produces a fresh (and, if the underlying data is bad, honestly-
labelled low-quality) result on its next scheduled run. This is a
deliberate simplicity/statelessness choice, not a gap — see
[DATA_QUALITY_AND_SCIENCE.md](DATA_QUALITY_AND_SCIENCE.md).

## Recovery runbook

**Accidental migration failure** (a migration errors out partway on
hosted): check the Supabase dashboard's migration history / SQL editor logs
for the exact error. Since migrations are transactional, the schema should
be unchanged. Fix the migration file's issue, and re-run `make db-push` —
every migration in this repo is idempotent, so a corrected re-run is safe.

**Deleted configuration** (someone deletes a `responsibility_registry` row,
an `sla_rules` row, etc. by mistake via direct SQL or the OpsView screen):
re-seed from the relevant migration's own seed block (each phase's Delhi
seed is a plain `insert ... on conflict do nothing` or similar — safe to
re-run). Custom configuration beyond the seed is only recoverable from a
database backup (see above) — there is no separate audit trail for
DELETEs on config tables the way there is for `incident_events`.

**Failed deployment** (a bad frontend or ingest deploy): Vercel and Render
both keep previous deployments — roll back to the last known-good one via
their own dashboards/CLIs. Neither this repo's CI nor its migrations are
involved in a frontend/ingest rollback, since the database schema is
independent of which frontend/ingest build is currently deployed (as long
as no migration was needed for that deploy).

**Corrupted forecast model**: not applicable — see "Model artefact
recovery" above. If forecasts look wrong, check `forecast_runs.data_quality_
status` and the underlying `readings`/`weather` freshness first; the model
itself has nothing to corrupt since it's retrained every run.

**Notification outage** (SMTP down, or notifications piling up in
`pending`): check `/health`'s `jobs.notifications` status and the System
Health screen. `notifications.py` already retries up to `MAX_RETRIES = 3`
before marking a row `failed` — a `failed` row is not lost, it's visible
and query-able (`select * from notifications where status = 'failed'`) for
manual follow-up or a future retry-reset. In-app notifications are
unaffected by an SMTP outage (they're just an RLS-scoped row the recipient's
own client reads, no transport involved).

**Ingestion outage** (OpenAQ or Open-Meteo unreachable): `ingest.py`'s own
per-station error handling (pre-existing since Phase 0) already isolates
one station's failure from others. Check `/health`'s `reading_freshness`
and `jobs.ingest` status; once the upstream API recovers, the next
scheduled run (or a manual `POST /run`) catches up — there is no gap-filling
mechanism for readings missed during the outage window, since OpenAQ/
Open-Meteo's own APIs are the only source of that historical data and
whether they retain it depends on their own retention, not this repo.

## Restore verification procedure

After any restore (from a Supabase backup, or from re-running migrations
against a fresh project): run `supabase/tests/run.sh`'s equivalent checks
against the restored project — at minimum, `python3 supabase/scripts/
check_hosted_drift.py --strict` (confirms schema completeness) and a manual
spot-check that RLS is enabled on every table (`select relname, relrowsecurity
from pg_class where relnamespace = 'public'::regnamespace`). Do not consider
a restore verified until both pass.
