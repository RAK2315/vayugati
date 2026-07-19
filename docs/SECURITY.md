# Security

Last updated: 2026-07-25 (Phase 11 — re-verified during Delhi pilot
validation; no new schema-level security change this phase).

RLS is the **only** authorization boundary in this application — the web
client only ever holds the anon key. Every claim in this document is backed
by an executable test in `supabase/tests/`, not just a read of the policy
text; a policy you have only read is a policy you have not verified.

## Secrets audit (this pass)

**Found and fixed**: `web/.env.example` was committed with a real project
URL and a real anon key (not placeholders), violating the "names only"
convention `ingest/.env.example` already correctly followed. Fixed to empty
placeholders this pass. Anon keys are safe-by-design for browser exposure
(RLS is the real boundary, not key secrecy), so this was not a breach in the
strict sense — but it is bad practice this repo should not repeat, and the
value is already in git history at commit `26e22da`. **Rewriting git
history was deliberately not done unilaterally** — that is a destructive
operation with its own risks (force-push, collaborator disruption) that
should be a deliberate decision by the repo owner, not something to do
silently as a side effect of a hardening pass. If you want it purged from
history, that is a separate, explicit action to take (`git filter-repo` or
BFG, then a coordinated force-push).

**Verified clean**: `ingest/.env.example` (names only, always has been);
`.gitignore` correctly excludes `.env`/`.env.local`/`*.env`; neither real
`.env` file in this working tree is tracked by git; `ingest/render.yaml`
uses `sync: false` for every secret (set manually in the Render dashboard,
never committed); no hardcoded API keys, JWTs, or AWS-shaped credentials
found anywhere in tracked source via `scripts/check_secrets.py` (also wired
into CI — see [DEPLOYMENT.md](DEPLOYMENT.md)).

Also removed this pass: a stray, empty `web/supabase/` directory (an
accidental `supabase init` scaffold with a mismatched `project_id`, never
committed, zero real content) — harmless debris, not a secrets issue, but
worth noting since it could have caused someone to `supabase link` the
wrong project from inside `web/`.

## RLS and SECURITY DEFINER review (this pass)

**SECURITY DEFINER search_path safety**: every `SECURITY DEFINER` function
in this schema pins `search_path = public`, verified two ways — a manual
audit reading every `create or replace function` in every migration, and (as
of this phase) an **automated** regression test (`supabase/tests/
110_production_hardening.sql`, TEST 119) that introspects `pg_proc`/
`pg_namespace` directly rather than checking a hand-maintained name list —
it will catch a future migration that adds an unprotected `SECURITY
DEFINER` function automatically, not just the ones known about today. Zero
violations found.

**Invoker-rights functions are a deliberate pattern, not an oversight**:
trigger functions (`enforce_incident_action_rules`, etc.) and a few
read-only functions (`get_incident_responsible_authority`,
`record_impact_evaluation`, `_resolve_task_routing`, `_send_task_
notification`) are intentionally NOT `security definer` — they rely on the
calling role's own RLS, which is the correct, narrower privilege for
something that should never grant more access than the caller already has.
Each says so in its own comment.

**No direct-table write bypass**: `task_dispatches`, `notifications`,
`forecast_runs`, `anomaly_candidates`, `job_runs` have **zero** authenticated
write policy — every write goes through a `SECURITY DEFINER` function.
Verified by literally attempting a direct `UPDATE` as a logged-in commander
and confirming it affects 0 rows (`supabase/tests/
100_authority_routing_and_dispatch.sql` TEST 98c).

**Audit records cannot be silently modified**: `incident_events` and
`action_evidence` have `select`/`insert` RLS policies only — no `update` or
`delete` policy exists for either table, and Postgres RLS denies a command
entirely when no policy for that command exists (regardless of the
underlying `GRANT`). This was true since Phase 3; not newly added, but
re-verified this pass as part of the systematic review.

**Storage evidence-tamper fix (this pass)**: `report-photos` previously let
an authenticated uploader `UPDATE`/`DELETE` their own object after
submission — unlike every DB-level evidence table (insert-only), a citizen
could silently swap or delete the photo behind an already-submitted
`photo_url` with no audit trail. Fixed by removing both policies; nothing in
this app ever called storage update/delete (verified), so this closes a gap
with zero behavior change.

