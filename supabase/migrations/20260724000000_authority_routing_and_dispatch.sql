-- ============================================================
-- authority_routing_and_dispatch — additive migration (Phase 9, vertical slice)
--
-- Turns an approved intervention into a correctly routed, trackable and
-- escalatable operational task. Nothing here is destructive:
--
--   * `responsibility_registry` (Phase 2) gains additive columns only —
--     team/backup routing, structured contact channels, supported
--     intervention types, working hours, an escalation hierarchy,
--     active/inactive status, and mapping confidence/source. Existing rows
--     (the Phase 7 Delhi seed) keep working unchanged; the new columns
--     default to honest "not yet specified" values, never guessed ones.
--   * `task_dispatches` (new table) is the operational envelope around an
--     `actions` row — routing decision, approval, notification/SLA
--     tracking, escalation — kept as a SEPARATE concept from
--     `actions.workflow_status` (Phase 4, unchanged), which continues to
--     own the intervention's own operational/outcome state exactly as
--     before. The two are kept in sync for the states they share
--     (accepted/in_progress/completed) by the functions in this file, not
--     by two independently-writable copies.
--   * `sla_rules` (new table) makes SLA timing configurable by city,
--     severity, source category, evidence level, action type, agency and
--     time of day — never one fixed SLA for every incident.
--   * `notifications` (new table) is a provider-agnostic delivery queue —
--     `ingest/app/notifications.py` (new) polls it and attempts delivery
--     via a pluggable adapter (in-app is a no-op "already delivered" write;
--     email uses a real adapter if SMTP is configured, else an explicit,
--     honestly-labelled dev-mock; SMS/WhatsApp have an adapter INTERFACE
--     only, never a fake "delivered").
--   * Three new atomic, server-side functions —
--     `dispatch_intervention_task`, `transition_task_dispatch`,
--     `escalate_stale_task_dispatches` — are the ONLY way `task_dispatches`
--     rows are ever created or change status. No RLS policy grants any
--     role direct INSERT/UPDATE on `task_dispatches` at all (mirroring
--     Phase 5.1/6/7's own "the function is the only write path" pattern) —
--     "prefer server-side atomic functions for dispatch and lifecycle
--     transitions" is therefore structural, not a convention someone could
--     accidentally bypass with a raw client update.
--
-- No existing table, column, row, or policy is altered or dropped.
--
-- Idempotent: safe to re-run and safe via `supabase db push`.
-- See docs/DATA_MODEL.md and docs/ROLE_WORKFLOWS.md.
-- ============================================================

-- ---------- enums ----------
do $$ begin
  create type task_dispatch_status as enum (
    'drafted', 'awaiting_approval', 'approved', 'routed', 'sent', 'acknowledged',
    'accepted', 'in_progress', 'completed', 'verification_pending',
    'overdue', 'escalated', 'rejected', 'rerouted', 'cancelled'
  );
exception when duplicate_object then null;
end $$;

do $$ begin
  create type routing_confidence_level as enum ('confirmed', 'probable', 'disputed', 'unresolved');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type notification_channel as enum ('in_app', 'email', 'sms', 'whatsapp');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type notification_status as enum ('pending', 'sent', 'delivered', 'failed', 'acknowledged');
exception when duplicate_object then null;
end $$;

-- ---------- responsibility_registry: additive routing detail (plan §2) ----------
-- "Route to the most specific available operational unit, not just a broad
-- agency name" — team_name/backup_*/escalation_hierarchy are what make a
-- specific unit (not just "PWD") representable at all.
alter table responsibility_registry add column if not exists team_name              text;
alter table responsibility_registry add column if not exists backup_agency         text;
alter table responsibility_registry add column if not exists backup_team           text;
alter table responsibility_registry add column if not exists backup_officer        uuid references profiles(id);
alter table responsibility_registry add column if not exists zone_description      text;
alter table responsibility_registry add column if not exists contact_channel       jsonb not null default '{}'::jsonb;
alter table responsibility_registry add column if not exists supported_intervention_types text[] not null default '{}';
alter table responsibility_registry add column if not exists working_hours         jsonb;
-- Ordered array of escalation steps beyond the primary officer/team, e.g.
-- [{"level":1,"role":"supervisor","contact":"..."},
--  {"level":2,"role":"agency_command","contact":"..."},
--  {"level":3,"role":"city_command_centre","contact":"..."}]
-- — the literal plan §8 escalation path, made data instead of code so a
-- city can define its own without a deployment.
alter table responsibility_registry add column if not exists escalation_hierarchy  jsonb not null default '[]'::jsonb;
alter table responsibility_registry add column if not exists is_active             boolean not null default true;
-- "Confidence AND SOURCE of mapping" — distinct from is_disputed (a
-- jurisdictional conflict) and from routing_confidence_level (computed per
-- dispatch): this is how sure the REGISTRY ROW ITSELF is, at data-entry time.
alter table responsibility_registry add column if not exists mapping_confidence    text not null default 'estimated'
  check (mapping_confidence in ('verified', 'estimated', 'legacy'));
alter table responsibility_registry add column if not exists mapping_source        text;
create index if not exists responsibility_registry_active_idx on responsibility_registry (city_id, is_active);

-- ---------- task_dispatches: the operational envelope around an action ----------
create table if not exists task_dispatches (
  id                          bigserial primary key,
  action_id                   bigint not null references actions(id) on delete cascade,
  incident_id                 bigint references incidents(id) on delete cascade,
  city_id                     int references city_config(id),
  ward_id                     int references wards(id),
  registry_id                 bigint references responsibility_registry(id),

  -- ---- routing (plan §1/§3) ----
  routing_confidence          routing_confidence_level not null default 'unresolved',
  -- Named-factor breakdown of WHY this routing was chosen (or wasn't) —
  -- "every routing decision must record its evidence", the same
  -- transparency discipline `incident_source_hypotheses.evidence_scores`
  -- (Phase 7) already established for attribution.
  routing_evidence            jsonb not null default '{}'::jsonb,
  physical_location           text,
  asset_description           text,
  responsible_agency          text,
  division_zone               text,
  primary_officer             uuid references profiles(id),
  primary_team                text,
  backup_agency                text,
  backup_team                  text,

  -- ---- lifecycle (plan §4) ----
  status                      task_dispatch_status not null default 'drafted',
  requires_approval           boolean not null default false,
  approved_by                 uuid references profiles(id),
  approved_at                  timestamptz,
  routed_at                   timestamptz,
  sent_at                     timestamptz,
  acknowledged_at             timestamptz,
  accepted_at                  timestamptz,
  arrived_at                  timestamptz,
  started_at                  timestamptz,
  completed_at                 timestamptz,
  verification_requested_at    timestamptz,
  verified_at                  timestamptz,

  -- ---- SLA (plan §7) — per-stage deadlines, computed from sla_rules at
  -- dispatch time, so "time to X" is always measurable against a stated
  -- target, never an unstated one-size-fits-all number ----
  sla_ack_due_at               timestamptz,
  sla_accept_due_at            timestamptz,
  sla_arrival_due_at           timestamptz,
  sla_completion_due_at        timestamptz,
  sla_verification_due_at      timestamptz,

  -- ---- escalation (plan §8) ----
  escalation_level             int not null default 0,
  escalated_at                  timestamptz,
  escalation_reason            text,

  -- ---- reasons (plan §10: "reason for rejection or rerouting") ----
  rejection_reason             text,
  reroute_reason                text,
  cancellation_reason           text,
  dispute_resolution_note       text,

  -- ---- resource awareness (plan §9) — never invented ----
  resource_availability         text not null default 'unknown'
    check (resource_availability in ('available', 'unavailable', 'unknown')),
  resource_note                 text,

  -- Versioned like `incident_source_hypotheses`/Phase 5.1's recurrence
  -- reports: a reroute supersedes the current dispatch with a NEW row
  -- rather than mutating history away — `is_current` + a partial unique
  -- index is the structural "one active dispatch per action" guarantee.
  is_current                    boolean not null default true,
  superseded_by_dispatch_id     bigint references task_dispatches(id),

  created_by                    uuid references profiles(id),
  created_at                    timestamptz not null default now(),
  updated_at                    timestamptz not null default now()
);
create unique index if not exists task_dispatches_one_current_per_action
  on task_dispatches (action_id) where is_current;
create index if not exists task_dispatches_incident_idx on task_dispatches (incident_id);
create index if not exists task_dispatches_ward_idx on task_dispatches (ward_id, status);
create index if not exists task_dispatches_officer_idx on task_dispatches (primary_officer, status);
create index if not exists task_dispatches_sla_idx on task_dispatches (status, sla_ack_due_at, sla_accept_due_at, sla_arrival_due_at, sla_completion_due_at);

-- ---------- sla_rules: configurable by city/severity/source/evidence/type/agency/time (plan §7) ----------
create table if not exists sla_rules (
  id                  bigserial primary key,
  -- Stable natural key so the Delhi seed below is genuinely idempotent —
  -- same reasoning as intervention_playbooks.slug (Phase 5): a bare
  -- `bigserial id` can't back `on conflict do nothing`. Nullable so a
  -- future admin-created rule (via the Operations panel) needs no slug.
  slug                text,
  city_id             int references city_config(id),
  severity            text check (severity is null or severity in ('low', 'moderate', 'high', 'severe')),
  source_category     source_category,
  evidence_level      source_confidence_level,
  action_type         text,
  agency              text,
  time_of_day         text check (time_of_day is null or time_of_day in ('business_hours', 'after_hours')),
  ack_hours           numeric not null default 2,
  accept_hours        numeric not null default 4,
  arrival_hours       numeric not null default 8,
  completion_hours    numeric not null default 24,
  verification_hours  numeric not null default 72,
  -- Explicit specificity ranking rather than a computed "how many columns
  -- match" score — a stated, city-editable priority, not a hidden formula.
  priority             int not null default 0,
  is_active            boolean not null default true,
  created_at           timestamptz not null default now()
);
create index if not exists sla_rules_lookup_idx on sla_rules (city_id, is_active, priority desc);
do $$ begin
  alter table sla_rules add constraint sla_rules_slug_key unique (slug);
-- Same duplicate_table caveat as intervention_playbooks_slug_key: a UNIQUE
-- constraint's backing index collides as duplicate_table (42P07) on rerun,
-- not duplicate_object (42710) — both must be caught.
exception when duplicate_object or duplicate_table then null;
end $$;

-- ---------- notifications: provider-agnostic delivery queue (plan §6) ----------
create table if not exists notifications (
  id                bigserial primary key,
  task_dispatch_id  bigint references task_dispatches(id) on delete cascade,
  recipient_id      uuid references profiles(id),
  -- Set when the recipient has no profile on file for this channel yet
  -- (e.g. an external agency contact) — never fabricated from nothing.
  recipient_contact text,
  channel           notification_channel not null,
  template_key      text not null,
  message_body      text not null,
  status            notification_status not null default 'pending',
  sent_at           timestamptz,
  delivered_at      timestamptz,
  acknowledged_at   timestamptz,
  failure_reason    text,
  retry_count       int not null default 0,
  created_at        timestamptz not null default now()
);
create index if not exists notifications_pending_idx on notifications (status, created_at) where status = 'pending';
create index if not exists notifications_recipient_idx on notifications (recipient_id, created_at desc);

-- ============================================================
-- Row Level Security
-- ============================================================
alter table task_dispatches enable row level security;
alter table sla_rules       enable row level security;
alter table notifications   enable row level security;

-- task_dispatches: commander/admin (all), field_officer (own ward, OR
-- assigned to them personally regardless of ward — matches
-- listInterventionsForOfficer's own "assignee sees it even outside a
-- ward-scoped read" precedent). Citizens: NO policy at all — internal
-- routing/officer detail, same posture as `actions`/`anomaly_candidates`.
drop policy if exists task_dispatches_read on task_dispatches;
create policy task_dispatches_read on task_dispatches for select using (
  auth_role() in ('commander', 'admin')
  or primary_officer = auth.uid()
  or (auth_role() = 'field_officer' and ward_id = auth_ward())
);
-- No INSERT/UPDATE/DELETE policy for any authenticated role, on purpose —
-- every write goes through dispatch_intervention_task/
-- transition_task_dispatch (SECURITY DEFINER), which enforce the lifecycle
-- and authorization themselves. This is the literal mechanism behind
-- "prefer server-side atomic functions for dispatch and lifecycle
-- transitions" — there is no other way in.

drop policy if exists sla_rules_read on sla_rules;
create policy sla_rules_read on sla_rules for select using (
  auth_role() in ('field_officer', 'commander', 'admin')
);
drop policy if exists sla_rules_write on sla_rules;
create policy sla_rules_write on sla_rules for all using (
  auth_role() in ('commander', 'admin')
) with check (
  auth_role() in ('commander', 'admin')
);

-- notifications: a recipient reads their own; commander/admin read all
-- (operational visibility — delivery/ack status is exactly what the
-- Operations panel needs to show). No citizen read at all.
drop policy if exists notifications_read on notifications;
create policy notifications_read on notifications for select using (
  auth_role() in ('commander', 'admin')
  or recipient_id = auth.uid()
);
-- Writes go through the dispatch functions (creation) and
-- ingest/app/notifications.py's service_role connection (delivery status
-- updates) — no authenticated write policy, same posture as
-- forecast_runs/readings/weather.

-- ============================================================
-- _resolve_task_routing — shared routing-matching logic (plan §1/§3).
-- Not itself a public RPC (no grants) — an internal helper both the
-- dispatch function and the read-only preview function call, so the exact
-- same matching rule always produces the exact same answer.
--
-- Match: the incident's leading source hypothesis (if any) + ward, against
-- `responsibility_registry` rows for the same city. A ward-specific,
-- verified, non-disputed match is 'confirmed'. A city-wide (no ward) or
-- non-verified match is 'probable'. A matched row with is_disputed=true is
-- 'disputed'. No match at all is 'unresolved'.
-- ============================================================
create or replace function _resolve_task_routing(p_action_id bigint)
returns table (
  registry_id            bigint,
  routing_confidence     routing_confidence_level,
  routing_evidence       jsonb,
  physical_location      text,
  asset_description      text,
  responsible_agency     text,
  division_zone          text,
  primary_officer        uuid,
  primary_team           text,
  backup_agency          text,
  backup_team            text
)
language plpgsql stable as $$
declare
  v_action        actions%rowtype;
  v_incident      incidents%rowtype;
  v_category      source_category;
  v_reg           responsibility_registry%rowtype;
  v_ward_match    boolean := false;
begin
  select * into v_action from actions where id = p_action_id;
  if v_action.incident_id is null then
    return; -- legacy, report-scoped action: routing does not apply
  end if;
  select * into v_incident from incidents where id = v_action.incident_id;

  select h.source_category into v_category
  from incident_source_hypotheses h
  where h.incident_id = v_incident.id and h.is_current
  order by h.probability desc
  limit 1;

  -- Prefer a ward-specific, active, matching-category registry row; fall
  -- back to a city-wide one (ward_id is null); a matching agency's own
  -- `supported_intervention_types` narrows further when populated (an
  -- empty array means "not yet specified" — never treated as "supports
  -- nothing", which would make every real row invisible until someone
  -- fills this in).
  select r.* into v_reg
  from responsibility_registry r
  where r.city_id = v_incident.city_id
    and r.is_active
    and (r.source_category is null or r.source_category = v_category)
    and (r.ward_id is null or r.ward_id = v_incident.ward_id)
    and (
      cardinality(r.supported_intervention_types) = 0
      or v_action.type = any (r.supported_intervention_types)
    )
  order by
    (r.ward_id = v_incident.ward_id) desc,          -- ward-specific first
    (r.source_category = v_category) desc,          -- exact category next
    (r.mapping_confidence = 'verified') desc,        -- verified over estimated/legacy
    r.updated_at desc
  limit 1;

  if v_reg.id is null then
    registry_id := null;
    routing_confidence := 'unresolved';
    routing_evidence := jsonb_build_object(
      'reason', 'No active responsibility_registry entry matches this incident''s source category and ward.',
      'source_category', v_category, 'ward_id', v_incident.ward_id
    );
    return next;
    return;
  end if;

  v_ward_match := (v_reg.ward_id = v_incident.ward_id);

  registry_id := v_reg.id;
  physical_location := coalesce(v_incident.summary, v_reg.zone_description);
  asset_description := v_reg.asset_description;
  responsible_agency := v_reg.regulating_authority;
  division_zone := v_reg.division_zone;
  primary_officer := v_reg.responsible_officer;
  primary_team := v_reg.team_name;
  backup_agency := v_reg.backup_agency;
  backup_team := v_reg.backup_team;

  routing_evidence := jsonb_build_object(
    'matched_registry_id', v_reg.id,
    'ward_match', v_ward_match,
    'category_match', v_reg.source_category = v_category,
    'mapping_confidence', v_reg.mapping_confidence,
    'mapping_source', v_reg.mapping_source,
    'is_disputed', v_reg.is_disputed
  );

  routing_confidence := case
    when v_reg.is_disputed then 'disputed'
    when v_ward_match and v_reg.mapping_confidence = 'verified' then 'confirmed'
    else 'probable'
  end;

  return next;
end $$;

-- ============================================================
-- preview_task_routing — read-only routing preview for the command UI,
-- BEFORE committing to a dispatch. Same matching logic as the dispatch
-- function itself (calls the same internal helper) so the preview a
-- commander sees is never a different answer from what dispatch actually
-- does.
-- ============================================================
create or replace function preview_task_routing(p_action_id bigint)
returns table (
  registry_id            bigint,
  routing_confidence     routing_confidence_level,
  routing_evidence       jsonb,
  physical_location      text,
  asset_description      text,
  responsible_agency     text,
  division_zone          text,
  primary_officer        uuid,
  primary_team           text,
  backup_agency          text,
  backup_team            text
)
language sql stable security definer set search_path = public as $$
  select * from _resolve_task_routing(p_action_id)
$$;

revoke all on function preview_task_routing(bigint) from public;
grant execute on function preview_task_routing(bigint) to authenticated;

-- ============================================================
-- dispatch_intervention_task — the atomic create-or-update entry point
-- (plan §1/§5/§14: "prefer server-side atomic functions for dispatch").
--
-- Idempotent: calling this again for an action with an existing `is_current`
-- dispatch UPDATES it (re-resolves routing, re-checks approval) rather than
-- creating a duplicate — "duplicate dispatch is prevented" is therefore
-- structural (the partial unique index), not just a check in this function.
-- ============================================================
create or replace function dispatch_intervention_task(
  p_action_id bigint,
  p_actor_id  uuid
) returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_caller_role      user_role;
  v_action           actions%rowtype;
  v_incident         incidents%rowtype;
  v_config           jsonb;
  v_approval_types   text[];
  v_route            record;
  v_requires_approval boolean;
  v_dispatch_id      bigint;
  v_status           task_dispatch_status;
  v_sla              record;
  v_now              timestamptz := now();
begin
  select role into v_caller_role from profiles where id = p_actor_id;
  if coalesce(v_caller_role, 'citizen') not in ('commander', 'admin') then
    raise exception 'Only a commander or admin may dispatch an intervention task.'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_action from actions where id = p_action_id;
  if not found then
    raise exception 'Action % not found', p_action_id;
  end if;
  if v_action.incident_id is null then
    raise exception 'Action % is not incident-linked; dispatch does not apply to legacy report-scoped actions', p_action_id;
  end if;
  select * into v_incident from incidents where id = v_action.incident_id;

  select coalesce(config, '{}'::jsonb) into v_config from city_config where id = v_incident.city_id;
  v_approval_types := array(
    select jsonb_array_elements_text(
      coalesce(v_config -> 'dispatch' -> 'requires_approval_types',
               '["penalty","stop_work","closure","restriction","prosecution","sprinkle"]'::jsonb)
    )
  );
  v_requires_approval := v_action.type = any (v_approval_types);

  select * into v_route from _resolve_task_routing(p_action_id);

  -- ---- status decision (plan §3/§5) ----
  if v_requires_approval and v_action.approved_by is null then
    v_status := 'awaiting_approval';
  elsif v_route.routing_confidence = 'unresolved' then
    -- "unresolved routing must not silently dispatch" — stays drafted,
    -- flagged, never advances on its own.
    v_status := 'drafted';
  elsif v_route.routing_confidence = 'disputed' then
    -- "disputed cases should go to command review" — same state as
    -- awaiting approval (a human must look at it), distinguishable via
    -- routing_confidence itself.
    v_status := 'awaiting_approval';
  else
    v_status := 'routed';
  end if;

  -- ---- SLA (plan §7): most specific matching rule wins ----
  select * into v_sla
  from sla_rules
  where is_active
    and (city_id is null or city_id = v_incident.city_id)
    and (severity is null or severity = v_incident.severity)
    and (source_category is null or source_category = (
      select h.source_category from incident_source_hypotheses h
      where h.incident_id = v_incident.id and h.is_current order by h.probability desc limit 1
    ))
    and (evidence_level is null or evidence_level = v_incident.source_confidence)
    and (action_type is null or action_type = v_action.type)
    and (agency is null or agency = v_route.responsible_agency)
  order by priority desc
  limit 1;
  -- documented fallback when no rule matches at all — never leave a
  -- dispatch with no SLA target.
  if v_sla.id is null then
    v_sla.ack_hours := 2; v_sla.accept_hours := 4; v_sla.arrival_hours := 8;
    v_sla.completion_hours := 24; v_sla.verification_hours := 72;
  end if;

  -- ---- idempotent create-or-update ----
  select id into v_dispatch_id from task_dispatches where action_id = p_action_id and is_current;

  if v_dispatch_id is null then
    insert into task_dispatches (
      action_id, incident_id, city_id, ward_id, registry_id,
      routing_confidence, routing_evidence, physical_location, asset_description,
      responsible_agency, division_zone, primary_officer, primary_team, backup_agency, backup_team,
      status, requires_approval, approved_by, approved_at, routed_at,
      sla_ack_due_at, sla_accept_due_at, sla_arrival_due_at, sla_completion_due_at, sla_verification_due_at,
      created_by
    ) values (
      p_action_id, v_incident.id, v_incident.city_id, v_incident.ward_id, v_route.registry_id,
      v_route.routing_confidence, v_route.routing_evidence, v_route.physical_location, v_route.asset_description,
      v_route.responsible_agency, v_route.division_zone, v_route.primary_officer, v_route.primary_team, v_route.backup_agency, v_route.backup_team,
      v_status, v_requires_approval, v_action.approved_by, v_action.approved_at, case when v_status = 'routed' then v_now else null end,
      v_now + (v_sla.ack_hours * interval '1 hour'), v_now + (v_sla.accept_hours * interval '1 hour'),
      v_now + (v_sla.arrival_hours * interval '1 hour'), v_now + (v_sla.completion_hours * interval '1 hour'),
      v_now + (v_sla.verification_hours * interval '1 hour'),
      p_actor_id
    ) returning id into v_dispatch_id;
  else
    update task_dispatches set
      registry_id = v_route.registry_id, routing_confidence = v_route.routing_confidence,
      routing_evidence = v_route.routing_evidence, physical_location = v_route.physical_location,
      asset_description = v_route.asset_description, responsible_agency = v_route.responsible_agency,
      division_zone = v_route.division_zone, primary_officer = v_route.primary_officer,
      primary_team = v_route.primary_team, backup_agency = v_route.backup_agency, backup_team = v_route.backup_team,
      status = v_status, requires_approval = v_requires_approval,
      approved_by = v_action.approved_by, approved_at = v_action.approved_at,
      routed_at = case when v_status = 'routed' and routed_at is null then v_now else routed_at end,
      updated_at = v_now
    where id = v_dispatch_id;
  end if;

  insert into incident_events (incident_id, event_type, actor_id, note, is_public, payload)
  values (
    v_incident.id, 'routing_decision', p_actor_id,
    format('Routing resolved as %s%s.', v_route.routing_confidence,
      case when v_route.responsible_agency is not null then format(' — %s', v_route.responsible_agency) else '' end),
    false,
    jsonb_build_object('task_dispatch_id', v_dispatch_id, 'routing_confidence', v_route.routing_confidence, 'registry_id', v_route.registry_id)
  );

  if v_status = 'routed' then
    perform _send_task_notification(v_dispatch_id, v_route.primary_officer, 'task_routed',
      format('A %s intervention has been routed to you.', v_action.type));
    update task_dispatches set status = 'sent', sent_at = v_now, updated_at = v_now where id = v_dispatch_id;
    insert into incident_events (incident_id, event_type, actor_id, note, is_public, payload)
      values (v_incident.id, 'dispatch', p_actor_id, 'Intervention dispatched to the responsible unit.', true,
        jsonb_build_object('task_dispatch_id', v_dispatch_id));
  end if;

  return v_dispatch_id;
end $$;

revoke all on function dispatch_intervention_task(bigint, uuid) from public;
grant execute on function dispatch_intervention_task(bigint, uuid) to authenticated;

-- ============================================================
-- _send_task_notification — internal helper: creates the in-app
-- notification row (always) and, when the recipient has an email on file,
-- a queued email notification row too. Actual delivery is
-- ingest/app/notifications.py's job (polls `status = 'pending'`); this
-- function only ever queues, never claims delivery itself.
-- ============================================================
create or replace function _send_task_notification(
  p_dispatch_id bigint,
  p_recipient   uuid,
  p_template    text,
  p_message     text
) returns void
language plpgsql as $$
declare v_email text;
begin
  if p_recipient is null then
    return; -- unresolved routing has no one to notify yet — never invented
  end if;

  insert into notifications (task_dispatch_id, recipient_id, channel, template_key, message_body, status)
  values (p_dispatch_id, p_recipient, 'in_app', p_template, p_message, 'pending');

  select email into v_email from profiles p join auth.users u on u.id = p.id where p.id = p_recipient;
  -- profiles has no email column of its own; auth.users.email is the real
  -- contact address Supabase already manages — read it, never guessed.
  if v_email is not null then
    insert into notifications (task_dispatch_id, recipient_id, recipient_contact, channel, template_key, message_body, status)
    values (p_dispatch_id, p_recipient, v_email, 'email', p_template, p_message, 'pending');
  end if;
end $$;

-- ============================================================
-- transition_task_dispatch — the ONLY way a dispatch's status ever
-- changes (plan §4/§14). A stated, enforced from->to table; anything not
-- explicitly listed is refused, not silently allowed.
-- ============================================================
create or replace function transition_task_dispatch(
  p_dispatch_id bigint,
  p_new_status  task_dispatch_status,
  p_actor_id    uuid,
  p_reason      text default null
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_d              task_dispatches%rowtype;
  v_caller_role    user_role;
  v_is_officer     boolean;
  v_allowed        boolean := false;
  v_now            timestamptz := now();
begin
  select * into v_d from task_dispatches where id = p_dispatch_id and is_current;
  if not found then
    raise exception 'Task dispatch % not found (or no longer current)', p_dispatch_id;
  end if;

  select role into v_caller_role from profiles where id = p_actor_id;
  v_is_officer := (v_d.primary_officer = p_actor_id);

  -- ---- transition table ----
  v_allowed := case v_d.status
    when 'drafted'              then p_new_status in ('awaiting_approval', 'routed', 'cancelled')
    when 'awaiting_approval'    then p_new_status in ('approved', 'rejected', 'cancelled')
    when 'approved'             then p_new_status in ('routed', 'cancelled')
    when 'routed'               then p_new_status in ('sent', 'rerouted', 'cancelled')
    when 'sent'                 then p_new_status in ('acknowledged', 'rerouted', 'cancelled', 'overdue')
    when 'acknowledged'         then p_new_status in ('accepted', 'rejected', 'rerouted', 'overdue')
    when 'accepted'             then p_new_status in ('in_progress', 'rejected', 'overdue', 'escalated')
    when 'in_progress'          then p_new_status in ('completed', 'escalated', 'overdue')
    when 'completed'            then p_new_status = 'verification_pending'
    when 'verification_pending' then p_new_status = 'escalated'
    when 'overdue'              then p_new_status in ('acknowledged', 'accepted', 'in_progress', 'escalated', 'cancelled')
    when 'escalated'            then p_new_status in ('rerouted', 'cancelled', 'approved', 'acknowledged', 'accepted')
    when 'rejected'             then p_new_status in ('rerouted', 'cancelled')
    when 'rerouted'             then p_new_status = 'drafted'
    when 'cancelled'            then false
    else false
  end;

  if not v_allowed then
    raise exception 'Cannot move a task dispatch from "%" to "%".', v_d.status, p_new_status
      using errcode = 'check_violation';
  end if;

  -- ---- authorization per transition ----
  if p_new_status in ('approved', 'routed', 'sent', 'escalated', 'cancelled') and coalesce(v_caller_role, 'citizen') not in ('commander', 'admin') then
    raise exception 'Only a commander or admin may set status "%".', p_new_status using errcode = 'insufficient_privilege';
  end if;
  if p_new_status in ('acknowledged', 'accepted', 'in_progress') and not (v_is_officer or coalesce(v_caller_role, 'citizen') in ('commander', 'admin')) then
    raise exception 'Only the assigned officer (or command) may set status "%".', p_new_status using errcode = 'insufficient_privilege';
  end if;
  if p_new_status = 'rerouted' and coalesce(v_caller_role, 'citizen') not in ('commander', 'admin') then
    raise exception 'Only a commander or admin may reroute a task.' using errcode = 'insufficient_privilege';
  end if;

  -- ---- mandatory reasons ----
  if p_new_status in ('rejected', 'rerouted', 'cancelled') and coalesce(trim(p_reason), '') = '' then
    raise exception '"%" requires a reason.' , p_new_status using errcode = 'check_violation';
  end if;

  update task_dispatches set
    status = p_new_status,
    acknowledged_at = case when p_new_status = 'acknowledged' then v_now else acknowledged_at end,
    accepted_at     = case when p_new_status = 'accepted' then v_now else accepted_at end,
    -- Arrival has no dedicated lifecycle status of its own (the 15 states
    -- are exactly the ones plan §4 lists) — modelled here as "the officer
    -- has arrived by the time they start work", set once, the first time
    -- status reaches in_progress. Simpler than a 16th status; documented in
    -- docs/IMPLEMENTATION_STATUS.md as a scope simplification.
    arrived_at      = case when p_new_status = 'in_progress' and arrived_at is null then v_now else arrived_at end,
    started_at      = case when p_new_status = 'in_progress' then v_now else started_at end,
    completed_at    = case when p_new_status = 'completed' then v_now else completed_at end,
    verification_requested_at = case when p_new_status = 'verification_pending' then v_now else verification_requested_at end,
    verified_at     = case when p_new_status = 'verification_pending' and v_d.status = 'completed' then v_now else verified_at end,
    escalated_at    = case when p_new_status = 'escalated' then v_now else escalated_at end,
    escalation_level = case when p_new_status = 'escalated' then escalation_level + 1 else escalation_level end,
    escalation_reason = case when p_new_status = 'escalated' then coalesce(p_reason, escalation_reason) else escalation_reason end,
    rejection_reason  = case when p_new_status = 'rejected' then p_reason else rejection_reason end,
    reroute_reason    = case when p_new_status = 'rerouted' then p_reason else reroute_reason end,
    cancellation_reason = case when p_new_status = 'cancelled' then p_reason else cancellation_reason end,
    approved_by = case when p_new_status = 'approved' then p_actor_id else approved_by end,
    approved_at = case when p_new_status = 'approved' then v_now else approved_at end,
    updated_at = v_now
  where id = p_dispatch_id;

  -- keep actions.workflow_status in sync for the states the two concepts
  -- share (Phase 4's own trigger, enforce_incident_action_rules, still
  -- governs what actions.workflow_status may legally hold — this update is
  -- subject to that trigger exactly like any other, unchanged).
  if p_new_status in ('accepted', 'in_progress') then
    update actions set workflow_status = p_new_status::text::action_workflow_status where id = v_d.action_id;
  end if;

  insert into incident_events (incident_id, event_type, actor_id, note, is_public, payload)
  values (
    v_d.incident_id,
    case p_new_status
      when 'approved' then 'approval' when 'sent' then 'dispatch'
      when 'acknowledged' then 'acknowledgement' when 'accepted' then 'acceptance'
      when 'rejected' then 'rejection' when 'rerouted' then 'rerouting'
      when 'escalated' then 'escalation' when 'completed' then 'completion'
      when 'cancelled' then 'cancellation' else 'status_changed'
    end,
    p_actor_id,
    format('Task %s%s.', p_new_status, case when p_reason is not null then ': ' || p_reason else '' end),
    p_new_status in ('sent', 'acknowledged', 'accepted', 'in_progress', 'completed', 'verification_pending'),
    jsonb_build_object('task_dispatch_id', p_dispatch_id, 'status', p_new_status)
  );

  -- plan §8: "escalate when action is completed without required evidence" —
  -- fires immediately (not on an SLA timer) so a bare "completed" claim with
  -- nothing behind it surfaces to command right away rather than waiting for
  -- the verification-SLA clock to run out.
  if p_new_status = 'completed'
     and not exists (select 1 from action_evidence where action_id = v_d.action_id)
     and (select proof_url from actions where id = v_d.action_id) is null
  then
    update task_dispatches set
      escalation_level = escalation_level + 1,
      escalation_reason = 'Marked completed with no attached evidence (no action_evidence rows, no proof_url).',
      updated_at = v_now
    where id = p_dispatch_id;

    insert into incident_events (incident_id, event_type, actor_id, note, is_public, payload)
    values (v_d.incident_id, 'escalation', null,
      'Task marked completed without required evidence — flagged for command review.', false,
      jsonb_build_object('task_dispatch_id', p_dispatch_id, 'reason', 'completed_without_evidence'));
  end if;
end $$;

revoke all on function transition_task_dispatch(bigint, task_dispatch_status, uuid, text) from public;
grant execute on function transition_task_dispatch(bigint, task_dispatch_status, uuid, text) to authenticated;

-- ============================================================
-- report_resource_unavailable / request_task_reroute — field-officer-only
-- narrow actions (plan §9/§11). Neither invents availability data; both
-- simply record what the officer reports and flag command.
-- ============================================================
create or replace function report_resource_unavailable(p_dispatch_id bigint, p_actor_id uuid, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare v_d task_dispatches%rowtype;
begin
  select * into v_d from task_dispatches where id = p_dispatch_id and is_current;
  if not found then raise exception 'Task dispatch % not found', p_dispatch_id; end if;
  if v_d.primary_officer is distinct from p_actor_id then
    raise exception 'Only the assigned officer may report resource availability for this task.' using errcode = 'insufficient_privilege';
  end if;

  update task_dispatches set resource_availability = 'unavailable', resource_note = p_note, updated_at = now()
  where id = p_dispatch_id;

  insert into incident_events (incident_id, event_type, actor_id, note, is_public, payload)
  values (v_d.incident_id, 'status_changed', p_actor_id, format('Officer reported resource unavailable: %s', coalesce(p_note, 'no reason given')), false,
    jsonb_build_object('task_dispatch_id', p_dispatch_id, 'resource_availability', 'unavailable'));
end $$;

revoke all on function report_resource_unavailable(bigint, uuid, text) from public;
grant execute on function report_resource_unavailable(bigint, uuid, text) to authenticated;

create or replace function request_task_reroute(p_dispatch_id bigint, p_actor_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v_d task_dispatches%rowtype;
begin
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'Requesting a reroute requires a reason.' using errcode = 'check_violation';
  end if;
  select * into v_d from task_dispatches where id = p_dispatch_id and is_current;
  if not found then raise exception 'Task dispatch % not found', p_dispatch_id; end if;
  if v_d.primary_officer is distinct from p_actor_id then
    raise exception 'Only the assigned officer may request a reroute for this task.' using errcode = 'insufficient_privilege';
  end if;

  -- The officer only ever REQUESTS — command still decides (transition_task_dispatch
  -- to 'rerouted' is commander/admin-only). This is recorded as an escalation
  -- so it surfaces in the Operations panel, not a silent status change.
  update task_dispatches set escalation_reason = format('Reroute requested by officer: %s', p_reason), updated_at = now()
  where id = p_dispatch_id;

  insert into incident_events (incident_id, event_type, actor_id, note, is_public, payload)
  values (v_d.incident_id, 'status_changed', p_actor_id, format('Officer requested a reroute: %s', p_reason), false,
    jsonb_build_object('task_dispatch_id', p_dispatch_id, 'reroute_requested', true));
end $$;

revoke all on function request_task_reroute(bigint, uuid, text) from public;
grant execute on function request_task_reroute(bigint, uuid, text) to authenticated;

-- ============================================================
-- resolve_jurisdiction_dispute — command-only (plan §10: "resolve
-- jurisdiction dispute with reason"). Picks a registry row (the disputed
-- one, its backup, or a different one entirely) and moves the dispatch to
-- 'approved', ready to route/send.
-- ============================================================
create or replace function resolve_jurisdiction_dispute(
  p_dispatch_id bigint,
  p_actor_id    uuid,
  p_registry_id bigint,
  p_note        text
) returns void language plpgsql security definer set search_path = public as $$
declare v_d task_dispatches%rowtype; v_caller_role user_role; v_reg responsibility_registry%rowtype;
begin
  select role into v_caller_role from profiles where id = p_actor_id;
  if coalesce(v_caller_role, 'citizen') not in ('commander', 'admin') then
    raise exception 'Only a commander or admin may resolve a jurisdiction dispute.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(trim(p_note), '') = '' then
    raise exception 'Resolving a jurisdiction dispute requires a reason.' using errcode = 'check_violation';
  end if;

  select * into v_d from task_dispatches where id = p_dispatch_id and is_current;
  if not found then raise exception 'Task dispatch % not found', p_dispatch_id; end if;
  select * into v_reg from responsibility_registry where id = p_registry_id;
  if not found then raise exception 'Responsibility registry row % not found', p_registry_id; end if;

  update task_dispatches set
    registry_id = v_reg.id,
    responsible_agency = v_reg.regulating_authority,
    division_zone = v_reg.division_zone,
    primary_officer = v_reg.responsible_officer,
    primary_team = v_reg.team_name,
    routing_confidence = 'confirmed',
    dispute_resolution_note = p_note,
    status = 'approved',
    approved_by = p_actor_id,
    approved_at = now(),
    updated_at = now()
  where id = p_dispatch_id;

  insert into incident_events (incident_id, event_type, actor_id, note, is_public, payload)
  values (v_d.incident_id, 'approval', p_actor_id, format('Jurisdiction dispute resolved: %s', p_note), false,
    jsonb_build_object('task_dispatch_id', p_dispatch_id, 'registry_id', v_reg.id));
end $$;

revoke all on function resolve_jurisdiction_dispute(bigint, uuid, bigint, text) from public;
grant execute on function resolve_jurisdiction_dispute(bigint, uuid, bigint, text) to authenticated;

-- ============================================================
-- escalate_stale_task_dispatches — the SLA/escalation batch driver (plan
-- §8), callable by the ingest cron or a commander session. Finds
-- non-terminal dispatches past their next SLA checkpoint and escalates
-- them, walking the matched registry's own escalation_hierarchy.
-- ============================================================
create or replace function escalate_stale_task_dispatches(p_city_code text default null)
returns table (dispatch_id bigint, new_status task_dispatch_status)
language plpgsql security definer set search_path = public as $$
declare
  v_caller_role user_role;
  r record;
begin
  if auth.uid() is not null then
    select role into v_caller_role from profiles where id = auth.uid();
    if coalesce(v_caller_role, 'citizen') not in ('commander', 'admin') then
      raise exception 'Only a commander or admin may run escalation.' using errcode = 'insufficient_privilege';
    end if;
  end if;

  for r in
    select d.id, d.incident_id, d.status,
      case
        when d.status = 'sent' and d.sla_ack_due_at < now() then 'overdue'
        when d.status = 'acknowledged' and d.sla_accept_due_at < now() then 'overdue'
        when d.status in ('accepted') and d.sla_arrival_due_at < now() then 'overdue'
        when d.status = 'in_progress' and d.sla_completion_due_at < now() then 'overdue'
        when d.status = 'completed' and d.sla_verification_due_at < now() then 'escalated'
        when d.status = 'overdue' then 'escalated'
      end as target_status
    from task_dispatches d
    join incidents i on i.id = d.incident_id
    join city_config c on c.id = i.city_id
    where d.is_current
      and (p_city_code is null or c.city_code = p_city_code)
      and d.status in ('sent', 'acknowledged', 'accepted', 'in_progress', 'completed', 'overdue')
  loop
    if r.target_status is null then
      continue;
    end if;
    dispatch_id := r.id;
    new_status := r.target_status::task_dispatch_status;

    update task_dispatches set
      status = new_status,
      escalated_at = case when new_status = 'escalated' then now() else escalated_at end,
      escalation_level = case when new_status = 'escalated' then escalation_level + 1 else escalation_level end,
      escalation_reason = case when new_status = 'escalated' then 'SLA deadline missed' else escalation_reason end,
      updated_at = now()
    where id = r.id;

    insert into incident_events (incident_id, event_type, actor_id, note, is_public, payload)
    values (r.incident_id, case when new_status = 'escalated' then 'escalation' else 'status_changed' end, null,
      format('Task automatically marked %s: SLA deadline missed.', new_status), false,
      jsonb_build_object('task_dispatch_id', r.id, 'status', new_status));

    return next;
  end loop;
end $$;

revoke all on function escalate_stale_task_dispatches(text) from public;
grant execute on function escalate_stale_task_dispatches(text) to authenticated;

-- ============================================================
-- Seed: Delhi's SLA rules + dispatch approval-type configuration.
-- ============================================================
insert into sla_rules (slug, city_id, severity, action_type, ack_hours, accept_hours, arrival_hours, completion_hours, verification_hours, priority)
select 'delhi_severe', id, 'severe', null, 1, 2, 4, 12, 48, 30 from city_config where city_code = 'delhi'
on conflict (slug) do nothing;

insert into sla_rules (slug, city_id, action_type, ack_hours, accept_hours, arrival_hours, completion_hours, verification_hours, priority)
select 'delhi_penalty', id, 'penalty', 1, 2, 6, 24, 72, 20 from city_config where city_code = 'delhi'
on conflict (slug) do nothing;

insert into sla_rules (slug, city_id, ack_hours, accept_hours, arrival_hours, completion_hours, verification_hours, priority)
select 'delhi_default', id, 2, 4, 8, 24, 72, 0 from city_config where city_code = 'delhi'
on conflict (slug) do nothing;

update city_config
set config = config || jsonb_build_object(
  'dispatch', jsonb_build_object(
    'requires_approval_types', jsonb_build_array('penalty', 'stop_work', 'closure', 'restriction', 'prosecution', 'sprinkle')
  )
)
where city_code = 'delhi'
  and not (config ? 'dispatch');
