-- ============================================================
-- submit_mission_result / submit_field_completion — atomic, idempotent
-- replacements for two non-transactional, multi-call client-side write
-- sequences (web/src/lib/incidents.ts's submitMissionResult and
-- submitFieldCompletion). Follow-up flagged explicitly when the offline
-- queue shipped (offlineSync.ts): "no server-side idempotency key... a
-- fully atomic fix is real backend work beyond this pass." This is that
-- fix.
--
-- Pattern: mirrors the existing submit_citizen_verification function
-- (20260725000000_production_hardening.sql) almost exactly — same
-- evidence_missions -> incident_evidence -> incident_events write
-- sequence inside one plpgsql security definer function (a Postgres
-- function body is one implicit transaction, so a mid-sequence failure
-- rolls back everything, fixing the ONLINE non-atomicity too, not just
-- offline replay). Authorization is derived from auth.uid() directly
-- inside the function ("security definer bypasses RLS: these checks are
-- the whole guard" - same comment as submit_citizen_verification), NOT
-- from a client-supplied actor id the way transition_task_dispatch does -
-- that function's p_actor_id-trusting convention is a pre-existing gap,
-- not one to propagate into new code.
--
-- Idempotency: a nullable idempotency_key uuid column on the target row
-- (evidence_missions / actions). The row is locked (select ... for
-- update) before checking it, so a genuinely concurrent replay serializes
-- rather than racing the writes. A matching key is a silent no-op
-- (already applied). Adopts submit_citizen_verification's own "already
-- closed -> refuse" convention for a DIFFERENT key on an already-completed
-- row - a small, deliberate tightening of today's client behavior (which
-- has no such guard at all), not a pure atomicity fix, made because the
-- sibling function already establishes this as the house convention.
--
-- Nothing here is destructive: two new nullable columns, two new
-- functions, no existing object touched.
-- ============================================================

alter table evidence_missions add column if not exists idempotency_key uuid;
alter table actions add column if not exists idempotency_key uuid;

-- Guards against a stale function from an earlier draft of this same
-- migration (the parameter order changed once during development, before
-- this file was ever applied anywhere) - `create or replace` cannot change
-- a function's parameter list, so this makes re-running safe regardless of
-- what, if anything, was already applied under the old signature.
drop function if exists submit_mission_result(bigint, bigint, text, jsonb, text, double precision, double precision, text, uuid);
drop function if exists submit_field_completion(bigint, bigint, boolean, text, timestamptz, timestamptz, text[], jsonb, double precision, double precision, text, uuid);

