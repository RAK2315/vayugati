-- ============================================================
-- incident_workflow — additive migration (Phase 3, vertical slice)
--
-- Makes the incident schema from 20260717000000_incidents_core.sql actually
-- operable end-to-end, without touching any existing table, column or row
-- destructively. Everything here is additive:
--
--   * new nullable columns on incidents / evidence_missions / actions
--   * one new column on incident_events (is_public, default false = safe)
--   * two replaced policies (incident_events_read, evidence_missions_write)
--     — both TIGHTEN access; neither widens it
--   * two security-definer functions: link_report_to_incident (performs the
--     report -> incident match/create, which RLS forbids the citizen from doing
--     directly) and list_assignable_officers (lets a commander see who they may
--     assign a mission to, which the baseline profiles policy forbids)
--   * one trigger enforcing the suspected/corroborated/verified task rules
--
-- No existing RLS policy is widened. The two functions expose exactly one
-- narrow capability each and check the caller's role internally.
--
-- Why the security-definer function exists (verified, not assumed):
-- under the Phase 2 RLS, a citizen CANNOT insert into `incidents`
-- (incidents_write allows commander/admin/field_officer only) and CANNOT
-- update `reports.incident_id` (reports_update_officer excludes citizens —
-- the UPDATE silently affects 0 rows rather than raising). So the linking
-- step cannot run as the citizen from the browser. It is therefore performed
-- by a security-definer function that the reporter may call only for their
-- OWN report. This also makes match-or-create atomic, which is what actually
-- prevents duplicate incidents when several reports arrive at once.
--
-- Idempotent: safe to re-run and safe via `supabase db push`.
-- See docs/DATA_MODEL.md and docs/ROLE_WORKFLOWS.md.
-- ============================================================

