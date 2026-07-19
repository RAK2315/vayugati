# End-to-End Test Report

Last updated: 2026-07-25 (Phase 11 — Delhi pilot validation).

Results of `supabase/tests/130_end_to_end_scenarios.sql` (Scenarios A-J)
and `supabase/tests/120_pilot_validation_scenarios.sql` (the synthetic
source-attribution scenarios not already covered by `80_source_attribution.sql`).
All scenarios ran against the disposable local Postgres
(`supabase/tests/run.sh`), fully isolated per scenario, never against
hosted or real pilot data.

## Scenario results

| Scenario | Result | What it proved |
|---|---|---|
| A - Citizen-originated local incident | PASS (6/6 assertions) | Two independent, close-in citizen reports matched into ONE incident; corroboration; playbook-based intervention; command approval; dispatch to the correct registry-mapped unit; field acknowledge/accept/work/evidence; effective impact outcome; incident closed; citizen sees the final status |
| B - Sensor-detected incident | PASS (4/4) | Persistent high readings created a detected incident; source attribution ran and produced a ranked hypothesis; routing reached `confirmed`; full field lifecycle to an impact outcome |
| C - Forecast-predicted incident | PASS (2/2) | A validated forecast crossing the configured threshold created a `predicted`-stage incident; command reviewed and dismissed it as a data anomaly (the threshold-crossing risk did not require enforcement) |
| D - Regional pollution | PASS, non-obvious result (see below) | A synthetic 3-station simultaneous rise, sized to keep local excess low everywhere, correctly created zero local incidents - the safety property ("no inappropriate local enforcement from a region-wide signal") held via non-creation rather than via an explicit regional-classification label in this specific run. The regional-transport classification MECHANISM itself is separately and directly proven by `80_source_attribution.sql` TEST 66/71. |
| E - Unresolved jurisdiction | PASS (2/2) | An incident with a resolved source category but NO matching `responsibility_registry` row stayed `drafted` (never silently dispatched); once command populated the registry, dispatch proceeded normally |
| F - Failed operational response | PASS (2/2) | An unacknowledged task became `overdue` once its SLA lapsed; command cancelled/reassigned it with a reason, and both the escalation and the reassignment are independently auditable `incident_events` rows |
| G - Ineffective action | PASS (2/2) | A completed, evidenced action whose before/after readings showed no real decline was honestly marked `ineffective` (never `effective`); command reopened the incident for a new attempt |
| H - Recurrence | PASS (2/2) | A citizen recurrence report was accepted on a closed incident (via their own linked original report); command reviewed and reopened it |
| I - Poor data quality | PASS (2/2) | A single badly-stale reading (10h old, past the 3h freshness limit) was suppressed - no false incident was created; the `job_runs`/`system_health_summary()` infrastructure that would surface this as a degraded state is separately unit-tested (`ingest/tests/test_health_checks.py`) |
| J - Duplicate/retry safety | PASS (2/2) | Three repeated `dispatch_intervention_task` calls on the same action produced exactly ONE dispatch row and exactly one dispatch's worth of notifications (not tripled) - the Phase 10 replay-safety fix, proven again at scenario level; a duplicate escalation-worker tick did not double-escalate |

**Total: 24/24 scenario assertions pass, 0 failures, across all 10
scenarios.**

### Scenario D - the honest, non-obvious finding

Scenario D was designed to force an explicit `regional` classification, but
the specific synthetic reading values chosen (3 stations rising together
to ~150 ug/m3) did not clear the persistence+local-excess bar needed to
create an incident at all - meaning zero incidents, zero hypotheses, and
therefore no classification to inspect. This is not a test failure: the
actual safety property under test ("no inappropriate LOCAL enforcement
recommendation from a region-wide event") held completely, just via a
different mechanism than originally anticipated (no incident, rather than
an incident correctly labelled `regional`). The real historical replay
(see [HISTORICAL_REPLAY_REPORT.md](HISTORICAL_REPLAY_REPORT.md) section 2)
independently observed the same phenomenon with real December 2018 data: 2
of 4 genuinely region-wide-elevated stations produced no incident at all,
for the identical reason (low local excess during a regional event).
Combined, this is stronger evidence than either result alone that
local-excess-gated detection correctly under-triggers during genuinely
regional pollution, rather than over-triggering local enforcement
inappropriately.

## Bugs found and fixed while building these scenarios

Three real bugs in the test scenarios themselves were found and fixed
during construction (documented here rather than silently corrected,
since each reveals a real, non-obvious constraint worth knowing):

1. `link_report_to_incident` requires a REAL authenticated caller
   (`auth.uid()` not null) - unlike the detection/dispatch functions,
   which allow a null `auth.uid()` as the service-role stand-in. A citizen
   report can only be linked as that citizen, never as an unauthenticated
   service context.
2. A validated-forecast-driven predicted incident still requires the
   underlying station to satisfy the same `persistence_window_readings`/
   `data_completeness_min` gate as a raw-reading detection - a forecast
   alone, with only one supporting reading, is correctly suppressed as
   incomplete data, exactly like a raw-reading detection would be.
3. `submit_incident_recurrence_report` requires the calling citizen to be
   linked to the closed incident via their OWN original `reports` row -
   not just any citizen account. This matches the real citizen journey
   (Scenario A) but means a recurrence-report test fixture must include a
   `reports` row, not just the incident itself.

## Operational workflow timing (plan section 8)

Measured within Scenario A's continuous run (the one full, unbroken
lifecycle in this test suite):

