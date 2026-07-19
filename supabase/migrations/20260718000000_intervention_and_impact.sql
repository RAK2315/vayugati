-- ============================================================
-- intervention_and_impact — additive migration (Phase 4, vertical slice)
--
-- Closes the incident loop from a verified source to a MEASURED outcome,
-- without touching any existing table, column or row destructively:
--
--   * one new enum: action_workflow_status (the intervention lifecycle).
--     The existing actions.status (report_status enum) is LEFT UNTOUCHED — the
--     Phase 4 lifecycle needs far more states than that enum has, and repurposing
--     it would be a breaking change to a column every current screen reads. So
--     the intervention lifecycle lives in a NEW column, actions.workflow_status.
--   * additive columns on actions (intervention detail + operational timestamps)
--     and impact_evaluations (before/after method detail).
--   * the enforce_incident_action_rules trigger is REPLACED (create or replace)
--     to (a) apply the evidence-level creation gate only at creation, so a later
--     downgrade cannot block routine workflow updates, and (b) refuse to mark an
--     action with an OUTCOME state unless an impact_evaluations row backs it.
--   * a NEW closure-guard trigger: an incident with a completed / verification-
--     pending action that has no impact evaluation cannot be closed. This is the
--     literal encoding of "an incident must not close merely because an action
--     photo was uploaded" (plan §15).
--   * record_impact_evaluation(): the transparent before/after computation.
--     SECURITY INVOKER on purpose — RLS (commander/admin only) gates the write,
--     and the outcome is DERIVED server-side so a client cannot claim a
--     reduction the data does not support.
--   * submit_citizen_action_verification(): a citizen linked to the incident may
--     report on the action outcome; it is recorded as SUPPORTING evidence and
--     never sets an outcome or touches source confidence (plan §11).
--
-- No existing RLS policy is changed. The existing action_evidence /
-- impact_evaluations / actions policies already express exactly what Phase 4
-- needs (field officer ward-scoped, commander/admin, citizens denied on
-- actions/action_evidence — verified in the Phase 3 tests).
--
-- Idempotent: safe to re-run and safe via `supabase db push`.
-- See docs/DATA_MODEL.md and docs/ROLE_WORKFLOWS.md.
-- ============================================================

-- ---------- intervention lifecycle enum ----------
-- Operational states (drafted..verification_pending) describe what the team did.
-- Outcome states (effective..inconclusive) describe whether pollution changed,
-- and are the SAME tokens as incident_outcome so record_impact_evaluation can
-- cast between them. 'reopened' closes the loop when a problem recurs.
-- The split is deliberate: "action completed" is NOT "pollution reduced".
do $$ begin
  create type action_workflow_status as enum (
    'drafted', 'awaiting_approval', 'assigned', 'accepted', 'in_progress',
    'completed', 'verification_pending',
    'effective', 'partly_effective', 'ineffective', 'inconclusive',
    'reopened'
  );
exception when duplicate_object then null;
end $$;

-- ---------- intervention detail on actions (all additive, nullable) ----------
-- Existing rows default to 'drafted'. Legacy report-scoped actions are never
-- incident-linked, so they never surface in the Phase 4 incident UI; the default
-- is harmless for them and documented in IMPLEMENTATION_STATUS.md.
alter table actions add column if not exists workflow_status action_workflow_status not null default 'drafted';
alter table actions add column if not exists recommended_action          text;
alter table actions add column if not exists responsible_agency          text;
alter table actions add column if not exists deadline                    timestamptz;
alter table actions add column if not exists expected_verification_hours int;
alter table actions add column if not exists accepted_at                 timestamptz;
alter table actions add column if not exists started_at                  timestamptz;
alter table actions add column if not exists completed_at                timestamptz;
alter table actions add column if not exists source_confirmed            boolean;
alter table actions add column if not exists not_completed_reason        text;
create index if not exists actions_incident_workflow_idx on actions (incident_id, workflow_status);
create index if not exists actions_assignee_workflow_idx on actions (assigned_to, workflow_status);

-- ---------- before/after detail on impact_evaluations (additive, nullable) ----------
alter table impact_evaluations add column if not exists observation_window_hours int;
alter table impact_evaluations add column if not exists station_label            text;
alter table impact_evaluations add column if not exists data_completeness        double precision
  check (data_completeness is null or (data_completeness >= 0 and data_completeness <= 1));
alter table impact_evaluations add column if not exists pct_change               double precision;
alter table impact_evaluations add column if not exists method_limitation        text;

