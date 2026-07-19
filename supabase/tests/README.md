# Database + RLS tests

```bash
./supabase/tests/run.sh     # needs docker; touches nothing hosted
```

## Why these exist

RLS is the only authorization boundary in this product — the web app only ever
holds the anon key, so if a policy is wrong, data leaks. A policy you have only
*read* is a policy you have not tested, so every assertion here is executed
against a real Postgres as the `authenticated` role.

That detail matters: **a superuser bypasses RLS**, so a suite that forgets
`set role authenticated` passes vacuously while proving nothing. `auth.uid()` /
`auth.role()` are stubbed to read `request.jwt.claims` exactly as Supabase
defines them, so `set request.jwt.claims = '{"sub":"…","role":"authenticated"}'`
is a faithful stand-in for a logged-in user.

Two bugs found this way during Phase 3, neither visible by reading the SQL:

- a citizen updating `reports.incident_id` silently affected **0 rows** (no
  error) — which is why linking goes through a security-definer function;
- a citizen assignee could read `evidence_missions.rationale`, an internal note
  that may name enforcement intent, even though no screen renders it.

## Layout

| File | Purpose |
|---|---|
| `00_local_supabase_stub.sql` | Local-only stubs for the bits of Supabase the migrations depend on (`auth.users`, `auth.uid()`, `auth.role()`, `storage.*`, the `anon`/`authenticated`/`service_role` roles). **Never shipped** — Supabase provides these. |
| `05_grants.sql` | Table grants Supabase applies automatically; the stub must do it by hand, after the migrations run. |
| `10_report_to_incident.sql` | The match-or-create rule: dedupe, radius, recency, category, independent corroboration, idempotency. |
| `20_evidence_and_privacy.sql` | Authorisation on linking, the suspected/corroborated/verified task rules, and citizen timeline privacy. |
| `30_mission_rls.sql` | The evidence-mission loop: who can create, see, and answer a mission. |
| `40_intervention_and_impact.sql` | Intervention creation gated by evidence level, the operational/outcome workflow split, the before/after impact rule, the closure guard, reopen, and citizen action verification. |
| `50_intervention_playbooks.sql` | Seeded playbook content, the playbook-tier evidence-level gate (isolated from the pre-existing enforcement-type gate), `playbook_id`/`playbook_version`/`checklist_snapshot` storage and stability under a live playbook edit, usage-metric source data, and playbook RLS (citizens denied entirely). |
| `60_recurrence_and_custom_hardening.sql` | Citizen recurrence reporting (submit, closed-only, ownership, no auto-reopen/enforcement, duplicate detection, RLS scoping) and custom intervention hardening (commander-only creation — closes a real gap in the baseline `actions_write` policy — mandatory reason, evidence-level/regional-classification compatibility, named-approver enforcement, post-approval immutability, and the guaranteed audit trigger). |
| `70_anomaly_detection.sql` | Automated pollution anomaly detection: never fires from one isolated reading, persistence/local-excess/trend-projection rules, the data-quality gate (staleness, completeness), regulatory-vs-indicative sensor confidence, deduplication (a second firing updates rather than duplicates), city-configurable thresholds, predicted incidents never create enforcement actions, RLS (citizens excluded, field officers ward-scoped), authorization (commander/admin or an unauthenticated service context only), and the command review actions (promote/dismiss/merge). |
| `80_source_attribution.sql` | Probable-source attribution: proximity/one citizen report never proving a source alone, two independent reporters adding real corroboration, PM10-heavy/NO2-CO/regional-transport signature ranking, contradictory evidence reducing confidence, poor data quality producing `unresolved`, a verified human finding never overwritten by recalculation, top-two ambiguity generating an evidence-mission recommendation, regional incidents never getting local responsibility routing, citizen RLS exclusion, idempotency, and authorization. |
| `90_unified_forecasting.sql` | `forecast_runs`/`forecasts` schema and RLS (broadly readable, service_role-write-only), multiple pollutants coexisting in `forecasts` without cross-contamination, a validated forecast crossing threshold driving a predicted incident, falling back to the raw-reading trend when no forecast exists, an unvalidated (fails-beats-persistence) or stale forecast never being trusted, a validated forecast that never crosses producing no candidate at all (never silently falling back to trend), forecast-driven predicted incidents still unable to create enforcement actions, and duplicate predicted incidents still not created across repeated validated-forecast firings. The forecasting MODEL itself is tested separately — see `ingest/tests/test_forecast.py`, against a fixed synthetic dataset (Postgres cannot train a model). |
| `100_authority_routing_and_dispatch.sql` | Authority routing and operational dispatch: a specific active registry match routes with `confirmed` confidence, an unresolved match never silently dispatches (stays `drafted`), a disputed match holds at `awaiting_approval` for command review and is resolvable with a recorded reason, server-side-enforced lifecycle transitions (illegal jumps rejected, `rejected`/`rerouted`/`cancelled` require a reason, `actions.workflow_status` kept in sync for shared states), duplicate dispatch calls collapse into one row (idempotent create-or-update), enforcement-sensitive actions are held until approved, SLA due timestamps come from the most specific matching `sla_rules` row, overdue tasks auto-escalate and a task completed with zero attached evidence escalates immediately, every routing/lifecycle step writes an immutable `incident_events` row, field officers can report resource unavailability and request (but not force) a reroute, notifications are queued per-channel with a retryable schema, citizens read zero rows of `task_dispatches`/`notifications` and cannot call any dispatch function, field officers only see tasks in their own ward, and no authenticated role — not even a commander — can write `task_dispatches` directly (every write goes through a SECURITY DEFINER function). |
| `110_production_hardening.sql` | Production hardening: `dispatch_intervention_task` is replay-safe (a repeat call on a task that's already progressed past routing never regresses status or re-sends a notification), `completed -> escalated` is a consistently-legal transition (matches what the escalation batch driver actually does), oversized free-text reasons are refused, `report-photos` storage has no update/delete policy (evidence is append-only), `job_runs` structurally prevents two overlapping runs of the same job+city, citizens/officers cannot read `job_runs` directly while `system_health_summary()` gives command a working rollup, feature flags actually gate `dispatch_intervention_task` and default to enabled for an unconfigured city, and an automated (not hardcoded-list) introspection check that every SECURITY DEFINER function in the schema pins `search_path`. |
| `120_pilot_validation_scenarios.sql` | Phase 11 source-attribution scenarios not already covered by `80_source_attribution.sql`: elevated PM2.5+CO ranks `open_burning`, elevated SO2+NO2 ranks `industrial`, genuinely mixed/ambiguous evidence produces no false single-winner certainty, and responsibility mapping degrades to an honest note (never a guess) when no registry row matches a resolved category. All scenarios are explicitly labelled synthetic. |
| `130_end_to_end_scenarios.sql` | Phase 11 end-to-end pilot scenarios (A-J from the pilot-validation brief): each proves a COMPLETE chain of transitions connects correctly stage to stage (citizen report → incident → playbook → approval → dispatch → field evidence → impact → citizen outcome; sensor detection → attribution → routing → dispatch → completion; validated-forecast prediction → command review; regional multi-station pattern → no false local incident; unresolved jurisdiction → blocked dispatch → command resolution; SLA breach → escalation → reassignment; ineffective action → reopen; recurrence → reopen; stale data → suppression; repeated RPC/worker calls → no duplicate incident/dispatch/notification) — it does not re-verify each mechanism's own edge cases, which are already covered by their own phase's test file. |
| `run.sh` | Rebuilds the schema from `schema.sql` + every migration, checks idempotency by re-applying, then runs the above. |

`run.sh` reuses a running `vg-pg` container if there is one; `docker rm -f vg-pg`
forces a clean start. Override with `VG_TEST_CONTAINER` / `VG_TEST_PORT`.

## Limits

- This is a **local stand-in**, not the hosted database. It proves the migrations
  apply, are idempotent, and that the policies behave as intended — it does not
  prove anything about the hosted project's current state, which may have drifted
  if changes were ever applied outside `migrations/`.
- The stub's `auth`/`storage` schemas model only what these migrations touch.
- Storage-bucket policies are not exercised (no Storage engine here).
