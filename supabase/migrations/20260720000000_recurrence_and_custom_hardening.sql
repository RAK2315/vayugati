-- ============================================================
-- recurrence_and_custom_hardening — additive migration (Phase 5.1, vertical slice)
--
-- Two things, both additive:
--
--   1. Citizen recurrence reporting: a citizen linked to a CLOSED incident may
--      report that the problem returned, without automatically reopening the
--      incident or creating an enforcement task. Command reviews the report and
--      chooses: dismiss, request more evidence, confirm, reopen the original
--      incident, create a new linked incident, or merge into an already-open
--      nearby incident. New table `incident_recurrence_reports`, one new
--      nullable self-referencing column on `incidents`
--      (`recurrence_of_incident_id`, for traceability of a new linked incident
--      back to the one it recurred from), and two security-definer functions
--      (submit / list-mine) — the same pattern Phase 3/4 already used for
--      citizen writes that RLS alone cannot express safely.
--
--   2. Custom-intervention hardening: `enforce_incident_action_rules` (same
--      function, `create or replace`d a fourth time) gains real DATABASE
--      guarantees that were previously only true because the only UI that
--      called `createIntervention`/`createInterventionFromPlaybook` happened to
--      live behind a commander-only ROUTE. Verified gap (not assumed): the
--      BASELINE `actions_write` policy (schema.sql) grants a field_officer
--      `for all` on any action in their own ward, with no distinction for
--      incident-linked vs legacy or custom vs playbook — so a field-officer
--      client could previously INSERT an incident-linked action directly,
--      bypassing the command-only UI entirely. This migration closes that at
--      the trigger level, where it cannot be bypassed by any client:
--        - creating an incident-linked action now requires commander/admin,
--          full stop (both playbook-based and custom);
--        - a custom (no playbook_id) incident-linked action must carry a
--          non-empty `custom_reason` explaining why no playbook was suitable;
--        - an incident classified 'regional' only accepts 'advisory_monitoring'
--          as an incident-linked action type, custom or not — the same "do not
--          recommend/allow ineffective local action" rule Phase 5's playbook
--          eligibility applied client-side, now enforced server-side too;
--        - once `approved_by` is set, the descriptive fields
--          (`type`/`recommended_action`/`responsible_agency`/`custom_reason`)
--          become immutable — no silent edits after approval, by anyone;
--      plus a NEW, guaranteed AFTER INSERT trigger that writes the creation
--      event directly from SQL, so the audit trail no longer depends on the
--      client remembering to call it.
--
-- No existing RLS policy on any table is widened. No existing column is
-- altered or dropped.
--
-- Idempotent: safe to re-run and safe via `supabase db push`.
-- See docs/DATA_MODEL.md and docs/ROLE_WORKFLOWS.md.
-- ============================================================

-- ---------- recurrence reports (additive, new table) ----------
create table if not exists incident_recurrence_reports (
  id                     bigserial primary key,
  incident_id            bigint not null references incidents(id) on delete cascade,
  reporter_id            uuid references profiles(id),
  recurrence_type        text not null check (recurrence_type in (
    'returned', 'partially_returned', 'action_temporary', 'unable_to_confirm'
  )),
  note                   text,
  lat                    double precision,
  lng                    double precision,
  photo_url              text,
  created_at             timestamptz not null default now(),
  review_status          text not null default 'pending' check (review_status in (
    'pending', 'more_evidence_requested', 'confirmed', 'dismissed'
  )),
  -- The ONLY text a citizen is ever shown about the review outcome. Internal
  -- reasoning goes to incident_events with is_public = false, same split as
  -- every other citizen-facing surface in this codebase (public_prompt vs
  -- rationale, public_response here vs internal notes).
  public_response        text,
  reviewed_by            uuid references profiles(id),
  reviewed_at            timestamptz,
  -- Set only when command chooses "create a new linked incident" from this
  -- report. Null for a reopen decision (the original incident's own status
  -- moving off 'closed' already represents that) and null while pending.
  resulting_incident_id  bigint references incidents(id) on delete set null
);
create index if not exists incident_recurrence_reports_incident_idx
  on incident_recurrence_reports (incident_id, review_status);
-- Duplicate detection: the same reporter's pending reports on the same incident.
create index if not exists incident_recurrence_reports_reporter_idx
  on incident_recurrence_reports (reporter_id, incident_id, review_status);

alter table incident_recurrence_reports enable row level security;

