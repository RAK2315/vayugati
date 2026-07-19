# Pilot Runbook

Last updated: 2026-07-25 (Phase 11 — Delhi pilot validation).

**Current sign-off status**: CONDITIONALLY PILOT READY, not PILOT READY —
see [PILOT_READINESS_REPORT.md](PILOT_READINESS_REPORT.md) for the full
evidence, hard blockers, and the exact conditions that remain before this
becomes a real pilot. This runbook's every mechanism has been proven via
real historical-data replay and deterministic end-to-end scenarios (see
[HISTORICAL_REPLAY_REPORT.md](HISTORICAL_REPLAY_REPORT.md) and
[END_TO_END_TEST_REPORT.md](END_TO_END_TEST_REPORT.md)) and structurally
verified step-by-step in
[OPERATOR_ACCEPTANCE_CHECKLIST.md](OPERATOR_ACCEPTANCE_CHECKLIST.md) — but
no real human operator has walked this runbook end to end yet, and hosted
deployment remains blocked (unchanged from Phase 10).

The end-to-end sequence for taking Vayu Gati from "verified locally" to "a
real, running Delhi pilot" — and what to do when something goes wrong once
it's running. See [DEPLOYMENT.md](DEPLOYMENT.md) for the deeper mechanics
behind each step below.

## Before you start

Read [DEPLOYMENT.md](DEPLOYMENT.md)'s current-status section. As of this
writing, the one known hosted Supabase project is stuck on the base Phase
0/1 schema with real accumulated data — confirm this hasn't changed with:

```bash
python3 supabase/scripts/check_hosted_drift.py
```

## 1. Stand up staging

1. `npx supabase login` (needs your own Supabase account access token).
2. `make link` (links to the project ref already in the Makefile) —
   **or**, if you'd rather keep the existing project as a genuine pilot
   environment and create a fresh one for production later, this is that
   moment to decide (see [DEPLOYMENT.md](DEPLOYMENT.md) §1).
3. `make db-diff` then `make db-push` — applies all Phase 2-10 migrations.
4. `make gen-types` — commit the regenerated `database.types.ts`.
5. `python3 supabase/scripts/check_hosted_drift.py --strict` — should now
   report every migration applied.
6. Manually verify in the dashboard: RLS enabled on every table, the two
   `report_photos_update`/`report_photos_delete` storage policies are gone.
7. Deploy the ingest service to Render from `ingest/render.yaml`, set every
   `sync: false` env var in the dashboard (`ENVIRONMENT=staging`).
8. Deploy the frontend to Vercel, set `VITE_ENVIRONMENT=staging` and the
   matching `VITE_SUPABASE_URL`/`VITE_SUPABASE_ANON_KEY`.
9. Confirm `GET <ingest-url>/health` returns `"status": "ok"` (or
   `"degraded"` with an explainable reason — e.g. no readings yet).
10. `python3 supabase/scripts/hosted_smoke_test.py` — safe, self-cleaning;
    confirms auth, city isolation, dispatch, notifications, escalation, and
    audit events all actually work end to end against the real project.

## 2. Seed Delhi configuration

Every phase's own migration already seeds a Delhi `city_config` row with
defaults (anomaly thresholds, forecasting parameters, feature flags, three
SLA rules). What still needs REAL data, filled in via the OpsView pilot
admin screen (`/ops`, commander/admin) or direct SQL, before the pilot
means anything operationally:

- `responsibility_registry`: real agency names, team names, backup
  contacts, working hours, escalation hierarchies for at least the source
  categories you expect to see (construction dust, road dust, vehicular,
  ...). Routing will read `probable` (city-wide match) rather than
  `confirmed` (ward-specific + verified) until this is filled in —
  expected and fine to start, but tighten it before relying on
  auto-dispatch for anything enforcement-adjacent. **Measured this phase**:
  0 of 4 existing Delhi rows are verified or contact-complete — use
  `supabase/RESPONSIBILITY_REGISTRY_IMPORT_TEMPLATE.csv`'s validated
  import process, and never invent a real officer name or contact detail
  to fill a blank field (see [DELHI_DATA_GAP_REPORT.md](DELHI_DATA_GAP_REPORT.md)).
- At least one real `field_officer` profile per ward you're piloting in
  (`profiles.role = 'field_officer'`, `ward_id` set) — currently manual SQL,
  no in-app officer management yet. **Measured this phase**: zero
  `field_officer` accounts exist anywhere in this project — this is a hard
  blocker for any real dispatch (a task can be created and routed, but
  nobody real exists to acknowledge it) until at least one is created.
- Station activation (`stations.is_active`) — confirm every station you
  expect readings from is active; deactivate any known-faulty ones via
  `/ops` so anomaly detection doesn't chase noise from a broken sensor.

## 3. Turn on features deliberately, one at a time

Every risky automated engine has a feature flag (`city_config.config.
feature_flags`, toggle via `/ops`):