-- ---------- incident workflow columns ----------
-- Snapshot fields: recorded at detection so the queue can rank/filter without
-- re-deriving from live forecasts (which change under the operator's feet).
alter table incidents add column if not exists assigned_authority text;
alter table incidents add column if not exists local_excess       double precision;
alter table incidents add column if not exists severity           text
  check (severity is null or severity in ('low', 'moderate', 'high', 'severe'));

-- ---------- evidence mission: field/citizen submission fields ----------
-- `result jsonb` already exists for free-form payloads; these are the fields the
-- workflow actually queries or gates on, so they are real columns, not jsonb keys.
alter table evidence_missions add column if not exists outcome text
  check (outcome is null or outcome in ('confirmed', 'rejected', 'unresolved'));
alter table evidence_missions add column if not exists checklist_response jsonb;
alter table evidence_missions add column if not exists proof_photo_url    text;
alter table evidence_missions add column if not exists lat                double precision;
alter table evidence_missions add column if not exists lng                double precision;
alter table evidence_missions add column if not exists notes              text;
-- Citizen-facing question. Deliberately separate from `rationale`, which is the
-- internal "why we need this evidence" note and may name authorities or
-- enforcement intent. Citizens are only ever shown public_prompt.
alter table evidence_missions add column if not exists public_prompt text;

-- ---------- action approval (plan §14) ----------
alter table actions add column if not exists approval_level approval_level;
alter table actions add column if not exists approved_by    uuid references profiles(id);
alter table actions add column if not exists approved_at    timestamptz;

-- ---------- citizen-safe timeline ----------
-- Incident events default to internal. Only events explicitly marked public are
-- ever visible to a citizen, so operational/enforcement notes cannot leak by
-- default — a new event type added later is private unless someone opts in.
alter table incident_events add column if not exists is_public boolean not null default false;
create index if not exists incident_events_public_idx on incident_events (incident_id, is_public, ts);

-- Replaces the Phase 2 policy: same rule for staff, but the citizen carve-out is
-- now restricted to is_public events. This is strictly narrower than before.
drop policy if exists incident_events_read on incident_events;
create policy incident_events_read on incident_events for select using (
  exists (
    select 1 from incidents i where i.id = incident_events.incident_id
    and (
      auth_role() in ('commander', 'admin')
      or (auth_role() = 'field_officer' and i.ward_id = auth_ward())
      or (
        incident_events.is_public
        and exists (select 1 from reports r where r.incident_id = i.id and r.reporter_id = auth.uid())
      )
    )
  )
);

-- Replaces the Phase 2 policy. Phase 2 used `for all` with an assignee carve-out,
-- which let an assignee INSERT arbitrary self-assigned missions (INSERT ignores
-- `using`). Split so assignees may only UPDATE the mission handed to them, while
-- creating missions stays a commander/admin action.
drop policy if exists evidence_missions_write on evidence_missions;
drop policy if exists evidence_missions_insert on evidence_missions;
create policy evidence_missions_insert on evidence_missions for insert with check (
  auth_role() in ('commander', 'admin')
);
drop policy if exists evidence_missions_update on evidence_missions;
create policy evidence_missions_update on evidence_missions for update using (
  auth_role() in ('commander', 'admin') or assigned_to = auth.uid()
) with check (
  auth_role() in ('commander', 'admin') or assigned_to = auth.uid()
);

-- Replaces the Phase 2 read policy, which granted any assignee SELECT on the
-- whole row. A citizen assignee could therefore read `rationale` — the internal
-- note that may name the responsible authority or enforcement intent — via the
-- API, even though no screen displays it. (Verified: the row was readable.)
--
-- Citizens now have NO direct read on this table; they go through
-- list_my_citizen_missions(), which returns only the citizen-safe columns.
-- Field officers keep full access to their own missions: they need the
-- rationale to do the job.
drop policy if exists evidence_missions_read on evidence_missions;
create policy evidence_missions_read on evidence_missions for select using (
  auth_role() in ('commander', 'admin')
  or (
    auth_role() = 'field_officer'
    and (
      assigned_to = auth.uid()
      or exists (
        select 1 from incidents i
        where i.id = evidence_missions.incident_id and i.ward_id = auth_ward()
      )
    )
  )
);

-- ============================================================
-- Evidence-level task rules (plan §9)
--
--   suspected           -> evidence-collection missions ONLY (no action task)
--   corroborated        -> inspection / preventive-action tasks allowed
--   officially_verified -> enforcement allowed, but ONLY with a recorded
--                          human approver (approved_by)
--
-- Enforced in the database so the rule holds regardless of which client writes.
-- Only fires when an action is attached to an incident, so the pre-existing
-- report-only action flow is completely unaffected.
-- ============================================================

create or replace function enforce_incident_action_rules() returns trigger
language plpgsql as $$
declare
  v_confidence source_confidence_level;
begin
  if new.incident_id is null then
    return new;  -- legacy report-scoped action: unchanged behaviour
  end if;

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

  -- Enforcement is never automatic: it needs an officially verified source AND
  -- a named human approver (plan §9, §14).
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

  return new;
end $$;

drop trigger if exists enforce_incident_action_rules_trg on actions;
create trigger enforce_incident_action_rules_trg
  before insert or update on actions
  for each row execute function enforce_incident_action_rules();

-- ============================================================
-- link_report_to_incident — the report -> incident match/create rule
--
-- Transparent and rule-based on purpose (no ML, per the Phase 3 brief). A
-- report joins an existing incident when ALL of these hold:
--
--   1. the incident is open (status <> 'closed')
--   2. same ward
--   3. detected within p_recency_hours (default 12h)
--   4. source category is compatible: the incident's leading hypothesis equals
--      the report's ai_category, OR either side has no category yet (the
--      classifier is async and may not have run — an unknown category must not
--      silently fabricate a match on a *different* known category)
--   5. within p_radius_m (default 750m) when BOTH have coordinates; when either
--      lacks coordinates, ward + recency + category is the fallback rule
--
-- Best candidate = closest when distances are known, else most recently detected.
-- Otherwise a new incident is created. Every outcome writes an incident_events
-- row. Returns the incident id.
--
-- Concurrency: a ward-scoped transaction advisory lock serialises concurrent
-- submissions in the same ward, so two reports describing one event cannot each
-- create an incident by racing past the other's SELECT.
--
-- Idempotent: a report that already has an incident_id is returned unchanged.
--
-- security definer because a citizen has no RLS rights to insert `incidents` or
-- update `reports.incident_id` (verified). The guard below is what keeps that
-- safe: the caller must own the report, or be staff.
-- ============================================================

create or replace function link_report_to_incident(
  p_report_id      bigint,
  p_recency_hours  int default 12,
  p_radius_m       int default 750
) returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_report       reports%rowtype;
  v_caller       uuid := auth.uid();
  v_caller_role  user_role;
  v_incident_id  bigint;
  v_match        bigint;
  v_created      boolean := false;
  v_excess       double precision;
  v_severity     text;
  v_distinct     int;