-- Read: commander/admin (all), field_officer (ward-scoped via the parent
-- incident). Citizens have NO direct read — structural, matching
-- evidence_missions: they go through list_my_recurrence_reports() instead,
-- which returns only citizen-safe columns (never `note`'s raw internal
-- handling, never other citizens' rows, never the reviewer's identity).
drop policy if exists incident_recurrence_reports_read on incident_recurrence_reports;
create policy incident_recurrence_reports_read on incident_recurrence_reports for select using (
  auth_role() in ('commander', 'admin')
  or (
    auth_role() = 'field_officer'
    and exists (select 1 from incidents i where i.id = incident_recurrence_reports.incident_id and i.ward_id = auth_ward())
  )
);
-- Write: commander/admin only — every review decision (dismiss / request more
-- evidence / confirm / set resulting_incident_id) is a plain RLS-gated UPDATE,
-- exactly like Phase 4's approveIntervention/assignIntervention. The only
-- INSERT path is the security-definer submit function below; there is no
-- policy granting citizens (or anyone else) direct insert.
drop policy if exists incident_recurrence_reports_write on incident_recurrence_reports;
create policy incident_recurrence_reports_write on incident_recurrence_reports for all using (
  auth_role() in ('commander', 'admin')
) with check (
  auth_role() in ('commander', 'admin')
);

-- ---------- traceability: a new incident created FROM a recurrence report ----------
-- Nullable, self-referencing. Paired with incident_recurrence_reports
-- .resulting_incident_id: that column points report -> new incident; this one
-- points new incident -> the incident it recurred from. Together they make
-- "linked incidents preserve traceability" checkable in both directions.
alter table incidents add column if not exists recurrence_of_incident_id bigint references incidents(id);
create index if not exists incidents_recurrence_of_idx on incidents (recurrence_of_incident_id);