**City scoping — a known, accepted limitation for a single-city pilot**:
`profiles` has no `city_id` column; `auth_role()`/`auth_ward()` scope by
ward, not city. A commander/admin account currently has implicit access to
**every** city's data in `city_config`, with no RLS boundary between them.
This has not mattered in practice (Delhi is the only city configured), and
is the same "multi-city deployment is out of scope" boundary every phase
since Phase 6 has explicitly declared. **Do not treat this as safe once a
second city's real data exists in the same project** — city-scoped RLS for
command roles is real, non-trivial schema work (a new `profiles.city_id`
column plus new predicates on ~15 tables' existing policies) that should be
its own deliberate phase, not a side effect of this one.

### Role-based access, verified per role

| Role | Verified boundary | Test |
|---|---|---|
| Citizen | Zero read on `task_dispatches`, `notifications`, `incident_source_hypotheses`, `responsibility_registry`, `job_runs`; sees only `is_public=true` `incident_events` | `80_source_attribution.sql` TEST 72, `100_...sql` TEST 98a, `110_...sql` TEST 116 |
| Field officer | Sees only their own assigned `task_dispatches` or their own ward's; cannot read another officer's ward | `100_...sql` TEST 97 |
| Commander/admin | Full read/write via the SECURITY DEFINER functions; **not** city-scoped (see above) | throughout |
| Service worker (ingest) | Uses the service_role key, which bypasses RLS by Supabase's own design — narrow, purpose-built functions (`start_job_run` etc.) are used where practical rather than broad table writes, but the service_role connection itself is inherently broad, matching how every Supabase project's ingest/ETL layer works | `db.py`'s own header comment |

## RPC hardening (this pass)

Two real correctness/replay bugs found and fixed via a systematic review of
every RPC for duplicate-execution risk (plan §7):

1. **`dispatch_intervention_task` was not replay-safe.** It recomputed
   `status` from scratch on every call with no check of the dispatch's
   current state — a retried client call (double-click, automation re-run)
   on an action whose dispatch had already progressed to, say,
   `in_progress` would silently **regress it back to `sent`** and fire a
   **second** notification. Fixed: once a dispatch has progressed past
   `routed`, a repeat call only refreshes the routing/registry snapshot and
   returns — status, timestamps, and notifications are frozen. Verified by
   `110_production_hardening.sql` TEST 111 (progress a dispatch to
   `in_progress`, call `dispatch_intervention_task` again, assert status/
   `sent_at`/notification count are all unchanged).
2. **`completed -> escalated` was inconsistent between the two write
   paths.** `escalate_stale_task_dispatches` performed this transition
   directly, but `transition_task_dispatch`'s own declared transition table
   didn't allow it — meaning the same operation the batch driver does would
   be *rejected* if attempted through the "normal" path. Fixed by declaring
   it legal in both places (TEST 112).
3. **Per-city failure isolation** (a `run_anomaly_detection`/
   `run_incident_source_attribution`/`escalate_stale_task_dispatches` batch
   loop had no per-iteration exception handling — one station's or one
   incident's unhandled exception aborted the ENTIRE multi-city batch,
   silently discarding every other city's results in the same transaction).
   Fixed with a `begin...exception...end` around each iteration, logging via
   `RAISE WARNING` and continuing. Verified by TEST 120 (a deliberately
   corrupted second city's config does not prevent a healthy city's station
   from producing a result in the same unscoped call).

**Input validation / bounded lengths**: `transition_task_dispatch`'s
`p_reason` and a table-level `CHECK` constraint on every `task_dispatches`
reason/note column cap free text at 2000 characters;
`incident_recurrence_reports.note` at 4000. Added via `not valid` +
`validate constraint` so the `ALTER TABLE` itself never blocks concurrent
writers.

**Deduplication already structural, not just checked**: `task_dispatches`'
partial unique index (`one current per action`) and `job_runs`' partial
unique index (`one running per job+city`) make "duplicate dispatch" and
"overlapping job run" impossible at the database level, not just prevented
by application logic that could be bypassed.

**Feature flags as a security-adjacent control**: `dispatch_intervention_
task` refuses outright (not just skips) when `operational_dispatch` is
disabled for a city — verified by `110_...sql` TEST 117. This means a pilot
operator has a genuine kill switch for the one engine capable of routing
enforcement-adjacent work, without a redeploy.

## Threat model notes

- **service_role key compromise** is the single highest-impact credential
  leak in this system (full read/write, bypasses RLS). It lives only in
  `ingest/.env` (gitignored) and the Render dashboard's env vars — never in
  a browser bundle, never in a frontend request.
- **anon key exposure** is expected and safe by design — it is meant to be
  public. RLS is what actually protects data behind it.
- **A compromised commander/admin account** currently has access to every
  city's data (see the city-scoping limitation above) and every SECURITY
  DEFINER function's command-level actions (dispatch, escalate, approve).
  Standard account-security practice (strong passwords, and Supabase Auth's
  own MFA support if enabled) is the mitigation here, not something this
  codebase can enforce in SQL alone.
- **CORS is currently `allow_origins=["*"]`** in `ingest/app/main.py` — flagged
  in-code since Phase 0 as needing tightening to the real deployed frontend
  domain before production use. Still open as of this phase; a concrete
  remaining action item (see [PILOT_RUNBOOK.md](PILOT_RUNBOOK.md)).

## Phase 11 re-verification (Delhi pilot validation)

### Critical finding: profile role/ward self-elevation (found and fixed live on hosted)

Found by manually walking the real, freshly-deployed hosted Vercel
frontend for the first time — not caught by any earlier code review or
RLS test, because every earlier RLS test only ever checked which ROWS a
policy exposed, never which COLUMNS a self-scoped write could change.

`profiles_self_update`/`profiles_insert_self` (`schema.sql`, present
since Phase 0/1, never touched by any later migration) are `using
(id = auth.uid())` / `with check (id = auth.uid())` only — they restrict
which row, not which columns. **Any self-registered citizen could call
the REST API directly and set their own `role` to `admin` or `commander`,
or set their own `ward_id` to anything, on signup or any later update.**
The frontend never offers this, but nothing in RLS stopped a raw HTTP
request from doing it.

**Proven exploitable against the real hosted project**: a disposable test
account was created, signed in as a real citizen, and successfully
PATCHed its own `role` to `admin` (HTTP 200) before the fix was applied.

**Fixed** with `20260727000000_profile_role_immutability.sql` — a
`before insert or update` trigger (`enforce_profile_role_immutability`)
that blocks any self-scoped change to `role` or `ward_id` unless the
caller is the service_role backend (`auth.uid() is null`) or an existing
admin acting on their own row. New signups are additionally forced to
`role = 'citizen'`, `ward_id = null` regardless of what they submit.

**Re-verified live** with the identical disposable-account technique
after the fix: the same self-elevation attempt now returns HTTP 400
("You cannot change your own role."), while an ordinary self-update
(`full_name`) still succeeds — no regression.

One real regression surfaced and was fixed **during construction of the
fix itself**: the trigger's first version blocked `auth.uid() is null`
(service_role) but not "some OTHER authenticated user's stale
`auth.uid()` left over from an earlier `as_user()` call in the same test
session, now updating a different user's row via a superuser fixture" —
this broke `110_production_hardening.sql` TEST 117 (its `_t110_setup`
helper updates a field officer's `ward_id` after an earlier test's
`as_user()` call, without a following `as_service()`, a known GUC-
persistence gotcha in this test suite). Fixed by scoping the trigger to
`new.id = auth.uid()` explicitly, matching its actual intent (only
self-referential writes are restricted). 9 new tests
(`140_profile_role_immutability.sql`, TESTs 141-149) cover both the fix
and this exact regression scenario (TEST 149). Full local suite
re-verified clean afterward — 13 migrations, 14 test files, zero
failures.

### Everything else re-verified this phase

No other new security-relevant schema or RLS change this phase (the one
other schema change, `readings_ts_idx`, is a plain index with no
access-control implication). The full RLS regression suite (14 files,
200+ assertions) and `scripts/check_secrets.py` were re-run and both pass
cleanly. Two additional, real findings from this phase's own end-to-end
and historical validation work:

- **Confirmed, not just asserted**: citizens have zero read access to
  internal attribution/routing/officer data across a full, real
  multi-step lifecycle (`130_end_to_end_scenarios.sql` Scenario A), not
  just in an isolated RLS test.
- **Confirmed, not just asserted**: no authenticated role — commander
  included — can write `task_dispatches`/`notifications`/`job_runs`
  directly; every write in every end-to-end scenario went through a
  SECURITY DEFINER function, with zero exceptions found across 24
  scenario assertions.

The **city-scoping limitation stated above remains unchanged and is now
formally load-bearing for the pilot decision**: see
[PILOT_READINESS_REPORT.md](PILOT_READINESS_REPORT.md) section 8, which
records it as an explicit, accepted hard boundary for a Delhi-only pilot
— not a defect, but a real constraint that must be closed with dedicated
schema work before any second city's real data ever shares this hosted
project.