begin
  select * into v_report from reports where id = p_report_id;
  if not found then
    raise exception 'Report % not found', p_report_id;
  end if;

  -- Authorisation. security definer bypasses RLS, so this is the ONLY thing
  -- standing between a caller and someone else's report. Reporter, or staff.
  select role into v_caller_role from profiles where id = v_caller;
  if v_caller is null then
    raise exception 'Not authenticated';
  end if;
  if v_report.reporter_id is distinct from v_caller
     and coalesce(v_caller_role, 'citizen') not in ('field_officer', 'commander', 'admin') then
    raise exception 'Not authorised to link report %', p_report_id;
  end if;

  -- already linked -> idempotent no-op
  if v_report.incident_id is not null then
    return v_report.incident_id;
  end if;

  if v_report.ward_id is null then
    raise exception 'Report % has no ward; cannot place it on the incident map', p_report_id;
  end if;

  -- serialise per ward so concurrent reports cannot both create an incident
  perform pg_advisory_xact_lock(hashtext('incident_ward_' || v_report.ward_id));

  -- re-read after taking the lock: a concurrent call may have linked it
  select incident_id into v_incident_id from reports where id = p_report_id;
  if v_incident_id is not null then
    return v_incident_id;
  end if;

  -- ---- rule-based match ----
  select i.id into v_match
  from incidents i
  where i.status <> 'closed'
    and i.ward_id = v_report.ward_id
    and i.detected_at >= now() - make_interval(hours => p_recency_hours)
    -- category compatibility (rule 4)
    and (
      v_report.ai_category is null
      or not exists (select 1 from incident_source_hypotheses h where h.incident_id = i.id)
      or exists (
        select 1 from incident_source_hypotheses h
        where h.incident_id = i.id and h.source_category = v_report.ai_category
      )
    )
    -- proximity (rule 5): only applied when both sides have coordinates
    and (
      v_report.lat is null or v_report.lng is null or i.lat is null or i.lng is null
      or (
        -- equirectangular approximation: accurate to well under a metre at the
        -- few-hundred-metre scale this rule operates on, and index-friendly.
        6371000 * sqrt(
          pow(radians(i.lat - v_report.lat), 2) +
          pow(radians(i.lng - v_report.lng) * cos(radians((i.lat + v_report.lat) / 2)), 2)
        ) <= p_radius_m
      )
    )
  order by
    -- closest first when both have coordinates, else most recent
    case
      when v_report.lat is null or v_report.lng is null or i.lat is null or i.lng is null then 1
      else 0
    end,
    case
      when v_report.lat is null or v_report.lng is null or i.lat is null or i.lng is null then null
      else 6371000 * sqrt(
        pow(radians(i.lat - v_report.lat), 2) +
        pow(radians(i.lng - v_report.lng) * cos(radians((i.lat + v_report.lat) / 2)), 2)
      )
    end asc nulls last,
    i.detected_at desc
  limit 1;

  if v_match is not null then
    v_incident_id := v_match;
  else
    -- ---- no match: create one ----
    -- severity snapshot from the ward's latest forecast local excess. Left NULL
    -- when no forecast exists — an unknown severity is shown as unavailable,
    -- never defaulted to 'low'.
    select f.local_excess into v_excess
    from forecasts f
    where f.ward_id = v_report.ward_id and f.local_excess is not null
    order by f.generated_at desc, f.horizon_ts asc
    limit 1;

    v_severity := case
      when v_excess is null then null
      when v_excess >= 100 then 'severe'
      when v_excess >= 50  then 'high'
      when v_excess >= 20  then 'moderate'
      else 'low'
    end;

    insert into incidents (
      city_id, ward_id, status, detection_method, source_confidence,
      lat, lng, summary, local_excess, severity, primary_pollutant, created_by
    )
    values (
      (select city_id from wards where id = v_report.ward_id),
      v_report.ward_id,
      'detected',
      'citizen_report_cluster',
      'suspected',
      v_report.lat, v_report.lng,
      coalesce(nullif(trim(v_report.description), ''), 'Citizen-reported pollution source'),
      v_excess, v_severity,
      'pm25',
      v_report.reporter_id
    )
    returning id into v_incident_id;
    v_created := true;

    insert into incident_events (incident_id, event_type, actor_id, note, is_public, payload)
    values (
      v_incident_id, 'created', v_report.reporter_id,
      'Incident opened from a citizen report.', true,
      jsonb_build_object('report_id', p_report_id, 'detection_method', 'citizen_report_cluster')
    );
  end if;

  -- ---- link the report + record it as evidence ----
  update reports set incident_id = v_incident_id where id = p_report_id;

  insert into incident_evidence (
    incident_id, evidence_type, report_id, supports, confidence, collected_by, collected_at, payload
  )
  values (
    v_incident_id, 'citizen_report', p_report_id, true,
    -- the classifier's own confidence, when it ran; never invented
    nullif((v_report.ai_meta ->> 'confidence'), '')::double precision,
    v_report.reporter_id, coalesce(v_report.created_at, now()),
    jsonb_build_object('ai_category', v_report.ai_category, 'matched', not v_created)
  );

  if not v_created then
    insert into incident_events (incident_id, event_type, actor_id, note, is_public, payload)
    values (
      v_incident_id, 'evidence_added', v_report.reporter_id,
      'Another citizen report was linked to this incident.', true,
      jsonb_build_object('report_id', p_report_id)
    );
  end if;

  -- ---- rebuild source hypotheses from the linked reports (transparent count rule) ----
  -- probability = share of linked, classified reports naming that category.
  -- This is a stated counting rule, not a model: model_version records that.
  if v_report.ai_category is not null then
    delete from incident_source_hypotheses
      where incident_id = v_incident_id and model_version = 'report_vote_v1';

    insert into incident_source_hypotheses (
      incident_id, source_category, probability, confidence_level, rationale, model_version
    )
    select
      v_incident_id,
      r.ai_category,
      count(*)::double precision / nullif(sum(count(*)) over (), 0),
      'suspected',
      count(*) || ' of ' || sum(count(*)) over () || ' linked citizen reports name this source category.',
      'report_vote_v1'
    from reports r
    where r.incident_id = v_incident_id and r.ai_category is not null
    group by r.ai_category;
  end if;

  -- ---- evidence-level rule: suspected -> corroborated ----
  -- Requires >= 2 reports from DIFFERENT reporters agreeing on the category:
  -- "multiple independent signals" (plan §9). One person reporting twice is not
  -- independent corroboration.
  select count(distinct r.reporter_id) into v_distinct
  from reports r
  where r.incident_id = v_incident_id
    and r.ai_category is not null
    and r.ai_category = v_report.ai_category;

  if v_distinct >= 2 then
    update incidents
      set source_confidence = 'corroborated', updated_at = now()
      where id = v_incident_id and source_confidence = 'suspected';

    -- Announce the upgrade only the first time (`found` = the row actually moved
    -- from suspected), so a later report does not re-announce it...
    if found then
      insert into incident_events (incident_id, event_type, actor_id, note, is_public, payload)
      values (
        v_incident_id, 'hypothesis_updated', v_report.reporter_id,
        'Independent reports from multiple people now corroborate the suspected source.',
        true,
        jsonb_build_object('distinct_reporters', v_distinct, 'rule', 'two_independent_reports_v1')
      );
    end if;

    -- ...but ALWAYS re-sync the hypothesis row. The rebuild above re-creates
    -- hypotheses at 'suspected', so if this stayed inside `if found` a later
    -- report would silently downgrade the displayed evidence level below the
    -- incident's own source_confidence.
    update incident_source_hypotheses
      set confidence_level = (select source_confidence from incidents where id = v_incident_id)
      where incident_id = v_incident_id and source_category = v_report.ai_category;
  end if;

  update incidents set updated_at = now() where id = v_incident_id;
  return v_incident_id;