-- `incident_evidence.evidence_type` gains one more allowed value so the
-- "merge with an already-open nearby incident" command decision can attach the
-- recurrence report's own evidence (note/photo/location) onto the TARGET
-- incident, alongside the existing evidence types — additive in effect (widens
-- the allowed set; no existing row's evidence_type is touched).
do $$ begin
  alter table incident_evidence drop constraint if exists incident_evidence_evidence_type_check;
  alter table incident_evidence add constraint incident_evidence_evidence_type_check
    check (evidence_type in (
      'reading', 'citizen_report', 'field_inspection', 'satellite', 'sensor', 'photo', 'other', 'recurrence_report'
    ));
exception when duplicate_object then null;
end $$;

-- ============================================================
-- submit_incident_recurrence_report — the citizen's entire write path.
--
-- security definer because, exactly like submit_citizen_action_verification,
-- the ownership check ("does this citizen have a report linked to this
-- incident") mixes two tables in a way the standard RLS policy shape on
-- incident_recurrence_reports cannot express for an INSERT before the row
-- exists to check against.
--
-- Deliberately does NOT touch `incidents` or `actions` anywhere in this
-- function body — that absence IS the guarantee that a citizen's recurrence
-- report can never automatically reopen the incident or create an enforcement
-- task. There is no code path here that could do either, not even accidentally.
--
-- Duplicate detection: if the SAME reporter already has a PENDING report on
-- this incident, this call is idempotent — it returns that report's id rather
-- than inserting a second one. Once command reviews it (status moves off
-- 'pending'), a further recurrence is treated as a new, independent signal.
-- ============================================================
create or replace function submit_incident_recurrence_report(
  p_incident_id      bigint,
  p_recurrence_type  text,
  p_note             text default null,
  p_lat              double precision default null,
  p_lng              double precision default null,
  p_photo_url        text default null
) returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_incident_status incident_status;
  v_linked          boolean;
  v_existing        bigint;
  v_new_id          bigint;
begin
  if p_recurrence_type not in ('returned', 'partially_returned', 'action_temporary', 'unable_to_confirm') then
    raise exception 'Invalid recurrence type "%"', p_recurrence_type;
  end if;

  select status into v_incident_status from incidents where id = p_incident_id;
  if v_incident_status is null then
    raise exception 'Incident % not found', p_incident_id;
  end if;
  if v_incident_status <> 'closed' then
    raise exception 'Recurrence can only be reported on a closed incident (currently "%")', v_incident_status;
  end if;

  select exists (
    select 1 from reports r where r.incident_id = p_incident_id and r.reporter_id = auth.uid()
  ) into v_linked;
  if not v_linked then
    raise exception 'You can only report recurrence on incidents linked to your own report';
  end if;

  -- Idempotent duplicate detection: a pending report from this reporter on
  -- this incident already exists -> return it unchanged rather than filing a
  -- second one. Mirrors link_report_to_incident's "already linked" no-op.
  select id into v_existing
  from incident_recurrence_reports
  where incident_id = p_incident_id and reporter_id = auth.uid() and review_status = 'pending'
  limit 1;
  if v_existing is not null then
    return v_existing;
  end if;

  insert into incident_recurrence_reports (incident_id, reporter_id, recurrence_type, note, lat, lng, photo_url)
  values (p_incident_id, auth.uid(), p_recurrence_type, p_note, p_lat, p_lng, p_photo_url)
  returning id into v_new_id;

  -- Public: a citizen viewing their own closed incident is entitled to see
  -- that their own report was received (plan's "after submission, show:
  -- recurrence report submitted") — this note is generic, names no one, and
  -- carries no enforcement detail, so it is safe to be public by construction.
  insert into incident_events (incident_id, event_type, actor_id, note, is_public, payload)
  values (
    p_incident_id, 'recurrence_submitted', auth.uid(),
    'A citizen reported that the problem may have returned.', true,
    jsonb_build_object('recurrence_report_id', v_new_id, 'recurrence_type', p_recurrence_type)
  );

  return v_new_id;
end $$;

revoke all on function submit_incident_recurrence_report(bigint, text, text, double precision, double precision, text) from public;
grant execute on function submit_incident_recurrence_report(bigint, text, text, double precision, double precision, text) to authenticated;

-- ============================================================
-- list_my_recurrence_reports — the citizen's entire read path for their own
-- recurrence reports on one incident. Returns only citizen-safe columns:
-- never `reviewed_by` (an internal identity), never other citizens' rows.
--
-- `outcome_kind` is computed here, server-side, rather than exposing the raw
-- `resulting_incident_id` FK — a citizen is told WHETHER their report led to a
-- reopen or a new linked incident, without being handed an id that (per the
-- unchanged incidents_read policy) they usually cannot actually open anyway,
-- since their own report stays linked to the ORIGINAL incident, not the new
-- one. Stating the fact in words avoids implying a link that doesn't resolve.
-- ============================================================
create or replace function list_my_recurrence_reports(p_incident_id bigint)
returns table (
  report_id        bigint,
  recurrence_type  text,
  created_at       timestamptz,
  review_status    text,
  public_response  text,
  outcome_kind     text
)
language sql stable security definer set search_path = public as $$
  select
    r.id, r.recurrence_type, r.created_at, r.review_status, r.public_response,
    case
      when r.resulting_incident_id is not null then 'new_incident'
      when r.review_status = 'confirmed'
           and (select i.status from incidents i where i.id = r.incident_id) <> 'closed' then 'reopened'
      else null
    end
  from incident_recurrence_reports r
  where r.incident_id = p_incident_id
    and r.reporter_id = auth.uid()
  order by r.created_at desc
$$;

revoke all on function list_my_recurrence_reports(bigint) from public;
grant execute on function list_my_recurrence_reports(bigint) to authenticated;

-- ============================================================
-- Custom-intervention hardening: enforce_incident_action_rules, extended a
-- fourth time (create or replace, same function/trigger name as Phase 3/4/5).
-- ============================================================
create or replace function enforce_incident_action_rules() returns trigger
language plpgsql as $$
declare
  v_confidence       source_confidence_level;
  v_classification   incident_classification;
  v_creating         boolean;
  v_has_eval         boolean;
  v_playbook_min     source_confidence_level;
begin
  if new.incident_id is null then
    return new;  -- legacy report-scoped action: unchanged behaviour
  end if;

  v_creating := (tg_op = 'INSERT') or (new.incident_id is distinct from old.incident_id);

  if v_creating then
    -- Phase 5.1: creating ANY incident-linked intervention — playbook-based or
    -- custom — is a command decision. Verified gap this closes: the baseline
    -- actions_write policy otherwise lets a field_officer INSERT directly into
    -- their own ward's actions with no distinction for incident-linked rows.
    if auth_role() not in ('commander', 'admin') then
      raise exception
        'Only a commander or admin may create an incident-linked intervention.'
        using errcode = 'insufficient_privilege';
    end if;

    select source_confidence, classification into v_confidence, v_classification
      from incidents where id = new.incident_id;
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

    -- Phase 5 addition: playbook-tier fidelity.
    if new.playbook_id is not null then
      select min_evidence_level into v_playbook_min
      from intervention_playbooks where id = new.playbook_id;
      if v_playbook_min is null then
        raise exception 'Playbook % not found', new.playbook_id;
      end if;
      if v_confidence < v_playbook_min then
        raise exception
          'Playbook requires at least "%" evidence; incident % is currently "%".',
          v_playbook_min, new.incident_id, v_confidence
          using errcode = 'check_violation';
      end if;
    end if;

    -- Phase 5.1: the custom (no-playbook) fallback must always say why no
    -- playbook was suitable — a real database guarantee, not merely a UI
    -- validation that a direct API call could skip.
    if new.playbook_id is null and coalesce(trim(new.custom_reason), '') = '' then
      raise exception
        'A custom intervention (no playbook) must record why no playbook was suitable (actions.custom_reason).'
        using errcode = 'check_violation';
    end if;

    -- Phase 5.1: local/regional compatibility for the custom fallback too —
    -- the same "do not allow ineffective local action against a regional
    -- source" rule Phase 5's playbook eligibility already applied client-side,
    -- now enforced here so it cannot be sidestepped by typing free text
    -- instead of picking the regional playbook.
    if v_classification = 'regional' and new.type <> 'advisory_monitoring' then
      raise exception
        'Incident % is classified regional: local intervention types are not appropriate. Only an advisory/monitoring action is permitted.',
        new.incident_id
        using errcode = 'check_violation';
    end if;
  end if;

  -- Phase 5.1: once approved, the descriptive fields become an immutable
  -- snapshot — no silent edits after approval, by anyone, playbook-based or
  -- custom. A genuine change means creating a new intervention, which is the
  -- auditable path.
  if tg_op = 'UPDATE' and old.approved_by is not null then
    if new.type is distinct from old.type
       or new.recommended_action is distinct from old.recommended_action
       or new.responsible_agency is distinct from old.responsible_agency
       or new.custom_reason is distinct from old.custom_reason then
      raise exception
        'Action % was approved on %: its instructions are now immutable. Create a new intervention instead of editing this one.',
        new.id, old.approved_at
        using errcode = 'check_violation';
    end if;
  end if;

  -- An outcome state must be backed by a real impact evaluation (Phase 4,
  -- unchanged): "a completed action is not a measured reduction."
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

-- `custom_reason` — the mandatory field the trigger above now requires for any
-- custom (no-playbook) incident-linked action. Nullable at the column level
-- (legacy/report-scoped and playbook-based rows never set it); the trigger is
-- what makes it mandatory exactly where it needs to be.
alter table actions add column if not exists custom_reason text;

-- ============================================================
-- Guaranteed audit trail for intervention creation. AFTER INSERT (not BEFORE,
-- and not the same trigger as the validation above) so it only fires once the
-- row genuinely exists, and so the event write can never be the reason a
-- legitimate creation fails. This replaces the client-side addIncidentEvent
-- call `createIntervention`/`createInterventionFromPlaybook` used to make
-- best-effort — the event is now written directly from SQL, so it happens
-- regardless of what the client does afterward. "Immutable audit event."
-- ============================================================
create or replace function log_action_creation_event() returns trigger
language plpgsql as $$
begin
  if new.incident_id is not null then
    insert into incident_events (incident_id, event_type, actor_id, note, is_public, payload)
    values (
      new.incident_id,
      case when new.playbook_id is not null then 'task_created' else 'custom_intervention_created' end,
      auth.uid(),
      case
        when new.playbook_id is not null then
          'Intervention created from playbook #' || new.playbook_id
          || coalesce(' (v' || new.playbook_version || ')', '') || '.'
        else
          'Custom intervention created: ' || coalesce(new.recommended_action, new.type, 'action')
          || '. Reason no playbook was used: ' || coalesce(new.custom_reason, '(not recorded)') || '.'
      end,
      true,
      jsonb_build_object(
        'action_id', new.id, 'action_type', new.type, 'playbook_id', new.playbook_id,
        'is_custom', new.playbook_id is null
      )
    );
  end if;
  return new;
end $$;

drop trigger if exists log_action_creation_event_trg on actions;
create trigger log_action_creation_event_trg
  after insert on actions
  for each row execute function log_action_creation_event();