`anomaly_detection`, `validated_forecasting`, `source_attribution`,
`citizen_evidence_missions`, `operational_dispatch`, `automatic_escalation`,
`notifications_email`/`_sms`/`_whatsapp`. All default **on** for a city
with no configured opinion — deliberately turn OFF anything you're not
ready to operate yet (most likely candidates for a cautious pilot start:
`operational_dispatch` and `automatic_escalation`, until the responsibility
registry above is real) rather than relying on them defaulting off, since
they don't.

## 4. Watch the first real day

- System Health screen (`/ops`) every few hours: is ingest completing? Is
  anomaly detection running? Any job stuck in `running` (stale)?
- `/health` on the ingest service: same signal, machine-readable.
- `notifications` table: anything stuck `pending`/`failed`? (SMTP
  configured? See [ENVIRONMENT_VARIABLES.md](ENVIRONMENT_VARIABLES.md).)
- First real incident through the full lifecycle: detected → routed →
  dispatched → acknowledged → completed → verified. Watch it manually at
  least once end to end before trusting the automation unattended.

## 5. When something breaks

| Symptom | Look here | See also |
|---|---|---|
| No new readings | `/health` `reading_freshness`, ingest job in System Health | [MONITORING.md](MONITORING.md) |
| Anomaly detection/forecast/attribution job stuck or failing | System Health, `job_runs.error_message` | [MONITORING.md](MONITORING.md) |
| A dispatch stuck at `unresolved`/`disputed` | Operations panel on the incident — resolve via "resolve jurisdiction dispute" or fill in the registry | [DATA_MODEL.md](DATA_MODEL.md) Phase 9 section |
| Notifications piling up | `notifications` table, `/health` `jobs.notifications` | [BACKUP_AND_RECOVERY.md](BACKUP_AND_RECOVERY.md) "Notification outage" |
| A migration failed on deploy | Supabase dashboard SQL logs | [BACKUP_AND_RECOVERY.md](BACKUP_AND_RECOVERY.md) "Accidental migration failure" |
| Frontend showing a blank/broken screen | The new top-level `ErrorBoundary` should catch this and show a reload prompt with a build id — if you see a truly blank screen instead, that's itself a bug worth reporting with the build id from a working page's help menu | — |
| Need to pause an automated engine fast | `/ops` → Feature flags → toggle off | [DATA_MODEL.md](DATA_MODEL.md) Phase 10 section |

## 5.5 Ambiguities found while validating this runbook (Phase 11)

Walking the actual runbook sequence against real, tested mechanisms
surfaced three places where an operator following this document would not
have found a clear answer. Each is now stated here explicitly rather than
left implicit — see
[OPERATOR_ACCEPTANCE_CHECKLIST.md](OPERATOR_ACCEPTANCE_CHECKLIST.md) for
the full mechanism-by-mechanism trace this was derived from.

1. **Handling an officer's rejection of a dispatched task**: the
   mechanism (`transition_task_dispatch(..., 'rejected', ...)`) is real
   and tested, but there is no dedicated runbook walkthrough for "officer
   rejects, command reroutes." In practice: open the Operations panel on
   the incident, review the rejection reason, then either resolve a
   jurisdiction dispute (if the rejection was about wrong authority) or
   dispatch again to a different officer/team.
2. **Reopening an incident after an "ineffective" impact outcome**: there
   is no dedicated "reopen from ineffective" RPC — this uses the exact
   same incident-status update as reopening a still-open incident. If you
   are following this runbook and looking for a distinct button for this
   specific case, there isn't one; use the standard reopen action from
   the incident header.
3. **Recovering a failed scheduled job**: there is no in-app "retry this
   job now" button. Today's actual recovery action is: wait for the next
   scheduled tick (ingest runs hourly, ops/notifications every 5 minutes),
   or, for the ingest service specifically, restart the process, which
   re-attempts on its own bootstrap pass. `job_runs`/System Health will
   show the failure clearly; there is just no manual retry trigger yet.

## 6. Known limitations to plan around

See [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md)'s full numbered
list. The ones most likely to matter operationally in an early pilot:

- City-level RLS scoping doesn't exist yet — fine for a single-city pilot,
  a real gap the moment a second city's data enters the same project (see
  [SECURITY.md](SECURITY.md)).
- No credentialed SMS/WhatsApp — email (if `SMTP_*` configured) and in-app
  are the only real notification channels right now.
- No route optimization or live GPS tracking — dispatch routing is
  jurisdiction-based, not distance-based.
- Resource availability is `unknown` until an officer explicitly reports
  otherwise — never invented, but also never automatically inferred from a
  roster system that doesn't exist yet.
- No in-app playbook editor, no officer/team activation UI — both still
  direct SQL.

## Recommended next steps

Not a new build phase — the concrete, closeable conditions in
[PILOT_READINESS_REPORT.md](PILOT_READINESS_REPORT.md) section 14: apply
the hosted migrations, verify data preservation, import real
`responsibility_registry` data, create real field-officer accounts, keep
`operational_dispatch` command-review-only until the registry data is in,
and have a real human operator walk this document end to end for the
first time.