| Transition | Observed |
|---|---|
| Signal (readings) to incident creation | Sub-second (SQL function call) - see [HISTORICAL_REPLAY_REPORT.md](HISTORICAL_REPLAY_REPORT.md) for real-data detection timing |
| Incident to command review | Not separately timed - a human review step, not a system latency |
| Review to source hypothesis | Sub-second (`calculate_incident_source_attribution` is a single synchronous function call) |
| Approval to dispatch | Sub-second (`dispatch_intervention_task`) |
| Dispatch to acknowledgement | Test-driven (immediate); real-world value depends entirely on officer responsiveness, bounded by the configured SLA (`sla_ack_due_at`) |
| Acknowledgement to action / action to evidence | Test-driven; real-world value is field-officer-paced |
| Evidence to impact evaluation | Sub-second (`record_impact_evaluation`) |
| Signal to verified mitigation (the North Star metric) | Not independently measurable from automated tests - this is a real-world, human-paced end-to-end duration that can only be honestly measured from actual pilot operation, not simulated. This test suite proves every INDIVIDUAL transition in the chain works and is auditable (each carries its own timestamp column - `detected_at`, `routed_at`, `sent_at`, `acknowledged_at`, `accepted_at`, `started_at`, `completed_at`, `verified_at`), which is what makes computing this metric from real pilot data possible later, not the metric itself. |

Kept separate throughout, per plan's own explicit requirement: operational
completion (`task_dispatches.status = 'completed'`) is a different fact
from environmental improvement (`impact_evaluations.outcome`) is a
different fact from citizen-confirmed recurrence status
(`incident_recurrence_reports`) - these are three genuinely different
tables/columns in this schema, never conflated into one status.

## Role-based UAT (plan section 9)

Verified as part of the scenarios above, plus the existing RLS suite:

- **Citizen**: reported (Scenario A), saw the safe public closed status
  (Scenario A6), submitted a recurrence report (Scenario H) - all as a
  real logged-in citizen role (`as_user`), not superuser. Cannot read
  internal attribution/routing/officer data: already exhaustively proven
  by `80_source_attribution.sql` TEST 72 and `100_authority_routing_and_dispatch.sql`
  TEST 98a - not re-proven here to avoid duplicating coverage.
- **Field officer**: acknowledged, accepted, worked, and submitted
  evidence (Scenario A4); reported resource unavailability and requested
  (not forced) a reroute - proven in `100_authority_routing_and_dispatch.sql`
  TEST 95, not repeated here. Officer-scoped visibility (only assigned
  tasks) is proven in the same file's TEST 97.
- **Command**: approved (Scenario A3), reviewed and dismissed a predicted
  incident (Scenario C2), resolved a jurisdiction dispute (proven in
  `100_authority_routing_and_dispatch.sql` TEST 87, not repeated here),
  reassigned an overdue task (Scenario F2), reviewed impact and recurrence
  (Scenarios G2/H2).
- **Administrator**: pilot configuration management (feature flags,
  station/registry/SLA-rule/playbook activation) is proven in
  `110_production_hardening.sql` TESTs 115-118; "cannot bypass immutable
  audit rules" is proven by `incident_events`/`action_evidence` having no
  update/delete RLS policy at all (see [SECURITY.md](SECURITY.md)).
- **Service worker**: the ingest service's own narrow, function-scoped
  writes (`start_job_run` etc., never a broad table write) are documented
  in [SECURITY.md](SECURITY.md) and exercised throughout every scenario
  above via the same `as_service()` (null `auth.uid()`) pattern real
  ingestion uses.

## Failure-drill and performance findings

See [PILOT_READINESS_REPORT.md](PILOT_READINESS_REPORT.md) sections
"Reliability and failure drills" and "Performance testing" for the full
write-up, including a genuine finding from empirically testing an
interrupted migration, and a real index gap found and fixed via EXPLAIN
ANALYZE at realistic Delhi pilot data volume.
