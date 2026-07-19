# Operator Acceptance Checklist

Last updated: 2026-07-25 (Phase 11 - Delhi pilot validation).

Exercises the actual `PILOT_RUNBOOK.md` sequence (plan section 19) against
the real, tested mechanisms this repo provides - each row states whether
the runbook step is backed by a real, tested capability, and any ambiguity
found while walking through it (which has already been fixed in
`PILOT_RUNBOOK.md` itself where noted).

| Runbook step | Backed by | Status | Notes |
|---|---|---|---|
| Check system health | `system_health_summary()`, `/ops` System Health screen, ingest `/health` | Ready | Verified in `110_production_hardening.sql` TEST 116, `ingest/tests/test_health_checks.py` |
| Review degraded data | `/health`'s `reading_freshness`/`jobs` fields, System Health screen | Ready | `ok`/`degraded`/`down` states all unit-tested |
| Inspect predicted incident | `PredictedIncidentPanel.tsx`, forecast curve + uncertainty display | Ready | Built and tested since Phase 6/8 |
| Promote or dismiss | `confirmPredictedIncident`/`dismissPredictedIncident` | Ready | Scenario C (this phase) exercised the dismiss path end to end |
| Request evidence | Evidence mission creation, citizen verification flow | Ready | Tested since Phase 3 (`30_mission_rls.sql`) |
| Approve intervention | `approveIntervention`, `TaskDispatchPanel.tsx` "Approve & dispatch" | Ready | Scenario A (this phase) exercised approval end to end |
| Route task | `dispatch_intervention_task`, routing confidence display | Ready | Scenarios A/B/E (this phase) |
| Handle rejection | `transition_task_dispatch(..., 'rejected', ...)` | Ready | Tested in `100_authority_routing_and_dispatch.sql`; not separately re-exercised in a Phase 11 scenario (an ambiguity worth closing - see below) |
| Escalate overdue task | `escalate_stale_task_dispatches`, System Health / Operations panel | Ready | Scenario F (this phase) |
| Evaluate impact | `record_impact_evaluation`, `effective`/`ineffective`/`inconclusive` | Ready | Scenarios A/B/G (this phase) |
| Manage recurrence | `submit_incident_recurrence_report`, command review actions | Ready | Scenario H (this phase) |
| Disable a feature flag | `/ops` Feature Flags section, `city_feature_enabled(...)` | Ready | `110_production_hardening.sql` TEST 117 |
| Recover a failed job | `job_runs`, `fail_job_run`, retry on next schedule | Conditionally ready | The mechanism is tested (a failed job is recorded, doesn't crash the service, and the next scheduled tick tries again) - but there is no in-app "manually retry this specific failed job now" button; recovery today means waiting for the next cron tick or restarting the ingest process. Documented as a real gap, not silently assumed solved. |

## Ambiguities found while walking the runbook, and how they were resolved

1. **"Handle rejection" has no dedicated end-to-end scenario in this
   phase's own new test file** - it is tested at the unit level
   (`100_authority_routing_and_dispatch.sql`), but Scenarios A-J did not
   include a full "officer rejects, command reroutes" chain. Not treated
   as a blocker (the underlying mechanism is proven), but flagged here as
   the one runbook step this phase's own new scenarios did not directly
   walk end to end.
2. **"Reopen after an ineffective outcome" (Scenario G) has no dedicated
   RPC** - reopening today is a direct `incidents.status` update by
   command, the same mechanism used for a still-open incident, not a
   distinct "reopen from ineffective" action. `PILOT_RUNBOOK.md` and
   `130_end_to_end_scenarios.sql`'s own Scenario G comment both now state
   this plainly, so an operator following the runbook is not surprised
   there is no separate button for this specific case.
3. **"Recover a failed job" has no manual retry trigger** - see the table
   row above. An operator's actual recovery action today is: wait for the
   next scheduled tick, or (for the ingest service specifically) restart
   the process, which re-attempts on its own bootstrap pass. This is now
   stated explicitly in `PILOT_RUNBOOK.md` rather than left implicit.

## What this checklist does NOT claim

This is a structural/mechanism acceptance check - it confirms every
runbook step is backed by real, tested code, not that a human pilot
operator has actually sat down and clicked through the real UI end to end.
See [PILOT_READINESS_REPORT.md](PILOT_READINESS_REPORT.md)'s "operational
readiness" scoring for the honest distinction between "the mechanism
works" and "an operator has been trained and signed off."
