# Vayu Gati — Role Workflows

Describes what each role can do **today** (post Phase 1 shell), and what the
product plan requires next (Phase 3). Kept factual — no screen described here
that doesn't exist is claimed to exist.

## Today (implemented)

### Citizen (`/citizen`)

1. See current AQI + PM2.5/PM10 + weather for their home ward, and a 48h
   forecast chart.
2. Report a pollution source: free-text description, optional GPS, optional
   photo. Submission is classified asynchronously by Claude
   (`source_category` + a Hindi advisory), with an explicit "unavailable" stub
   response when no API key is configured — the report is never blocked on
   classification.
3. Track their own reports through `submitted → verified → assigned/acted →
   resolved/rejected`.

**Gap vs. plan:** no incident visibility, no targeted verification missions,
no "verify claimed action" or recurrence reporting yet (plan §11, §18 Citizen
application). Deferred to Phase 3/5.

### Field officer (`/field`)

1. See their assigned ward's AQI, forecast, and the wind-attribution compass.
2. See a daily roll-up (open/resolved counts, median Gati hours).
3. Work a ranked action queue (reports in their ward, ranked by a client-side
   `priorityScore`: source severity × AI confidence × report age × forecast
   local excess) and advance each report one status at a time.

**Gap vs. plan:** no distinct verification-vs-action task types, no
evidence/checklist capture beyond the existing photo, no offline draft/sync,
no GPS/voice-note capture, no "action completed" vs. "impact verified"
separation in the UI (the *schema* for that split — `action_evidence` +
`impact_evaluations` — now exists after this migration; the field UI does not
write to it yet). Deferred to Phase 3.

### Commander / Admin (`/command`)

1. City-wide Gati metric (median signal→resolved hours).
2. Predictive-GRAP-style alerts: wards forecast to cross the severe PM2.5
   threshold within 36h.
3. Team allocation across wards, weighted by forecast local excess
   (largest-remainder apportionment).
4. Hotspot table (current AQI, forecast peak, dominant source, data age) and a
   MapLibre map with AQI-coloured markers.