end $$;

revoke all on function link_report_to_incident(bigint, int, int) from public;
grant execute on function link_report_to_incident(bigint, int, int) to authenticated;

-- ============================================================
-- list_assignable_officers — who a commander may hand a mission to.
--
-- Needed because the baseline `profiles_self_read` policy lets a user read only
-- their OWN profile (admin excepted), so a commander querying `profiles`
-- correctly gets zero rows — verified. Without this, an evidence mission could
-- never be assigned to anyone and the field half of the workflow is dead.
--
-- Deliberately a narrow security-definer function rather than a wider RLS policy
-- on `profiles`: this returns ONLY id/full_name/ward for field officers, so
-- commanders never gain access to phone numbers or other users' details. The
-- role check is inside the function because security definer bypasses RLS.
-- ============================================================
create or replace function list_assignable_officers(p_ward_id int default null)
returns table (id uuid, full_name text, ward_id int)
language sql stable security definer set search_path = public as $$
  select p.id, p.full_name, p.ward_id
  from profiles p
  where p.role = 'field_officer'
    and (p_ward_id is null or p.ward_id = p_ward_id)
    and (select role from profiles me where me.id = auth.uid()) in ('commander', 'admin')
  order by p.full_name nulls last
$$;

revoke all on function list_assignable_officers(int) from public;
grant execute on function list_assignable_officers(int) to authenticated;

