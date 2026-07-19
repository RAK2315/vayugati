-- ============================================================
-- incidents_core — additive migration (Phase 2, safest slice)
--
-- Introduces the incident-centred domain model from
-- docs/vayu-gati-product-plan-v2.md without touching any existing
-- table, column, row, or RLS policy. Nothing here is destructive:
--
--   * all new objects are CREATE ... IF NOT EXISTS / guarded CREATE TYPE
--   * the only changes to existing tables are two nullable FK columns
--     (reports.incident_id, actions.incident_id) and one nullable FK
--     column (wards.city_id) — additive, backward compatible, and
--     safe to leave unpopulated
--   * the current citizen-report flow keeps working unchanged;
--     nothing in this file requires the UI to link reports to an
--     incident yet (that lands in a following, reviewable slice)
--
-- Idempotent: safe to re-run and safe via `supabase db push`.
-- See docs/DATA_MODEL.md for the full entity-relationship narrative
-- and docs/VAYU_GATI_MIGRATION_AUDIT.md §10-12 for the phase plan and
-- rollback strategy.
-- ============================================================

-- ---------- enums (guarded — CREATE TYPE has no IF NOT EXISTS) ----------
do $$ begin
  create type source_confidence_level as enum ('suspected', 'corroborated', 'officially_verified');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type incident_outcome as enum (
    'effective', 'partly_effective', 'ineffective', 'inconclusive',
    'source_disproved', 'completed_no_change', 'recurred'
  );
exception when duplicate_object then null;
end $$;

do $$ begin
  create type incident_status as enum (
    'detected', 'under_review', 'evidence_gathering', 'routed',
    'action_approved', 'action_dispatched', 'in_progress', 'verifying', 'closed'
  );
exception when duplicate_object then null;
end $$;

do $$ begin
  create type incident_classification as enum ('local', 'mixed', 'regional', 'uncertain');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type approval_level as enum ('automatic', 'command', 'authorised_legal');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type mission_status as enum ('proposed', 'dispatched', 'in_progress', 'completed', 'cancelled');
exception when duplicate_object then null;
end $$;