**Gap vs. plan:** this is a dashboard, not the Outlook-style list-detail-
action incident queue the plan requires as the *primary* command surface
(plan §18-19: "the map supports decisions but does not replace the incident
queue"). No incident approval/assignment/SLA/escalation UI exists yet.
Deferred to Phase 3.

### Admin

`admin` is currently a superuser role allowed on all three views, not a
distinct "senior administrator" analytics surface (plan §4). No dedicated
admin metrics view (response times, agency performance, cost-effectiveness)
exists yet. Role/ward assignment is manual SQL today (documented in
`README.md`) — there is no in-app user-management screen.

## Shared shell (new this pass)

All three authenticated roles now render inside one `AppShell`
(top bar + left icon rail + responsive main workspace — see
[DESIGN_SYSTEM.md](DESIGN_SYSTEM.md)). The icon rail always shows the full
target navigation set (Overview, Incidents, Map, Tasks, Citizens, Sensors,
Analytics, Settings) so the information architecture is visible from day one,
but only destinations that are actually built are clickable — everything else
is disabled with a tooltip naming the phase it arrives in. This is a
deliberate application of the "do not fake integrations" rule to navigation:
a nav item that goes nowhere real is worse than one that's honestly marked
"coming soon."

| Rail item | State today | Route |
|---|---|---|
| Overview | **Active** | role home (`/citizen`, `/field`, or `/command`) |
| Incidents | **Active** for `commander`/`admin` (Phase 3) | `/incidents` |
| Tasks | **Active** for `field_officer`/`admin` (Phase 3) | `/missions` |
| Map | Disabled — embedded in Overview today | — |
| Citizens | Disabled — "Phase 3/5" | — |
| Sensors | Disabled — "Phase 4" | — |
| Analytics | Disabled — "Phase 6" | — |
| Settings | Disabled — "Phase 4/5" | — |

## Phase 3 (built — incident workflow vertical slice)

The existing citizen/field/command surfaces above still work unchanged. Phase 3
adds the incident workflow *alongside* them.

### Citizen — what changed

1. Submitting a report now: saves the report → waits (bounded, 8s) for
   classification, because the matching rule reads `ai_category` → runs the
   match-or-create rule. A failure to link is reported separately from a failed
   submission: the report is already saved and can be linked later, so it must
   not read as "your report was lost".
2. Each report shows **the incident it joined**, in plain language, with a
   public status timeline and the authority handling it.
3. **Targeted verification**: a request appears only when the safety rule allows
   it. Citizens are never asked to approach a fire or an industrial site
   (`HAZARDOUS_FOR_CITIZENS`), or to go outside when the air is severe — those
   render as an explanation of why we are *not* asking, not a disabled button.
   A citizen's answer is supporting evidence only: it can never officially
   verify a source or unlock enforcement.

Sensitive information is withheld structurally, not by UI discipline: citizens
have no read on `evidence_missions`, hypotheses or actions at all, and only see
`incident_events` marked `is_public`.

### Field officer — what changed

`/missions` (rail: Tasks). Assigned evidence missions, each showing *why* the
evidence is needed (plan §10). Opening one gives a **short, source-specific
checklist** (≤5 items — the app is used one-handed, outdoors), geotagged photo
capture via the existing `report-photos` bucket, and an explicit outcome:

- **confirmed** → the officer is an authorised officer, so this makes the source
  `officially_verified` and routes the incident;
- **rejected** → sends the hypothesis back to `suspected` and the incident to
  `under_review`. It does **not** close the incident: the pollution may be real
  with a different cause;
- **unresolved** → changes nothing. An inconclusive visit is not evidence either
  way.

A photo without a GPS fix is accepted but flagged as weaker evidence rather than
silently saved as equivalent.

**Not built:** offline drafts. The form is online-only and says so.

### Command — what changed

`/incidents` (rail: Incidents), added **alongside** the `/command` dashboard,
which is untouched. Outlook-style list → detail → action:

- **Secondary nav**: Active, Predicted, Verification, Assigned, Escalated,
  Closed. Two honest caveats stated in the UI: *Predicted* is always empty
  (nothing creates forecast-detected incidents until Phase 4's detection
  service), and *Escalated* is an age rule (open >24h, nothing dispatched), not
  real SLA tracking — Phase 5.
- **List**: severity, evidence level, ward, age; worst-first then oldest.
- **Detail**: location, pollutant, local excess, severity, evidence level,
  probable source + confidence, assigned authority, status, and which task kinds
  the evidence level permits.
- **Evidence workspace**: linked reports (with distance from the incident
  centre), monitoring evidence, source hypotheses, supporting **and
  contradictory** evidence, evidence quality, and the full timeline with
  internal entries marked.
- **Action panel**: request the next best evidence (rationale mandatory; an
  assignee is mandatory, because an unassigned mission reaches nobody), route to
  an authority, close. Routing is blocked on a `suspected` incident and the UI
  explains why rather than hiding the control.

### Rules, and where they live

The evidence-level rules are enforced in the **database**
(`enforce_incident_action_rules`), so they hold whichever client writes.
`web/src/lib/incidentRules.ts` mirrors them as pure functions so the UI can
explain and pre-empt the rule — and so they are unit tested (31 tests) rather
than only exercised by clicking. The matching rule lives only in SQL (it must be
atomic to prevent duplicates); its parameters are passed explicitly from the
client so the values the UI explains and the DB applies cannot drift.

## Phase 4 (built — intervention and verified mitigation)

The Phase 3 surfaces above are unchanged; Phase 4 adds the intervention and
impact workflow on top of them, closing the "next slice" Phase 3 called out.

### Command — what changed

`/incidents` gains a new **Intervention** panel (`InterventionPanel.tsx`),
between the incident header and the source-evidence panel:

- **Create an intervention** — only offered when the evidence level allows it
  (the same `taskBlockedReason` gate Phase 3 used for routing); the DB trigger
  is the real enforcement, this is the explanation. Records recommended action,
  responsible authority, deadline, expected verification window, and —
  immediately, for enforcement types — whether command approval is required.
- **Approve / assign / advance** — an enforcement-sensitive intervention shows
  "Needs approval" until a named commander approves it; a drafted/approved
  intervention is assigned to a field officer from the same
  `list_assignable_officers` pool Phase 3 built for evidence missions; each
  advance moves exactly one step along the operational lifecycle
  (`nextOperationalStatus`) — there is no control that can skip straight to an
  outcome state, because outcome states are never offered as a workflow step at
  all, only ever produced by recording an impact evaluation.
- **Record impact evaluation** — a before/after form (before/after readings,
  observation window, station, data completeness, notes) with a **live preview**
  of what the database will compute (`previewImpactOutcome`, kept in lockstep
  with the SQL rule) — shown so the operator isn't surprised, never presented as
  the source of truth.
- **Impact result** — every recorded evaluation, with its outcome, % change,
  completeness, station, and the fixed "not weather-adjusted, not causal proof"
  limitation string on every row.
- **Citizen verification** — the citizen's action-outcome answers, decoded from
  `incident_evidence` (they arrive as `citizen_action_answer` in the payload),
  shown with the same "supports, does not prove" framing used everywhere else
  citizen evidence appears.
- **Reopen / close**, in the incident header — close is blocked by the database
  (not just the UI) when a completed action has no impact evaluation; reopen
  (shown once closed) asks for a reason and returns the incident to
  `evidence_gathering`.

### Field officer — what changed

`/missions` gains an **"Interventions assigned to me"** card above the existing
evidence-mission card — a distinct task type ("go do something", vs. a mission's
"find out what's happening"), so it is not mixed into one undifferentiated list.
Opening one gives: start/completion time capture, a source-confirmed/not-confirmed
toggle, a free-text "action performed" field, the same short per-source checklist
missions use, **multiple** geotagged photographs (the brief's plural, vs.
mission's single proof photo), and a "could not be completed" path that requires
a reason before it can be submitted. Submitting writes one `action_evidence` row
per proof item (GPS, checklist, each photo, start/end timestamps) rather than one
blob, so each is independently auditable.

The form never offers an outcome — only `completed` or (if not completed)
`in_progress` with a reason. Turning "completed" into "effective" is exclusively
a command action, later, backed by a real reading.

### Citizen — what changed

Each linked incident (`CitizenIncidentCard`) gains a small action-verification
prompt (`CitizenActionVerificationCard`) once the public status suggests
something has actually been done (`action_dispatched` / `in_progress` /
`verifying` — never shown before there is anything to confirm, never after
`closed`, per the same safety gate Phase 3 built for source verification). Five
answers: completed, partial, not completed, problem remains, problem returned.
Recorded as supporting evidence only — the RPC that handles it
(`submit_citizen_action_verification`) is structurally incapable of setting an
outcome or reopening anything; that is a command decision.

**Known gap, stated rather than hidden**: because the safety gate refuses once
an incident is `closed`, a citizen cannot report recurrence *after* formal
closure through this control today — only while the incident is still open and
being verified. Reporting recurrence into an already-closed incident is command-
only (the "Reopen" button) for now; extending the citizen path to a closed
incident is listed as follow-up work below rather than assumed to already work.

### Rules, and where they live

The operational/outcome split, the "no outcome without an evaluation" rule, and
the closure guard are all enforced in the **database**
(`enforce_incident_action_rules`, `enforce_incident_closure_rules`), exactly
like Phase 3's evidence-level gate — so they hold regardless of which client
writes. `web/src/lib/incidentRules.ts` mirrors the lifecycle ordering and a
preview of the before/after computation as pure, unit-tested functions
(16 new tests) so the UI can explain and pre-empt a rule instead of surfacing a
raw Postgres error.

## Phase 5 (built — intervention playbooks)

The Phase 3/4 surfaces above are unchanged in shape; Phase 5 replaces Phase
4's free-text intervention creation with structured, source-specific
templates, and closes the "no intervention playbooks" limitation Phase 4
called out.

### Command — what changed

The Intervention panel's "+ New intervention" button now opens a **playbook
picker** first, instead of the free-text form directly:

- **Ranked, eligible playbooks only** — filtered by the incident's city,
  evidence level, source category, and local-vs-regional classification
  (`isPlaybookEligible`), then scored on source match, evidence-level fit,
  urgency-vs-deployment-time, cost, and resource availability
  (`rankPlaybooks`) — five stated factors, no ML. Each candidate shows *why*
  it's recommended, in plain language generated from the same signals.
- **Cost, time and verification shown up front** — the cost range, deploy
  time, expected time to effect, and verification method, plus the
  evidence-basis label ("literature-based estimate" / "expert estimate — not
  yet locally validated" / "based on this city's own observed results") and
  known limitations, so expected impact is never presented as a guarantee.
- **Usage history alongside each candidate** — times used, and how many of
  those uses were effective/partly effective/ineffective/inconclusive
  (`tallyPlaybookUsage`), read-only: nothing in this phase ever rewrites a
  playbook's own cost/time/effect estimates from observed outcomes.
- **One editable field**: "Operational notes" — a per-incident addendum,
  explicitly labelled as the only thing being customised. The playbook's own
  instructions/checklist are snapshotted, not mutated.
- **A "Use a custom intervention instead" escape hatch** — falls through to
  Phase 4's original free-text `CreateInterventionDialog`, unchanged, for a
  source/city with no matching playbook yet. A commander is never blocked
  from acting just because no template exists.
- Selecting a playbook still respects every Phase 3/4 rule unchanged: the
  evidence-level creation gate, the enforcement-type approval requirement,
  and — new this pass — the playbook's *own* `min_evidence_level`, enforced
  in the database (see [DATA_MODEL.md](DATA_MODEL.md)) so a commander cannot
  bypass it by editing anything short of the incident's actual evidence.

### Field officer — what changed

The intervention completion form (`/missions`) now prefers a **snapshot** of
the originating playbook's checklist (`checklist_snapshot`, taken at
selection time) over the hardcoded per-category checklist, and shows the
playbook's `required_proof`/`verification_method` as informational hints plus
any commander-written operational note. A custom (non-playbook) intervention
falls back to the Phase 3 hardcoded checklist exactly as before. The "could
not be completed" path is unchanged.

### Rules, and where they live

Eligibility and ranking are pure, unit-tested TypeScript
(`web/src/lib/incidentRules.ts`) — read-only and client-side, since nothing
about "which playbooks to show, in what order" needs database atomicity. The
one new **database** rule — an action referencing a playbook must meet that
playbook's `min_evidence_level` — is enforced in the same
`enforce_incident_action_rules` trigger Phase 3/4 already used, extended
again rather than duplicated. See [DATA_MODEL.md](DATA_MODEL.md) for exactly
why this is additive defence-in-depth and not a replacement for the
pre-existing enforcement-type gate (which was never bypassable via playbooks
in the first place — it doesn't consult them).

## Phase 5.1 (built — citizen recurrence reporting and custom-intervention hardening)

Closes the "citizen recurrence reporting" gap called out after Phase 5, and
hardens the custom (no-playbook) intervention fallback so it cannot bypass the
rules a playbook-based intervention already had to follow.

### Citizen — what changed

For a **closed** incident their report is linked to, `CitizenIncidentCard`
now shows a `CitizenRecurrenceCard`:

- **Final outcome** (from `impact_evaluations.outcome`, which RLS already let
  a linked citizen read directly since Phase 4 — only the outcome column
  itself is shown, never the internal `notes`/`method_limitation`) and
  **previous action status**, derived from the public timeline
  (`action_completed`/`action_dispatched`/`task_created` event types) —
  never from `actions` itself, which citizens still cannot read at all.
- **"Report that the problem returned"** — recurrence type (the plan's own
  four options: returned / partially returned / action was temporary /
  unable to confirm), an optional note, optional geolocation, optional
  photo. No internal action, agency, officer, or enforcement detail is ever
  requested or shown.
- After submission: **submitted → under review → more evidence requested →
  confirmed recurrence → linked to reopened incident / linked to a new
  incident → dismissed (public-safe reason)** — `citizenRecurrenceStatusLabel`
  combines the raw `review_status` with a server-computed `outcome_kind` so
  the citizen sees the right label without being handed the raw incident id.
  Submitting again while a report is still pending is a no-op (duplicate
  detection, server-side).

### Command — what changed

A new **Recurrence** queue tab (closed incidents with at least one pending
recurrence report) and, in the incident workspace, a **Recurrence reports**
panel:

- Closure date, previous intervention, previous impact result, and
  time-since-closure at a glance.
- Every recurrence report on the incident, with the citizen's own evidence
  (note/photo/location) and a **recommendation** (`recommendRecurrenceDecision`
  — reopen / new incident / uncertain, with plain-language reasons) shown
  alongside, never applied automatically.
- Six manual review actions per pending report: **dismiss** (public-safe
  reason required) / **request more evidence** / **confirm recurrence** /
  **reopen the original incident** / **create a new linked incident**
  (traced back via `recurrence_of_incident_id`) / **merge with an
  already-open nearby incident** (attaches the citizen's evidence to the
  target incident).

The intervention creation form now requires **"Why no playbook was
suitable"** (`custom_reason`) before a custom intervention can be submitted —
enforced client-side for a fast error and, non-negotiably, in the database.
Every intervention card is now labelled either from-a-playbook or
**Custom intervention**, with the custom reason shown alongside it.

### Field officer — what changed

The `/missions` intervention list now shows the same **Custom intervention**
label next to any action with no `playbook_id`, so a field officer can see at
a glance which of their assigned interventions came from a structured
template and which were a commander's own judgement call. No other change —
the completion form and checklist behaviour are unchanged from Phase 5.

### Rules, and where they live

The reopen-vs-new-incident recommendation is pure, unit-tested TypeScript
(`recommendRecurrenceDecision` in `incidentRules.ts`) — three stated,
documented thresholds (soon-after-closure / substantial-gap /
same-location-radius), never applied automatically; every actual disposition
is a separate, explicit, command-only function in `incidents.ts`. The
custom-intervention hardening rules (commander-only creation, mandatory
reason, evidence-level and regional-classification compatibility,
post-approval immutability) are enforced in the same
`enforce_incident_action_rules` database trigger every prior phase already
used, extended again rather than duplicated — see
[DATA_MODEL.md](DATA_MODEL.md) for the verified gap this closes in the
baseline `actions_write` RLS policy.

## Phase 6 (built — automated pollution anomaly detection and predicted incidents)

Closes the "no automated pollution anomaly detection" gap called out after
Phase 5.1. Nothing about the Phase 3-5.1 surfaces changes shape — a
Phase-6-created incident is worked through the exact same evidence/
intervention/impact/recurrence workflow as any other incident; the only new
things are how it gets CREATED and one new command review surface for it.

### Command — what changed

- The **Predicted** queue tab (existed since Phase 3, always empty until
  now) populates automatically: any incident where the automated rule
  engine (`evaluate_station_pollutant_anomaly`, re-run on every ingest
  cycle) sees a trend projected to cross a threshold but has not yet
  crossed it.
- The incident workspace gains a new panel (shown only for an incident with
  `detection_stage` set — i.e. one that came from automated detection, not
  a citizen report or manual entry): location, pollutant, current
  concentration, local excess, rate of increase, expected threshold-crossing
  time, data confidence, every triggered detection rule in plain language,
  and nearby monitoring stations.
- Four review actions: **continue monitoring** (logs the decision, changes
  nothing — the engine keeps re-evaluating on its own schedule) /
  **promote to active incident** (`detection_stage → 'confirmed'`, a
  metadata transition only — the incident is already fully workable at any
  stage) / **dismiss as data anomaly** (closes the incident with a
  public-safe reason) / **merge with an existing incident** (closes this
  one, attaches its sensor evidence to the target, traceable both ways via
  `merged_into_incident_id`). "Request evidence" is **not** a new button —
  the existing evidence-mission "Request evidence" button in the incident
  header already works on a predicted incident unchanged.
- No automatic enforcement dispatch, ever: a freshly auto-detected incident
  starts at `source_confidence = 'suspected'`, same as any other new
  incident, so the pre-existing Phase 3 evidence-level gate refuses any
  action on it regardless of how it was detected — verified directly
  (`supabase/tests/70_anomaly_detection.sql` test 49).

### Field officer — what changed

Nothing. A Phase-6-created incident reaches the field exactly the way any
other incident does, once command creates an intervention for it — no new
surface, no new field-facing state.

### Citizen — what changed

Nothing new was built, deliberately: a predicted incident is still just an
incident, so the existing Phase 3 "citizen verification request"
(`evidence_missions`, `mission_type = 'citizen_verification'`) already
satisfies "Vayu Gati may generate a safe citizen verification request" with
zero code changes. It already excludes internal source allegations,
enforcement detail, and named facilities — that was true before this phase
and remains true now. Citizens have no read at all on the new
`anomaly_candidates` table or on `incidents.detection_stage`/
`primary_pollutant` (verified, `supabase/tests/70_anomaly_detection.sql`
tests 51a/51b/51d).

### Rules, and where they live

Every threshold/persistence/local-excess/trend-projection/dedup rule lives
in `evaluate_station_pollutant_anomaly` / `run_anomaly_detection` (SQL) —
not duplicated in TypeScript, for the same reason `link_report_to_incident`
doesn't have a client-side twin: it needs to be atomic with the incident
create/update, and it reads a city-configurable threshold table the client
has no business re-deriving. `web/src/lib/incidentRules.ts` only carries
display-only labels/formatting for values the database already computed.
See [DATA_MODEL.md](DATA_MODEL.md) for the full mechanism and
[DATA_QUALITY_AND_SCIENCE.md](DATA_QUALITY_AND_SCIENCE.md) for the
thresholds' scientific basis and honest limitations.

## Phase 7 (built — transparent, rule-based probable-source attribution)

Closes the "no probable-source attribution for an automatically detected
incident" and "responsibility routing is free-text, not the
`responsibility_registry`" gaps called out after Phase 6. The Phase 3–6
surfaces above are unchanged in shape.

### Command — what changed

`/incidents` gains a new **Source attribution** panel
(`SourceAttributionPanel.tsx`), between the predicted-incident panel and the
recurrence/intervention panels:

- **Ranked hypotheses** with a probability bar, confidence-tier badge
  (suspected/corroborated/officially verified), and the fixed disclaimer
  "Probable source — not a confirmed violation." on every result.
- **Supporting, contradictory and missing evidence**, each as plain-language
  lists — an evidence-scored breakdown, not a bare percentage. A
  data-quality warning appears whenever the underlying calculation notes
  gaps (no wind data, no registry match, etc.).
- **Local/regional classification**, with a "(human-confirmed)" tag once a
  commander has taken it over from the model.
- **Probable responsible authority** for the top local hypothesis, with a
  routing-confidence percentage, or an explicit "Not applicable —
  regional" / "Unresolved jurisdiction" state — never a dispatch action.
- **Last calculation time**, and the **recommended next evidence mission**
  when one exists — shown as information pointing at the existing "Request
  evidence" header button (Phase 6's own precedent: not a second button).
- **Four review actions**: confirm as corroborated / mark unresolved / reject
  with a mandatory reason (per hypothesis), plus a panel-level "Request
  recalculation". None of these can set `officially_verified` — that stays
  an authorised field-officer action, unchanged from Phase 3.
- `IncidentEvidencePanel`'s old, simpler "Probable source" list is removed
  — fully superseded by the new panel, not duplicated alongside it.

### Field officer — what changed

Nothing new to build: a recommended evidence mission the attribution engine
proposes reaches a field officer through the exact same `/missions` flow any
other evidence mission already uses — it just has a different
`mission_type`/`rationale`.

### Citizen — what changed

Nothing new to build, deliberately: when the engine's recommendation is
citizen-safe, it is one of the plan's own three exact questions ("Is heavy
road dust visible…" / "Is loose construction material left uncovered…" /
"Is visible smoke present…"), delivered through the existing Phase 3
`citizen_verification` mission and its existing `HAZARDOUS_FOR_CITIZENS`
safety gate, unchanged. A citizen still has zero read on
`incident_source_hypotheses` or `responsibility_registry`, directly or via
`get_incident_responsible_authority` — no named facility, internal agency
note, enforcement strategy, or unverified accusation is ever reachable.

### Rules, and where they live

Every evidence weight, threshold, the ambiguity gap, the never-overwrite-
verified guard, and the classification-update rule live in
`calculate_incident_source_attribution` / `run_incident_source_attribution`
(SQL) — the same reason `evaluate_station_pollutant_anomaly` does not have a
client-side twin. `web/src/lib/incidentRules.ts` carries only display
labels and one pure, unit-tested ambiguity-explanation helper
(`needsMoreAttributionEvidence`), mirroring Phase 6's own
`describeAnomalyDetectionRule` pattern exactly. See
[DATA_MODEL.md](DATA_MODEL.md) for the full mechanism and
[DATA_QUALITY_AND_SCIENCE.md](DATA_QUALITY_AND_SCIENCE.md) for the scoring
weights' scientific basis and honest limitations.

## Phase 8 (built — unified forecasting and scientific validation)

Closes the "no forecast-based (as opposed to sensor-trend-based) anomaly
prediction" gap called out after Phase 7. The Phase 3–7 surfaces above are
unchanged in shape — a forecast-driven predicted incident is worked through
the exact same evidence/intervention/impact/recurrence/attribution workflow
as any other incident.

### Command — what changed

- The **Predicted** incident panel gains a new **Forecast** sub-section
  (shown whenever a `forecast_runs` row exists for the incident's
  ward+pollutant, regardless of which method actually created THIS
  incident): the forecast curve with a shaded uncertainty band, the
  predicted peak, **method used** (machine-learning model vs. seasonal/
  hourly baseline), **fallback status** in plain language, **model
  accuracy by horizon** (a compact MAE-vs-persistence readout per 6/12/24/
  48h checkpoint, greyed out beyond whatever horizon was actually
  validated), a data-quality warning when the run isn't `ok`, and the
  fixed, literal **"Forecast — not a guaranteed outcome."** disclaimer.
- The panel's existing "Prediction method" field (already present since
  Phase 6, now meaningfully populated) shows whether THIS SPECIFIC
  predicted incident came from the validated forecast or the raw-reading
  trend fallback — never ambiguous, never silently mixed.
- No new review actions — continue monitoring / promote / dismiss / merge
  all work identically regardless of which method produced the prediction.

### Field officer — what changed

Nothing — a forecast-driven incident reaches the field exactly like any
other incident, once command creates an intervention for it.

### Citizen — what changed

Nothing new to build, deliberately: `ForecastChart.tsx` (the citizen-facing
PM2.5 curve) is explicitly unaffected — `fetchForecast`/`fetchAllForecasts`
now filter to `pollutant = 'pm25'` so the citizen dashboard keeps showing
exactly what it always has, byte-for-byte, even though the underlying
`forecasts` table now also holds pm10/no2 rows for command's use.

### Rules, and where they live

The forecasting model itself (LightGBM training, the time-based holdout,
every metric) lives entirely in `ingest/app/forecast.py` — it cannot live
in SQL (Postgres cannot train a model) or in `incidentRules.ts` (no I/O,
and re-deriving a model's own validation client-side would be exactly the
"second, potentially-inconsistent" computation this codebase avoids
everywhere else). The CONNECTION point — deciding whether a predicted
incident may use the validated forecast or must fall back to the raw-
reading trend — lives in `evaluate_station_pollutant_anomaly` (SQL,
`create or replace`d a second time), the same function Phase 6 built,
extended rather than duplicated. `incidentRules.ts` carries only display
labels and two pure, unit-tested helpers (`isHorizonValidated`,
`forecastFallbackStatus`). See [DATA_MODEL.md](DATA_MODEL.md) for the full
mechanism and [DATA_QUALITY_AND_SCIENCE.md](DATA_QUALITY_AND_SCIENCE.md)
for the validation methodology, model inputs, and honest limitations.

## Phase 9 (built — authority routing and operational dispatch)

Turns an approved intervention into a correctly routed, trackable,
escalatable operational task. Sits ON TOP of Phase 4's own operational
workflow (`actions.workflow_status`), never replacing it — see
DATA_MODEL.md's "Phase 9" section for the full `task_dispatches`/
`sla_rules`/`notifications` mechanism.

### Command — what changed

- New **Operations** section on the incident detail view
  (`TaskDispatchPanel.tsx`), one row per intervention: routed authority,
  routing confidence (confirmed/probable/disputed/unresolved), assigned
  officer/team, lifecycle status, an SLA countdown, escalation level,
  delivery status per notification channel, and any rejection/reroute/
  escalation reason on file.
- Actions: **preview & dispatch** (unresolved routing is shown plainly and
  never auto-advances), **approve & dispatch** for an enforcement-sensitive
  or equipment-deployment action still `awaiting_approval`, **resolve
  jurisdiction dispute** (pick the correct unit from the active
  responsibility registry, with a required reason), **escalate**,
  **cancel**, and a manual **"check for overdue tasks"** trigger (the same
  SLA/escalation batch driver the ingest cron runs every 5 minutes).

### Field officer — what changed

- New **My dispatched tasks** card on the missions screen
  (`FieldTaskDispatchCard.tsx`), separate from the existing intervention
  card on purpose — dispatch lifecycle (acknowledge/accept/reject) is a
  distinct concept from evidence/outcome capture, which stays exactly where
  it was.
- Actions: **acknowledge**, **accept** or **reject with a reason**, **start
  work** (this also marks arrival — see DATA_MODEL.md's note on why there's
  no separate arrival status), **report resource unavailable** (never
  invents availability), **request a reroute** (a request only — command
  still decides and actually reroutes).
- Once marked complete, the existing `InterventionCompletionForm` is still
  where the checklist/photo/GPS evidence is actually captured — Phase 9
  does not duplicate or replace that.

### Citizen — what changed

Nothing new to build, deliberately: `dispatch_intervention_task`/
`transition_task_dispatch` write the same `incident_events.is_public`
rows every earlier phase already renders via `IncidentTimeline.tsx` (a few
new event-type labels were added there for readability). A citizen already
sees "Dispatched", "Acknowledged", "Accepted", "In progress", "Completed"
on their existing timeline with no new query, RPC, or RLS surface —
internal routing detail, officer identity, rejection/reroute reasons, and
disputed-jurisdiction detail stay `is_public = false` and are never sent to
the client at all.

### Rules, and where they live

Every routing/lifecycle/approval/SLA/escalation rule lives in
`supabase/migrations/20260724000000_authority_routing_and_dispatch.sql` —
`dispatch_intervention_task`, `transition_task_dispatch`,
`escalate_stale_task_dispatches`, and friends are the ONLY way a dispatch
is ever created or changes status (no authenticated write policy exists on
`task_dispatches`/`notifications` at all — verified by test 98c actually
attempting a direct update and observing 0 rows affected).
`incidentRules.ts` carries only display labels and pure UI helpers
(`canTransitionTaskDispatch`, `taskDispatchRequiresReason`,
`publicTaskStatusLabel`, `slaCountdownLabel`, ...) that mirror the SQL's own
transition table for the sole purpose of greying out an illegal button
before a user tries it — the database remains the actual authority.
Notification delivery is a genuinely new Python module,
`ingest/app/notifications.py`: an in-app "adapter" is a no-op (the row
itself, RLS-scoped, is the delivery), a real SMTP email adapter is used
when `SMTP_HOST` is configured, otherwise an honest development-mock
adapter that logs "would send" and records why it didn't — SMS/WhatsApp
have an adapter INTERFACE only, always an explicit "no provider configured"
failure, never a fabricated delivery. `ingest/app/dispatch.py` is a thin
wrapper calling `escalate_stale_task_dispatches` on a 5-minute schedule
(`ingest/app/main.py`'s `run_ops`), separate from the hourly `run_intel`
cycle since an SLA clock can't wait an hour.

## Phase 10 (built — hosted deployment prep, security, reliability and production hardening)

Not a new domain workflow — this phase hardens what Phases 2-9 already
built rather than adding a new incident-lifecycle concept. The one new
user-facing surface is command/admin-only.

### Command — what changed

- New **`/ops`** screen (Settings in the icon rail): System Health (every
  scheduled job's last run, staleness flagged) and a minimal pilot admin
  surface — per-city feature-flag toggles, station/responsibility-registry/
  SLA-rule/playbook activation toggles. Deliberately narrow, not a general
  database editor — deeper edits stay direct SQL.
- Two real RPC bugs fixed that could otherwise have silently corrupted a
  dispatch's lifecycle or fired a duplicate notification on a retried
  action — see [SECURITY.md](SECURITY.md) for the writeup; no command-
  facing behaviour changes as a result, since these were bugs in an edge
  case (retrying an already-progressed dispatch), not the normal flow.

### Field officer — what changed

Nothing new to build — the frontend hardening in this phase (error
boundary, citizen-safe error messages) is command/citizen-facing; field
surfaces were already reasonably defensive.

### Citizen — what changed

Citizen-facing error messages no longer show a raw database error string —
every citizen component now shows a fixed, friendly message on failure
(the real error is still logged to the browser console in dev builds for
debugging). Nothing else changes; every existing citizen-visible state and
RLS boundary is untouched.

### Rules, and where they live

Job reliability (`job_runs`' structural single-run guard), system health
(`system_health_summary()`), and feature flags
(`city_feature_enabled(...)`) all live in SQL, following the same
discipline as every earlier phase. `ingest/app/logging_utils.py`'s
`run_tracked(...)` wraps every scheduled Python job with this tracking plus
structured logging — a function wrapper, not a context manager, because a
`with` block's body always executes regardless of what's yielded, and
"skip this job, another run holds the lock" genuinely needs to skip
calling the job function at all. See [DATA_MODEL.md](DATA_MODEL.md)'s
Phase 10 section for the full mechanism, [SECURITY.md](SECURITY.md) for
the security review, and [MONITORING.md](MONITORING.md) for the
observability design.

## Phase 11 (validated — Delhi pilot validation, historical replay, end-to-end scenario testing and pilot readiness sign-off)

Not a new workflow — every role's existing workflow (citizen, field
officer, command, administrator, service worker) was exercised through a
real, continuous, multi-step chain rather than isolated unit tests, using
new deterministic scenarios A-J
(`supabase/tests/130_end_to_end_scenarios.sql`). Full detail in
[END_TO_END_TEST_REPORT.md](END_TO_END_TEST_REPORT.md)'s "Role-based UAT"
section.

- **Citizen**: reported, saw the safe public closed status, submitted a
  recurrence report — all as a real logged-in citizen role, never
  superuser. Confirmed (again, this phase) cannot read internal
  attribution/routing/officer data.
- **Field officer**: acknowledged, accepted, worked, submitted evidence,
  reported resource unavailability. Confirmed only sees their own
  assigned tasks and cannot alter a command decision.
- **Command**: approved, dismissed a predicted incident, resolved a
  jurisdiction dispute, reassigned an overdue task, reviewed impact and
  recurrence.
- **Administrator**: pilot configuration management (feature flags,
  station/registry/SLA-rule/playbook activation) reconfirmed; cannot
  bypass the immutable audit rules (`incident_events`/`action_evidence`
  have no update/delete RLS policy at all).
- **Service worker**: the ingest service's own narrow, function-scoped
  writes exercised throughout every scenario via the same `as_service()`
  pattern real ingestion uses — never a broad table write.

**A real, concrete gap found this phase, affecting every role above**:
zero `field_officer` accounts exist anywhere in this project's data, and
0 of 4 `responsibility_registry` rows are verified or contact-complete.
The mechanism works end to end; the real Delhi operational data behind it
does not exist yet. See
[DELHI_DATA_GAP_REPORT.md](DELHI_DATA_GAP_REPORT.md).

**Structural, not human, acceptance**: every check above confirms the
CODE does the right thing — no real human operator has walked
`PILOT_RUNBOOK.md` end to end in an actual browser session yet. See
[OPERATOR_ACCEPTANCE_CHECKLIST.md](OPERATOR_ACCEPTANCE_CHECKLIST.md) for
the honest distinction.

## Still missing after Phase 10

- Offline field drafts; voice notes.
- **No UI to create or edit a playbook's template fields** — the picker
  only *selects* from existing rows, and `/ops` only toggles
  `is_active`; adding a new playbook or editing its checklist/cost/
  duration fields is still direct SQL.
- **Playbook usage metrics are ward-scoped for a field officer, unscoped for
  command** — same RLS-driven pattern as every other `actions` query in this
  codebase (`listInterventionsForOfficer`), not a new limitation, just
  inherited here too.
- **No credentialed SMS/WhatsApp provider** — the adapter interface exists
  (`ingest/app/notifications.py`) but always reports an honest "not
  configured" failure; wiring a real provider needs credentials this repo
  does not have.
- **No route optimisation or live GPS tracking** — explicitly out of scope
  for Phase 9 per its own brief; "distance/zone compatibility" is a plain
  ward match, not a real routing calculation.
- **Resource availability defaults to "unknown"** until an officer
  explicitly reports otherwise — there is no shift/roster/equipment system
  to check against, so Phase 9 never invents an answer (plan's own explicit
  requirement).
- **No city-level RLS scoping for command roles** — a commander/admin
  currently has implicit access to every city's data; fine for a single-
  city pilot, a real gap the moment a second city's data enters the same
  project. See [SECURITY.md](SECURITY.md).
- **Migrations have never been applied to the hosted Supabase project** —
  see [DEPLOYMENT.md](DEPLOYMENT.md). This is the single biggest remaining
  step before any real pilot traffic.
- **No real backup verified** — [BACKUP_AND_RECOVERY.md](BACKUP_AND_RECOVERY.md)
  states what to check, not that it has been checked.
- **Resolved as of Phase 11**: Delhi pilot validation against real
  historical data and a formal pilot readiness sign-off are now done —
  see [PILOT_READINESS_REPORT.md](PILOT_READINESS_REPORT.md) (final
  decision: CONDITIONALLY PILOT READY). What remains is closing the
  concrete conditions that report lists (hosted migration, real
  `responsibility_registry` data, real field-officer accounts), not
  further validation work.
- Weather-adjusted or causal impact analysis — deliberately out of scope;
  every evaluation says so on its face (`method_limitation`).
- The "merge with a nearby open incident" command action (Phase 5.1's
  recurrence-merge and Phase 6's predicted-incident-merge) requires the
  commander to already know the target incident's id — there is no
  map-based "nearby open incidents" picker yet.
- **`responsibility_registry` is ward-or-city scoped only, never per-asset**
  — no road/construction-site/factory has its own coordinates anywhere in
  this schema, so GIS proximity and wind alignment in the attribution engine
  are both coarse, ward-level checks, not a metric distance or a true
  bearing calculation. `gis_proximity_radius_m`/`wind_alignment_tolerance_deg`
  are seeded as reserved, not-yet-applied placeholders for that future model.
- **The two attribution mechanisms (`attribution.py`'s wind-rose and
  `calculate_incident_source_attribution`'s per-incident scoring) are not
  reconciled with each other** — the incident engine reads the wind rose's
  `direction` only as a presence/absence check, not its magnitude or
  confidence.
- Analyst surface, senior admin metrics, second-city configuration (though
  the playbook model itself is already city-parametric — see DATA_MODEL.md's
  "city-specific and reusable design" note).
- In-app role/ward management (still manual SQL), which is why a commander can
  only dispatch to officers already assigned to a ward.