-- ============================================================
-- Citizen verification: a deliberately narrow pair of functions.
--
-- Citizens have no direct SELECT/UPDATE path to evidence_missions (see the read
-- policy above). These two functions are the entire citizen surface, and they
-- expose only what a citizen needs:
--   * the question we are asking (public_prompt), never the internal rationale
--   * enough context (leading source category, severity) for the client to apply
--     the safety rule — both are things we would tell the public anyway
-- ============================================================

create or replace function list_my_citizen_missions()
returns table (
  mission_id       bigint,
  incident_id      bigint,
  mission_type     text,
  status           mission_status,
  public_prompt    text,
  outcome          text,
  incident_status  incident_status,
  ward_name        text,
  leading_category source_category,
  severity         text
)
language sql stable security definer set search_path = public as $$
  select
    m.id, m.incident_id, m.mission_type, m.status, m.public_prompt, m.outcome,
    i.status, w.name,
    (select h.source_category
       from incident_source_hypotheses h
      where h.incident_id = i.id
      order by h.probability desc
      limit 1),
    i.severity
  from evidence_missions m
  join incidents i on i.id = m.incident_id
  left join wards w on w.id = i.ward_id
  where m.assigned_to = auth.uid()
    and m.mission_type = 'citizen_verification'
  order by m.created_at desc
$$;

revoke all on function list_my_citizen_missions() from public;
grant execute on function list_my_citizen_missions() to authenticated;

-- Record a citizen's answer.
--
-- Note what this does NOT do: it never touches incidents.source_confidence.
-- Citizen evidence supports prioritisation and verification but cannot
-- establish a source or a violation on its own (plan §11) — only an authorised
-- officer can, which is why that path lives in the field flow instead.
create or replace function submit_citizen_verification(
  p_mission_id bigint,
  p_outcome    text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_m evidence_missions%rowtype;
begin
  if p_outcome not in ('confirmed', 'rejected', 'unresolved') then
    raise exception 'Invalid outcome "%"', p_outcome;
  end if;

  select * into v_m from evidence_missions where id = p_mission_id;
  if not found then
    raise exception 'Mission % not found', p_mission_id;
  end if;

  -- security definer bypasses RLS: these checks are the whole guard.
  if v_m.assigned_to is distinct from auth.uid() then
    raise exception 'This verification request is not addressed to you';
  end if;
  if v_m.mission_type <> 'citizen_verification' then
    raise exception 'Mission % is not a citizen verification request', p_mission_id;
  end if;
  if v_m.status in ('completed', 'cancelled') then
    raise exception 'This verification request is already closed';
  end if;

  update evidence_missions
     set status             = 'completed',
         outcome            = p_outcome,
         checklist_response = jsonb_build_object('citizen_answer', p_outcome),
         completed_at       = now()
   where id = p_mission_id;

  insert into incident_evidence (incident_id, evidence_type, supports, collected_by, payload)
  values (
    v_m.incident_id,
    'citizen_report',
    case p_outcome when 'confirmed' then true when 'rejected' then false else null end,
    auth.uid(),
    jsonb_build_object('mission_id', p_mission_id, 'citizen_answer', p_outcome, 'authorised_officer', false)
  );

  insert into incident_events (incident_id, event_type, actor_id, note, is_public, payload)
  values (
    v_m.incident_id, 'evidence_added', auth.uid(),
    'A citizen answered a verification request.', true,
    jsonb_build_object('citizen_answer', p_outcome)
  );
end $$;

revoke all on function submit_citizen_verification(bigint, text) from public;
grant execute on function submit_citizen_verification(bigint, text) to authenticated;