-- ---------- city configuration (Pan-India configurability, plan §20) ----------
create table if not exists city_config (
  id                   serial primary key,
  city_code            text not null unique,           -- e.g. 'delhi'
  name                 text not null,
  country              text not null default 'India',
  timezone             text not null default 'Asia/Kolkata',
  default_language     text not null default 'hi',
  supported_languages  text[] not null default array['hi', 'en'],
  pollutant_priority   text[] not null default array['pm25', 'pm10', 'no2'], -- V1 priority order, plan §6
  is_active            boolean not null default true,
  config               jsonb not null default '{}'::jsonb, -- SLA defaults, escalation hierarchy, thresholds — see docs/DATA_MODEL.md
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

create table if not exists city_connectors (
  id               bigserial primary key,
  city_id          int not null references city_config(id) on delete cascade,
  connector_type   text not null check (connector_type in ('pollution', 'weather', 'mobility', 'satellite', 'gis', 'other')),
  provider         text not null,                        -- e.g. 'openaq', 'open-meteo'
  config           jsonb not null default '{}'::jsonb,
  is_enabled       boolean not null default true,
  last_sync_at     timestamptz,
  last_sync_status text,                                  -- e.g. 'ok', 'stale', 'not_configured', 'error'
  created_at       timestamptz not null default now(),
  unique (city_id, connector_type, provider)
);
create index if not exists city_connectors_city_idx on city_connectors (city_id, connector_type);

-- link wards to a city (nullable + backfilled below; never required by existing insert paths)
alter table wards add column if not exists city_id int references city_config(id);

-- ---------- incidents: the central domain object (plan §2) ----------
create table if not exists incidents (
  id                 bigserial primary key,
  city_id            int references city_config(id),
  ward_id            int references wards(id) on delete set null,
  status             incident_status not null default 'detected',
  classification     incident_classification,             -- local / mixed / regional / uncertain, set once evidence allows
  primary_pollutant  text check (primary_pollutant in ('pm25', 'pm10', 'no2', 'so2', 'co', 'o3')),
  -- detection_method must always be populated by the detection service so an
  -- incident is never traceable to "a single isolated reading" (plan §6) —
  -- enforced by the ingest/detection code path, documented here as a NOT NULL.
  detection_method   text not null,
  detected_at        timestamptz not null default now(),
  closed_at          timestamptz,
  source_confidence  source_confidence_level not null default 'suspected',
  lat                double precision,
  lng                double precision,
  summary            text,
  created_by         uuid references profiles(id),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index if not exists incidents_city_idx on incidents (city_id);
create index if not exists incidents_ward_status_idx on incidents (ward_id, status);
create index if not exists incidents_status_idx on incidents (status);
create index if not exists incidents_detected_idx on incidents (detected_at desc);

-- ---------- evidence attached to an incident (plan §8) ----------
create table if not exists incident_evidence (
  id            bigserial primary key,
  incident_id   bigint not null references incidents(id) on delete cascade,
  evidence_type text not null check (evidence_type in ('reading', 'citizen_report', 'field_inspection', 'satellite', 'sensor', 'photo', 'other')),
  report_id     bigint references reports(id) on delete set null,
  reading_id    bigint references readings(id) on delete set null,
  supports      boolean,                                  -- true = corroborates the leading hypothesis, false = contradicts
  confidence    double precision check (confidence is null or (confidence >= 0 and confidence <= 1)),
  payload       jsonb not null default '{}'::jsonb,
  collected_at  timestamptz not null default now(),
  collected_by  uuid references profiles(id),
  created_at    timestamptz not null default now()
);
create index if not exists incident_evidence_incident_idx on incident_evidence (incident_id, collected_at desc);
create index if not exists incident_evidence_report_idx on incident_evidence (report_id);

-- ---------- probabilistic source hypotheses (plan §8-9) ----------
create table if not exists incident_source_hypotheses (
  id               bigserial primary key,
  incident_id      bigint not null references incidents(id) on delete cascade,
  source_category  source_category,
  probability      double precision not null check (probability >= 0 and probability <= 1),
  confidence_level source_confidence_level not null default 'suspected',
  rationale        text,
  contradicted_by  text,
  model_version    text,
  computed_at      timestamptz not null default now(),
  created_at       timestamptz not null default now()
);
create index if not exists incident_hypotheses_incident_idx on incident_source_hypotheses (incident_id, probability desc);

-- ---------- next-best-evidence missions (plan §10) ----------
create table if not exists evidence_missions (
  id                       bigserial primary key,
  incident_id              bigint not null references incidents(id) on delete cascade,
  mission_type             text not null check (mission_type in (
    'citizen_verification', 'field_photo', 'mobile_sensor_route', 'upwind_downwind_reading',
    'construction_check', 'traffic_count', 'source_status_check', 'other'
  )),
  status                   mission_status not null default 'proposed',
  assigned_to              uuid references profiles(id),
  expected_confidence_gain double precision,
  rationale                text,                           -- why this evidence is needed (plan §10 requirement)
  dispatched_at            timestamptz,
  completed_at             timestamptz,
  result                   jsonb,
  created_at               timestamptz not null default now()
);
create index if not exists evidence_missions_incident_idx on evidence_missions (incident_id, status);
create index if not exists evidence_missions_assignee_idx on evidence_missions (assigned_to, status);

-- ---------- source–responsibility registry (plan §12) ----------
create table if not exists responsibility_registry (
  id                     bigserial primary key,
  city_id                int references city_config(id),
  source_category        source_category,
  ward_id                int references wards(id),
  asset_description      text,
  owner_name             text,
  regulating_authority   text,
  division_zone          text,
  responsible_officer    uuid references profiles(id),
  escalation_contact     text,
  is_disputed            boolean not null default false,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);
create index if not exists responsibility_registry_lookup_idx on responsibility_registry (city_id, source_category, ward_id);

-- ---------- configurable intervention playbooks (plan §13) ----------
create table if not exists intervention_playbooks (
  id                      bigserial primary key,
  city_id                 int references city_config(id),
  source_category         source_category,
  min_evidence_level      source_confidence_level not null default 'corroborated',
  approval_level          approval_level not null default 'command',
  title                   text not null,
  checklist               jsonb not null default '[]'::jsonb,
  required_team           text,
  required_equipment      text,
  estimated_minutes       int,
  estimated_cost          numeric,
  expected_effect         text,
  expected_duration_hours numeric,
  known_limitations       text,
  required_proof          text,
  verification_method     text,
  evidence_basis          text check (evidence_basis in ('literature', 'expert_estimate', 'vayu_gati_observation')),
  is_active               boolean not null default true,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now()
);
create index if not exists intervention_playbooks_lookup_idx on intervention_playbooks (city_id, source_category);

-- ---------- incident audit trail / timeline (mirrors report_events) ----------
create table if not exists incident_events (
  id           bigserial primary key,
  incident_id  bigint not null references incidents(id) on delete cascade,
  event_type   text not null,   -- 'created' | 'classified' | 'evidence_added' | 'hypothesis_updated' |
                                 -- 'mission_dispatched' | 'routed' | 'task_created' | 'action_approved' |
                                 -- 'action_dispatched' | 'action_completed' | 'impact_evaluated' |
                                 -- 'status_changed' | 'closed' | 'other'
  actor_id     uuid references profiles(id),
  note         text,
  payload      jsonb,
  ts           timestamptz not null default now()
);
create index if not exists incident_events_incident_idx on incident_events (incident_id, ts);

-- ---------- operational proof for a task/action (plan §15, operational verification) ----------
create table if not exists action_evidence (
  id                bigserial primary key,
  action_id         bigint not null references actions(id) on delete cascade,
  evidence_type     text not null check (evidence_type in (
    'gps', 'timestamp', 'checklist', 'photo', 'video', 'voice_note', 'asset_record', 'inspection_outcome', 'other'
  )),
  payload           jsonb not null default '{}'::jsonb,
  photo_url         text,
  captured_by       uuid references profiles(id),
  captured_at       timestamptz not null default now(),
  is_offline_capture boolean not null default false,       -- field app offline-draft support (plan §Field application)
  synced_at         timestamptz,
  created_at        timestamptz not null default now()
);
create index if not exists action_evidence_action_idx on action_evidence (action_id, captured_at desc);

-- ---------- environmental impact evaluation (plan §15, separate from task completion) ----------
create table if not exists impact_evaluations (
  id                        bigserial primary key,
  incident_id               bigint not null references incidents(id) on delete cascade,
  action_id                 bigint references actions(id) on delete set null,
  method                    text not null check (method in (
    'before_after', 'weather_adjusted', 'comparable_location', 'citizen_confirmation', 'recurrence_window', 'other'
  )),
  before_value              double precision,
  after_value               double precision,
  expected_no_action_value  double precision,
  comparison_ward_id        int references wards(id),
  weather_adjustment        jsonb,
  citizen_confirmed         boolean,
  recurrence_window_days    int,
  outcome                   incident_outcome not null default 'inconclusive',
  confidence                double precision check (confidence is null or (confidence >= 0 and confidence <= 1)),
  evaluated_by              uuid references profiles(id),
  evaluated_at              timestamptz not null default now(),
  notes                     text,
  created_at                timestamptz not null default now()
);
create index if not exists impact_evaluations_incident_idx on impact_evaluations (incident_id, evaluated_at desc);

-- ---------- link existing reports/actions to incidents (additive, nullable) ----------
alter table reports add column if not exists incident_id bigint references incidents(id) on delete set null;
create index if not exists reports_incident_idx on reports (incident_id);

alter table actions add column if not exists incident_id bigint references incidents(id) on delete set null;
create index if not exists actions_incident_idx on actions (incident_id);

-- ============================================================
-- Row Level Security
-- Mirrors the existing posture: `auth_role()` / `auth_ward()` (defined in
-- schema.sql) gate everything; reference data reads broadly, writes are
-- ward-scoped for field officers and unrestricted for commander/admin.
-- ============================================================

alter table city_config              enable row level security;
alter table city_connectors          enable row level security;
alter table incidents                enable row level security;
alter table incident_evidence        enable row level security;
alter table incident_source_hypotheses enable row level security;
alter table evidence_missions        enable row level security;
alter table responsibility_registry  enable row level security;
alter table intervention_playbooks   enable row level security;
alter table incident_events          enable row level security;
alter table action_evidence          enable row level security;
alter table impact_evaluations       enable row level security;

-- city_config: readable by any authenticated user (needed by all clients to
-- know which City Pack they're in); writes are service_role only (no policy).
drop policy if exists city_config_read on city_config;
create policy city_config_read on city_config for select using (auth.role() = 'authenticated');

-- city_connectors: operational/provider detail — commander/admin only.
drop policy if exists city_connectors_read on city_connectors;
create policy city_connectors_read on city_connectors for select using (auth_role() in ('commander', 'admin'));

-- incidents: field officer sees their ward; commander/admin see all;
-- citizen sees an incident only if one of their own reports is linked to it.
drop policy if exists incidents_read on incidents;
create policy incidents_read on incidents for select using (
  auth_role() in ('commander', 'admin')
  or (auth_role() = 'field_officer' and ward_id = auth_ward())
  or exists (
    select 1 from reports r where r.incident_id = incidents.id and r.reporter_id = auth.uid()
  )
);
drop policy if exists incidents_write on incidents;
create policy incidents_write on incidents for insert with check (
  auth_role() in ('commander', 'admin')
  or (auth_role() = 'field_officer' and ward_id = auth_ward())
);
drop policy if exists incidents_update on incidents;
create policy incidents_update on incidents for update using (
  auth_role() in ('commander', 'admin')
  or (auth_role() = 'field_officer' and ward_id = auth_ward())
);

-- helper predicate (inlined per-policy below, since Postgres RLS can't share
-- a function easily across tables without another security-definer wrapper):
-- "can this user see the parent incident?" — same rule as incidents_read.

drop policy if exists incident_evidence_read on incident_evidence;
create policy incident_evidence_read on incident_evidence for select using (
  exists (
    select 1 from incidents i where i.id = incident_evidence.incident_id
    and (
      auth_role() in ('commander', 'admin')
      or (auth_role() = 'field_officer' and i.ward_id = auth_ward())
      or exists (select 1 from reports r where r.incident_id = i.id and r.reporter_id = auth.uid())
    )
  )
);
drop policy if exists incident_evidence_write on incident_evidence;
create policy incident_evidence_write on incident_evidence for insert with check (
  auth.role() = 'authenticated'
);

drop policy if exists incident_hypotheses_read on incident_source_hypotheses;
create policy incident_hypotheses_read on incident_source_hypotheses for select using (
  exists (
    select 1 from incidents i where i.id = incident_source_hypotheses.incident_id
    and (
      auth_role() in ('commander', 'admin')
      or (auth_role() = 'field_officer' and i.ward_id = auth_ward())
    )
  )
);
drop policy if exists incident_hypotheses_write on incident_source_hypotheses;
create policy incident_hypotheses_write on incident_source_hypotheses for all using (
  auth_role() in ('commander', 'admin')
) with check (
  auth_role() in ('commander', 'admin')
);

drop policy if exists evidence_missions_read on evidence_missions;
create policy evidence_missions_read on evidence_missions for select using (
  assigned_to = auth.uid()
  or exists (
    select 1 from incidents i where i.id = evidence_missions.incident_id
    and (
      auth_role() in ('commander', 'admin')
      or (auth_role() = 'field_officer' and i.ward_id = auth_ward())
    )
  )
);
drop policy if exists evidence_missions_write on evidence_missions;
create policy evidence_missions_write on evidence_missions for all using (
  auth_role() in ('commander', 'admin')
  or assigned_to = auth.uid()
) with check (
  auth_role() in ('commander', 'admin')
  or assigned_to = auth.uid()
);

drop policy if exists responsibility_registry_read on responsibility_registry;
create policy responsibility_registry_read on responsibility_registry for select using (
  auth_role() in ('commander', 'admin')
  or (auth_role() = 'field_officer' and (ward_id is null or ward_id = auth_ward()))
);
drop policy if exists responsibility_registry_write on responsibility_registry;
create policy responsibility_registry_write on responsibility_registry for all using (
  auth_role() in ('commander', 'admin')
) with check (
  auth_role() in ('commander', 'admin')
);

drop policy if exists intervention_playbooks_read on intervention_playbooks;
create policy intervention_playbooks_read on intervention_playbooks for select using (
  auth_role() in ('field_officer', 'commander', 'admin')
);
drop policy if exists intervention_playbooks_write on intervention_playbooks;
create policy intervention_playbooks_write on intervention_playbooks for all using (
  auth_role() in ('commander', 'admin')
) with check (
  auth_role() in ('commander', 'admin')
);

drop policy if exists incident_events_read on incident_events;
create policy incident_events_read on incident_events for select using (
  exists (
    select 1 from incidents i where i.id = incident_events.incident_id
    and (
      auth_role() in ('commander', 'admin')
      or (auth_role() = 'field_officer' and i.ward_id = auth_ward())
      or exists (select 1 from reports r where r.incident_id = i.id and r.reporter_id = auth.uid())
    )
  )
);
drop policy if exists incident_events_write on incident_events;
create policy incident_events_write on incident_events for insert with check (
  auth.role() = 'authenticated'
);

drop policy if exists action_evidence_read on action_evidence;
create policy action_evidence_read on action_evidence for select using (
  exists (
    select 1 from actions a where a.id = action_evidence.action_id
    and (
      auth_role() in ('commander', 'admin')
      or (auth_role() = 'field_officer' and a.ward_id = auth_ward())
    )
  )
);
drop policy if exists action_evidence_write on action_evidence;
create policy action_evidence_write on action_evidence for insert with check (
  exists (
    select 1 from actions a where a.id = action_evidence.action_id
    and (
      auth_role() in ('commander', 'admin')
      or (auth_role() = 'field_officer' and a.ward_id = auth_ward())
    )
  )
);

drop policy if exists impact_evaluations_read on impact_evaluations;
create policy impact_evaluations_read on impact_evaluations for select using (
  exists (
    select 1 from incidents i where i.id = impact_evaluations.incident_id
    and (
      auth_role() in ('commander', 'admin')
      or (auth_role() = 'field_officer' and i.ward_id = auth_ward())
      or exists (select 1 from reports r where r.incident_id = i.id and r.reporter_id = auth.uid())
    )
  )
);
drop policy if exists impact_evaluations_write on impact_evaluations;
create policy impact_evaluations_write on impact_evaluations for all using (
  auth_role() in ('commander', 'admin')
) with check (
  auth_role() in ('commander', 'admin')
);

-- ============================================================
-- Seed: Delhi as the first City Pack + its real, currently-live connectors.
-- Connectors are seeded to reflect ACTUAL integration status (openaq/open-meteo
-- enabled; satellite/mobility/gis explicitly marked not configured) rather
-- than implying integrations that don't exist yet — see plan's "do not fake
-- integrations" rule.
-- ============================================================

insert into city_config (city_code, name, country, timezone, default_language, supported_languages, pollutant_priority)
values ('delhi', 'Delhi', 'India', 'Asia/Kolkata', 'hi', array['hi', 'en'], array['pm25', 'pm10', 'no2'])
on conflict (city_code) do nothing;

update wards set city_id = (select id from city_config where city_code = 'delhi')
where city_id is null;

insert into city_connectors (city_id, connector_type, provider, is_enabled, last_sync_status)
select id, 'pollution', 'openaq', true, 'ok' from city_config where city_code = 'delhi'
union all
select id, 'weather', 'open-meteo', true, 'ok' from city_config where city_code = 'delhi'
union all
select id, 'mobility', 'none', false, 'not_configured' from city_config where city_code = 'delhi'
union all
select id, 'satellite', 'none', false, 'not_configured' from city_config where city_code = 'delhi'
union all
select id, 'gis', 'none', false, 'not_configured' from city_config where city_code = 'delhi'
on conflict (city_id, connector_type, provider) do nothing;