-- ============================================================
-- Replace the evidence-level trigger (Phase 3) with a version that:
--   1. applies the creation gate only when the action is created or first linked
--      to an incident (a later evidence-level downgrade must not block routine
--      workflow updates on an already-legitimate action), and
--   2. refuses to mark an action with an OUTCOME state unless an impact
--      evaluation backs it — "a completed action is not a measured reduction".
-- The Phase 3 behaviour (suspected blocks action creation; enforcement needs a
-- verified source + a named approver) is preserved for INSERTs, which is what
-- the existing tests exercise.
-- ============================================================
create or replace function enforce_incident_action_rules() returns trigger
language plpgsql as $$
declare
  v_confidence source_confidence_level;
  v_creating   boolean;
  v_has_eval   boolean;
begin
  if new.incident_id is null then
    return new;  -- legacy report-scoped action: unchanged behaviour
  end if;

  v_creating := (tg_op = 'INSERT') or (new.incident_id is distinct from old.incident_id);

  if v_creating then
    select source_confidence into v_confidence from incidents where id = new.incident_id;
    if v_confidence is null then
      raise exception 'Incident % not found for action', new.incident_id;
    end if;

    if v_confidence = 'suspected' then
      raise exception
        'Incident % is only suspected: collect evidence first (evidence_missions). Action tasks require a corroborated source.',
        new.incident_id
        using errcode = 'check_violation';
    end if;

    if new.type in ('penalty', 'stop_work', 'closure', 'restriction', 'prosecution') then
      if v_confidence <> 'officially_verified' then
        raise exception
          'Enforcement action "%" requires an officially verified source on incident % (currently %).',
          new.type, new.incident_id, v_confidence
          using errcode = 'check_violation';
      end if;
      if new.approved_by is null then
        raise exception
          'Enforcement action "%" on incident % requires an authorised human approver (actions.approved_by).',
          new.type, new.incident_id
          using errcode = 'check_violation';
      end if;
    end if;
  end if;

  -- An outcome state must be backed by a real impact evaluation. This is the
  -- rule that stops "we uploaded a completion photo" from ever reading as "the
  -- pollution went down" (plan §15).
  if new.workflow_status in ('effective', 'partly_effective', 'ineffective', 'inconclusive') then
    select exists (select 1 from impact_evaluations e where e.action_id = new.id) into v_has_eval;
    if not v_has_eval then
      raise exception
        'Action % cannot be marked "%": record an impact evaluation first (a completed action is not a measured outcome).',
        new.id, new.workflow_status
        using errcode = 'check_violation';
    end if;
  end if;

  return new;
end $$;

drop trigger if exists enforce_incident_action_rules_trg on actions;
create trigger enforce_incident_action_rules_trg
  before insert or update on actions
  for each row execute function enforce_incident_action_rules();

-- ============================================================
-- Closure guard. An incident cannot move to 'closed' while it has a linked
-- action that has been done operationally (completed / verification_pending)
-- but never checked environmentally (no impact_evaluations row). This is the
-- literal encoding of "an incident must not close merely because an action
-- photo was uploaded" (plan §15). Incidents with no such action (e.g. a source
-- disproved in the field) can still close.
-- ============================================================
create or replace function enforce_incident_closure_rules() returns trigger
language plpgsql as $$
declare v_blocking int;
begin
  if new.status = 'closed' and (tg_op = 'INSERT' or old.status is distinct from 'closed') then
    select count(*) into v_blocking
    from actions a
    where a.incident_id = new.id
      and a.workflow_status in ('completed', 'verification_pending')
      and not exists (select 1 from impact_evaluations e where e.action_id = a.id);
    if v_blocking > 0 then
      raise exception
        'Incident % has % completed action(s) with no impact evaluation: verify whether pollution actually changed before closing.',
        new.id, v_blocking
        using errcode = 'check_violation';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists enforce_incident_closure_rules_trg on incidents;
create trigger enforce_incident_closure_rules_trg
  before insert or update on incidents
  for each row execute function enforce_incident_closure_rules();

-- ============================================================
-- record_impact_evaluation — the transparent before/after method (plan §15/§16).
--
-- The outcome is DERIVED here, server-side, not accepted from the caller: a
-- client cannot claim "effective" when the data does not support it. Missing or
-- insufficient data yields 'inconclusive', never a fabricated reduction.
--
-- SECURITY INVOKER (default): RLS decides who may write. impact_evaluations_write
-- is commander/admin only, so a field officer calling this fails on the insert,
-- which is correct — impact evaluation is a command action. The eval row is
-- inserted BEFORE the action is moved to an outcome state, so the action trigger
-- above sees it and allows the transition.
--
-- Rule (stated, not a model):
--   before/after null, before<=0, or completeness < 0.5  -> inconclusive
--   reduction >= 40%                                      -> effective
--   reduction >= 15%                                      -> partly_effective
--   otherwise (incl. increases)                           -> ineffective
-- ============================================================
create or replace function record_impact_evaluation(
  p_incident_id  bigint,
  p_action_id    bigint,
  p_before       double precision,
  p_after        double precision,
  p_window_hours int,
  p_station      text,
  p_completeness double precision,
  p_notes        text default null
) returns text
language plpgsql as $$
declare
  v_outcome    incident_outcome;
  v_pct        double precision;
  v_reduction  double precision;
  v_limit text := 'Before/after comparison only. Not weather-adjusted and not causal proof — concurrent weather and citywide changes are not controlled for.';