-- Params with `default null` after the required ones are what makes the
-- generated Supabase RPC Args type accept `| null` for these business-
-- optional fields (Postgres requires defaulted params to trail non-defaulted
-- ones in the declaration - callers still always pass every field by name
-- via supabase-js, so the declaration order has no effect on call sites).
create or replace function submit_mission_result(
  p_mission_id         bigint,
  p_incident_id        bigint,
  p_outcome            text,
  p_checklist_response jsonb,
  p_idempotency_key    uuid,
  p_proof_photo_url    text default null,
  p_lat                double precision default null,
  p_lng                double precision default null,
  p_notes              text default null
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_m           evidence_missions%rowtype;
  v_caller_role user_role;
  v_note        text;
begin
  if p_idempotency_key is null then
    raise exception 'p_idempotency_key is required.' using errcode = 'check_violation';
  end if;
  if p_outcome not in ('confirmed', 'rejected', 'unresolved') then
    raise exception 'Invalid outcome "%".', p_outcome using errcode = 'check_violation';
  end if;

  select * into v_m from evidence_missions where id = p_mission_id for update;
  if not found then
    raise exception 'Evidence mission % not found.', p_mission_id using errcode = 'no_data_found';
  end if;

  -- idempotent replay: this exact submission already landed - no-op, not an error.
  if v_m.idempotency_key is not null and v_m.idempotency_key = p_idempotency_key then
    return;
  end if;

  -- security definer bypasses RLS: this is the whole guard (same convention as submit_citizen_verification).
  select role into v_caller_role from profiles where id = auth.uid();
  if coalesce(v_caller_role, 'citizen') not in ('commander', 'admin') and v_m.assigned_to is distinct from auth.uid() then
    raise exception 'Only the assigned officer (or command) may submit this mission result.'
      using errcode = 'insufficient_privilege';
  end if;

  -- Same "already closed" refusal submit_citizen_verification already
  -- establishes - only a matching-key replay (handled above) may pass
  -- through a completed mission silently.
  if v_m.status in ('completed', 'cancelled') then
    raise exception 'This mission is already closed.' using errcode = 'check_violation';
  end if;

  update evidence_missions set
    status             = 'completed',
    outcome            = p_outcome,
    checklist_response = p_checklist_response,
    proof_photo_url    = p_proof_photo_url,
    lat                = p_lat,
    lng                = p_lng,
    notes              = p_notes,
    completed_at       = now(),
    idempotency_key    = p_idempotency_key
  where id = p_mission_id;

  insert into incident_evidence (incident_id, evidence_type, supports, report_id, payload, collected_by)
  values (
    p_incident_id,
    case when p_proof_photo_url is not null then 'photo' else 'field_inspection' end,
    case p_outcome when 'confirmed' then true when 'rejected' then false else null end,
    null,
    jsonb_build_object(
      'outcome', p_outcome, 'checklist', p_checklist_response, 'photo_url', p_proof_photo_url,
      'lat', p_lat, 'lng', p_lng, 'mission_id', p_mission_id,
      'authorised_officer', coalesce(v_caller_role, 'citizen') in ('field_officer', 'admin')
    ),
    auth.uid()
  );

  v_note := case p_outcome
    when 'confirmed' then 'A field visit confirmed the suspected source.'
    when 'rejected'  then 'A field visit did not find the suspected source.'
    else 'A field visit could not determine the source.'
  end;

  insert into incident_events (incident_id, event_type, actor_id, note, is_public, payload)
  values (p_incident_id, 'evidence_added', auth.uid(), v_note, true, jsonb_build_object('outcome', p_outcome));
end $$;

revoke all on function submit_mission_result(bigint, bigint, text, jsonb, uuid, text, double precision, double precision, text) from public;
grant execute on function submit_mission_result(bigint, bigint, text, jsonb, uuid, text, double precision, double precision, text) to authenticated;

create or replace function submit_field_completion(
  p_action_id            bigint,
  p_incident_id          bigint,
  p_action_performed     text,
  p_photo_urls           text[],
  p_checklist_response   jsonb,
  p_idempotency_key      uuid,
  p_source_confirmed     boolean default null,
  p_started_at           timestamptz default null,
  p_completed_at         timestamptz default null,
  p_lat                  double precision default null,
  p_lng                  double precision default null,
  p_not_completed_reason text default null
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_a             actions%rowtype;
  v_caller_role   user_role;
  v_caller_ward   int;
  v_was_completed boolean;
  v_url           text;
begin
  if p_idempotency_key is null then
    raise exception 'p_idempotency_key is required.' using errcode = 'check_violation';
  end if;
  v_was_completed := coalesce(trim(p_not_completed_reason), '') = '';
  if not v_was_completed and coalesce(trim(p_not_completed_reason), '') = '' then
    raise exception 'Record why the action could not be completed.' using errcode = 'check_violation';
  end if;

  select * into v_a from actions where id = p_action_id for update;
  if not found then
    raise exception 'Action % not found.', p_action_id using errcode = 'no_data_found';
  end if;

  if v_a.idempotency_key is not null and v_a.idempotency_key = p_idempotency_key then
    return;
  end if;

  select role, ward_id into v_caller_role, v_caller_ward from profiles where id = auth.uid();
  if coalesce(v_caller_role, 'citizen') not in ('commander', 'admin')
     and not (v_caller_role = 'field_officer' and v_a.ward_id = v_caller_ward) then
    raise exception 'Only a field officer in this action''s ward (or command) may submit this completion.'
      using errcode = 'insufficient_privilege';
  end if;

  if v_a.workflow_status = 'completed' then
    raise exception 'This action is already marked completed.' using errcode = 'check_violation';
  end if;

  update actions set
    workflow_status      = case when v_was_completed then 'completed' else 'in_progress' end::action_workflow_status,
    source_confirmed      = p_source_confirmed,
    started_at             = p_started_at,
    completed_at           = case when v_was_completed then p_completed_at else null end,
    not_completed_reason   = p_not_completed_reason,
    idempotency_key         = p_idempotency_key
  where id = p_action_id;

  if p_lat is not null and p_lng is not null then
    insert into action_evidence (action_id, evidence_type, payload, captured_by)
    values (p_action_id, 'gps', jsonb_build_object('lat', p_lat, 'lng', p_lng), auth.uid());
  end if;

  insert into action_evidence (action_id, evidence_type, payload, captured_by)
  values (
    p_action_id, 'checklist',
    jsonb_build_object('checklist', p_checklist_response, 'action_performed', p_action_performed,
      'source_confirmed', p_source_confirmed),
    auth.uid()
  );

  foreach v_url in array coalesce(p_photo_urls, array[]::text[]) loop
    insert into action_evidence (action_id, evidence_type, photo_url, payload, captured_by)
    values (p_action_id, 'photo', v_url, jsonb_build_object('lat', p_lat, 'lng', p_lng), auth.uid());
  end loop;

  if p_started_at is not null and p_completed_at is not null then
    insert into action_evidence (action_id, evidence_type, payload, captured_by)
    values (p_action_id, 'timestamp',
      jsonb_build_object('started_at', p_started_at, 'completed_at', p_completed_at), auth.uid());
  end if;

  if not v_was_completed then
    insert into action_evidence (action_id, evidence_type, payload, captured_by)
    values (p_action_id, 'other', jsonb_build_object('not_completed_reason', p_not_completed_reason), auth.uid());
  end if;

  insert into incident_events (incident_id, event_type, actor_id, note, is_public, payload)
  values (
    p_incident_id,
    case when v_was_completed then 'action_completed' else 'status_changed' end,
    auth.uid(),
    case when v_was_completed
      then 'Field officer recorded the intervention as completed. Pollution impact has not been verified yet.'
      else format('Field officer could not complete the intervention: %s', p_not_completed_reason)
    end,
    true,
    jsonb_build_object('action_id', p_action_id, 'source_confirmed', p_source_confirmed, 'completed', v_was_completed)
  );
end $$;

revoke all on function submit_field_completion(bigint, bigint, text, text[], jsonb, uuid, boolean, timestamptz, timestamptz, double precision, double precision, text) from public;
grant execute on function submit_field_completion(bigint, bigint, text, text[], jsonb, uuid, boolean, timestamptz, timestamptz, double precision, double precision, text) to authenticated;