begin
  if p_before is null or p_after is null or p_before <= 0 or coalesce(p_completeness, 0) < 0.5 then
    v_outcome := 'inconclusive';
    v_pct := null;
  else
    v_pct := (p_after - p_before) / p_before * 100.0;
    v_reduction := (p_before - p_after) / p_before;
    if v_reduction >= 0.40 then
      v_outcome := 'effective';
    elsif v_reduction >= 0.15 then
      v_outcome := 'partly_effective';
    else
      v_outcome := 'ineffective';
    end if;
  end if;

  insert into impact_evaluations (
    incident_id, action_id, method, before_value, after_value,
    observation_window_hours, station_label, data_completeness, pct_change,
    outcome, confidence, method_limitation, evaluated_by, notes
  ) values (
    p_incident_id, p_action_id, 'before_after', p_before, p_after,
    p_window_hours, p_station, p_completeness, v_pct,
    v_outcome,
    -- confidence here is a data-completeness proxy, NOT a statistical
    -- confidence; null when we could not measure at all.
    case when v_outcome = 'inconclusive' then null else p_completeness end,
    v_limit, auth.uid(), p_notes
  );

  -- Reflect the outcome onto the action (the eval now exists, so the action
  -- trigger permits the outcome state).
  if p_action_id is not null then
    update actions
       set workflow_status = v_outcome::text::action_workflow_status,
           resolved_at = coalesce(resolved_at, now())
     where id = p_action_id;
  end if;

  -- Move to 'verifying' — never auto-close. Closing stays a separate, human
  -- decision (and is itself guarded).
  update incidents set status = 'verifying', updated_at = now()
   where id = p_incident_id and status <> 'closed';

  insert into incident_events (incident_id, event_type, actor_id, note, is_public, payload)
  values (
    p_incident_id, 'impact_evaluated', auth.uid(),
    case v_outcome
      when 'inconclusive'     then 'Impact could not be measured — data was missing or incomplete, so no reduction is claimed.'
      when 'effective'        then 'Before/after readings indicate the action was effective (not weather-adjusted).'
      when 'partly_effective' then 'Before/after readings indicate the action was partly effective (not weather-adjusted).'
      else                         'Before/after readings indicate the action did not reduce pollution (not weather-adjusted).'
    end,
    true,
    jsonb_build_object('outcome', v_outcome, 'pct_change', v_pct, 'method', 'before_after', 'completeness', p_completeness)
  );

  return v_outcome::text;
end $$;

revoke all on function record_impact_evaluation(bigint, bigint, double precision, double precision, int, text, double precision, text) from public;
grant execute on function record_impact_evaluation(bigint, bigint, double precision, double precision, int, text, double precision, text) to authenticated;

-- ============================================================
-- submit_citizen_action_verification — a citizen linked to the incident reports
-- on the action outcome (plan §11, §15). Recorded as SUPPORTING evidence only:
-- it never sets an outcome, never touches source confidence, and never closes or
-- reopens the incident — a citizen's confirmation supports the result but cannot
-- independently prove pollution reduction.
--
-- SECURITY DEFINER so the linked-report check is the guard (the citizen must own
-- a report on this incident), rather than relying on the permissive
-- incident_evidence insert policy.
-- ============================================================
create or replace function submit_citizen_action_verification(
  p_incident_id bigint,
  p_answer      text
) returns void
language plpgsql security definer set search_path = public as $$
declare v_linked boolean;
begin
  if p_answer not in ('completed', 'partial', 'not_completed', 'problem_remains', 'problem_returned') then
    raise exception 'Invalid answer "%"', p_answer;
  end if;

  select exists (
    select 1 from reports r where r.incident_id = p_incident_id and r.reporter_id = auth.uid()
  ) into v_linked;
  if not v_linked then
    raise exception 'You can only confirm incidents linked to your own report';
  end if;

  insert into incident_evidence (incident_id, evidence_type, supports, collected_by, payload)
  values (
    p_incident_id, 'citizen_report',
    null,  -- supports the result but does not prove reduction; never true/false
    auth.uid(),
    jsonb_build_object('citizen_action_answer', p_answer, 'authorised_officer', false)
  );

  insert into incident_events (incident_id, event_type, actor_id, note, is_public, payload)
  values (
    p_incident_id, 'evidence_added', auth.uid(),
    'A citizen reported on the action outcome.', true,
    jsonb_build_object('citizen_action_answer', p_answer)
  );
end $$;

revoke all on function submit_citizen_action_verification(bigint, text) from public;
grant execute on function submit_citizen_action_verification(bigint, text) to authenticated;
