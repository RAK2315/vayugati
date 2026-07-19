-- ============================================================
-- intervention_playbooks — additive migration (Phase 5, vertical slice)
--
-- Replaces free-text intervention creation with structured, source-specific
-- playbooks, reusing the `intervention_playbooks` table that has existed
-- since Phase 2 (schema only, never populated, never read by any code —
-- see IMPLEMENTATION_STATUS.md Phase 4 limitation 6). No parallel table is
-- created. Everything here is additive:
--
--   * new columns on the EXISTING `intervention_playbooks` table (action type,
--     responsible agency type, operational instructions, a cost RANGE,
--     deploy/effect/verification timing, recommended pollutants, a regional
--     applicability flag, and a version counter)
--   * new, nullable columns on `actions` (which playbook was used, a snapshot
--     of its version and checklist at selection time, and a bounded
--     "operational notes" override) plus one index
--   * the `enforce_incident_action_rules` trigger is REPLACED (create or
--     replace, same function name as Phase 3/4) to add ONE more check: an
--     action referencing a playbook must meet that playbook's own
--     min_evidence_level. This closes a real gap — see the trigger's comment
--     for the reasoning and for what it does NOT need to close (the
--     enforcement-type gate already keys off `actions.type` directly, never
--     off playbook content, so it was never bypassable via playbook edits).
--   * six Delhi playbooks seeded (city_id = Delhi's row), matching plan §13
--     and covering road dust, construction dust, open burning, vehicular,
--     industrial (the one enforcement-tier example) and a regional/advisory
--     protocol.
--
-- No existing RLS policy on `intervention_playbooks` or `actions` is changed.
-- The Phase 2 policy (`intervention_playbooks_read`: field_officer/commander/
-- admin; write: commander/admin) already denies citizens entirely — this pass
-- adds a test proving it (was previously unverified, only asserted in docs).
--
-- No new SQL function is required: listing/ranking/eligibility is read-only
-- and pure, and lives in web/src/lib/incidentRules.ts (transparent, rule-
-- based, no ML per the brief); creating an action from a playbook is a plain
-- insert through the existing trigger, exactly like Phase 4's free-text path.
--
-- Idempotent: safe to re-run and safe via `supabase db push`.
-- See docs/DATA_MODEL.md and docs/ROLE_WORKFLOWS.md.
-- ============================================================

-- ---------- intervention_playbooks: new columns (all additive) ----------

-- Controlled vocabulary, mirroring the enforcement-type list the Phase 3/4
-- trigger already hardcodes (penalty/stop_work/closure/restriction/
-- prosecution) plus the operational types already offered in the free-text
-- CreateInterventionDialog (inspect/sprinkle/notice), plus the new source-
-- specific types this pass's seed set needs.
alter table intervention_playbooks add column if not exists action_type text not null default 'inspect';
do $$ begin
  alter table intervention_playbooks add constraint intervention_playbooks_action_type_check
    check (action_type in (
      'inspect', 'sprinkle', 'notice', 'vacuum_sweeping', 'extinguish_removal',
      'traffic_management', 'advisory_monitoring',
      'penalty', 'stop_work', 'closure', 'restriction', 'prosecution', 'other'
    ));
exception when duplicate_object then null;
end $$;

-- Default responsible-authority TYPE (e.g. "Municipal roads department",
-- "Traffic police") — a label, not a specific office; the specific instance
-- value still lives on `actions.responsible_agency` and stays editable per
-- incident. The `responsibility_registry` table remains the eventual home for
-- a real name→authority mapping (still not wired up — see limitations).
alter table intervention_playbooks add column if not exists responsible_agency_type text;

-- Operational narrative, distinct from the itemised `checklist` jsonb below.
alter table intervention_playbooks add column if not exists instructions text;

-- Cost as a RANGE, not a single number (the brief's "estimated cost range").
-- The original singular `estimated_cost` column is left in place, untouched
-- and unpopulated by this migration or its seed data — dropping/renaming a
-- column, even an unused one, is not how this repo does additive migrations
-- (see actions.status vs actions.workflow_status in Phase 4 for the identical
-- pattern). It is documented here as superseded, not silently abandoned.
alter table intervention_playbooks add column if not exists estimated_cost_min numeric;
alter table intervention_playbooks add column if not exists estimated_cost_max numeric;
do $$ begin
  alter table intervention_playbooks add constraint intervention_playbooks_cost_range_check
    check (estimated_cost_min is null or estimated_cost_max is null or estimated_cost_min <= estimated_cost_max);
exception when duplicate_object then null;
end $$;

-- Three DISTINCT time concepts, deliberately not conflated:
--   estimated_minutes (existing, Phase 2)  = time to DEPLOY (get the team there)
--   expected_time_to_effect_hours (new)    = how long after deployment before
--                                            pollution is expected to start
--                                            responding
--   expected_duration_hours (existing)     = how long the effect is expected
--                                            to persist once achieved
--   verification_window_hours (new)        = the recommended window for the
--                                            before/after check; prefills
--                                            actions.expected_verification_hours
alter table intervention_playbooks add column if not exists expected_time_to_effect_hours numeric;
alter table intervention_playbooks add column if not exists verification_window_hours int;

-- Which pollutants the verification step should look at — prefills the
-- before/after form's implicit focus; advisory only, not a hard constraint
-- (record_impact_evaluation still accepts any single before/after pair).
alter table intervention_playbooks add column if not exists recommended_pollutants text[];

-- Regional/non-local applicability. A playbook with for_regional = true is
-- the ONLY kind ever shown for an incident classified 'regional' (plan's
-- "regional/non-local → do not recommend ineffective local action"); every
-- other (default) playbook is hidden for a regional incident. The paired
-- check keeps the model coherent: a regional playbook cannot also claim a
-- specific local source.
alter table intervention_playbooks add column if not exists for_regional boolean not null default false;
do $$ begin
  alter table intervention_playbooks add constraint intervention_playbooks_regional_no_source_check
    check (not for_regional or source_category is null);
exception when duplicate_object then null;
end $$;

-- Bumped by a human editing the master template (not automated — see the
-- "do not automatically rewrite playbook estimates" requirement). Snapshotted
-- onto `actions.playbook_version` at selection time so a historical action
-- remains interpretable even after the live playbook template changes.
alter table intervention_playbooks add column if not exists version int not null default 1;

-- Stable natural key so the seed inserts below are genuinely idempotent.
-- `bigserial id` alone cannot make `on conflict do nothing` idempotent for
-- unkeyed seed data — every re-run would insert a fresh id and duplicate every
-- row. Nullable (a plain unique constraint allows multiple NULLs), so a future
-- non-seeded, admin-created playbook needs no slug at all; every seeded row
-- below gets one.
alter table intervention_playbooks add column if not exists slug text;
do $$ begin
  alter table intervention_playbooks add constraint intervention_playbooks_slug_key unique (slug);
-- A UNIQUE constraint auto-creates a backing index sharing its name, so on
-- re-run Postgres raises duplicate_table (42P07) for the INDEX name
-- collision, not duplicate_object (42710) as CHECK constraints do above —
-- verified by actually re-running this migration, not assumed. Both must be
-- caught for this block to be genuinely idempotent.
exception when duplicate_object or duplicate_table then null;
end $$;

create index if not exists intervention_playbooks_regional_idx on intervention_playbooks (for_regional) where for_regional;

-- ---------- actions: which playbook (if any) produced this intervention ----------
alter table actions add column if not exists playbook_id bigint references intervention_playbooks(id);
alter table actions add column if not exists playbook_version int;
-- The commander's ONLY editable field when creating from a playbook (plan's
-- "allow limited edits to operational notes"). The playbook's own
-- `instructions`/`checklist` are never mutated by this — this is a per-
-- incident addendum, not an edit to the template, which is exactly what keeps
-- edits from being able to touch min_evidence_level or any other gate.
alter table actions add column if not exists playbook_notes_override text;
-- Snapshot of playbook.checklist at selection time, so the field officer's
-- checklist stays stable even if the master playbook is edited later — the
-- same reasoning as playbook_version, applied to the actual content the field
-- app renders.
alter table actions add column if not exists checklist_snapshot jsonb;
create index if not exists actions_playbook_idx on actions (playbook_id);

-- ============================================================
-- Extend the evidence-level trigger (Phase 3/4 function, same name, replaced
-- again) with ONE more check: when an action references a playbook, the
-- incident's source_confidence must meet or exceed that playbook's
-- min_evidence_level.
--
-- Why this is additive defence-in-depth, not the core gate:
-- `source_confidence_level` is declared as `enum ('suspected', 'corroborated',
-- 'officially_verified')` — Postgres orders enum values by declaration order
-- and supports direct <, <=, >, >= comparison, so "meets or exceeds" is a
-- plain comparison, no ordinal mapping table needed.
--
-- The pre-existing enforcement-type gate (penalty/stop_work/closure/
-- restriction/prosecution require officially_verified + a named approver)
-- is UNCHANGED and untouched by this addition: it keys off `new.type`
-- directly and has never consulted `intervention_playbooks` at all. So even
-- if a commander (who already has RLS write access to intervention_playbooks,
-- a pre-existing Phase 2 privilege) edited a playbook's min_evidence_level
-- down, the enforcement-type gate still cannot be bypassed — it does not read
-- min_evidence_level. This new check only prevents a playbook that is
-- LABELLED as requiring more evidence (e.g. min_evidence_level =
-- 'officially_verified' on a non-enforcement action_type) from being used
-- below that label. It is a courtesy check for playbook-tier fidelity, not
-- the safety-critical gate — that gate was never touchable via playbooks.
-- ============================================================
create or replace function enforce_incident_action_rules() returns trigger
language plpgsql as $$
declare
  v_confidence      source_confidence_level;
  v_creating        boolean;
  v_has_eval        boolean;
  v_playbook_min    source_confidence_level;
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

    -- Phase 5 addition: playbook-tier fidelity (see comment above the function).
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

-- ============================================================
-- Seed: six Delhi playbooks (city-scoped, not core-logic-hardcoded — the
-- eligibility/ranking code in incidentRules.ts filters by whatever
-- incident.city_id resolves to; Delhi is data here, not a code branch).
--
-- Deliberately NOT rewritten by any impact-evaluation outcome — nothing in
-- this migration or in web/src/lib/incidents.ts writes back to these rows
-- from observed results. "Do not automatically rewrite playbook estimates"
-- is satisfied by absence: no such code exists.
--
-- Cost/time figures are illustrative (evidence_basis = 'expert_estimate' or
-- 'literature' as appropriate per row) — never presented as guaranteed; see
-- known_limitations on each row and the UI's "not a guarantee" framing.
-- ============================================================

insert into intervention_playbooks (
  slug, city_id, source_category, min_evidence_level, action_type, approval_level,
  title, instructions, checklist, required_team, required_equipment,
  estimated_minutes, estimated_cost_min, estimated_cost_max,
  expected_effect, expected_duration_hours, expected_time_to_effect_hours,
  verification_window_hours, recommended_pollutants,
  known_limitations, required_proof, verification_method, evidence_basis,
  responsible_agency_type, for_regional, is_active
)
select
  'delhi-road-dust-sweeping',
  c.id, 'road_dust', 'corroborated', 'vacuum_sweeping', 'command',
  'Mechanical sweeping and debris removal',
  'Deploy a mechanical/vacuum road sweeper along the affected stretch; remove loose debris and stockpiled material from the carriageway and shoulder.',
  '[{"id":"unpaved","label":"Unpaved or broken shoulder?","type":"boolean"},{"id":"sweeping","label":"Mechanical sweeping evident?","type":"boolean"},{"id":"spill","label":"Material spill on the carriageway?","type":"boolean"},{"id":"notes","label":"Anything else worth recording?","type":"text"}]'::jsonb,
  '2-person sweeper crew', 'Mechanical road sweeper, debris collection vehicle',
  180, 8000, 15000,
  'Reduces resuspended road dust (PM10 primarily) along the treated stretch', 48, 2,
  48, array['pm10','pm25'],
  'Effect is temporary; dust reaccumulates without addressing the unpaved shoulder or spill source. Rain confounds a before/after comparison.',
  'Geotagged photo of the swept stretch, before and after; sweeper vehicle log or work order',
  'PM10 reading at the nearest station/sensor before and after, compared over the verification window',
  'literature', 'Municipal roads/sanitation department', false, true
from city_config c where c.city_code = 'delhi'
on conflict (slug) do nothing;

insert into intervention_playbooks (
  slug, city_id, source_category, min_evidence_level, action_type, approval_level,
  title, instructions, checklist, required_team, required_equipment,
  estimated_minutes, estimated_cost_min, estimated_cost_max,
  expected_effect, expected_duration_hours, expected_time_to_effect_hours,
  verification_window_hours, recommended_pollutants,
  known_limitations, required_proof, verification_method, evidence_basis,
  responsible_agency_type, for_regional, is_active
)
select
  'delhi-construction-dust-inspection',
  c.id, 'construction_dust', 'corroborated', 'inspect', 'command',
  'Site inspection: covering, wheel-wash and track-out control',
  'Inspect the site for required dust-control measures: green netting/covering over stockpiles, a functioning wheel-wash at the site exit, and evidence of material track-out onto the public road. Issue a compliance notice for any deficiency found.',
  '[{"id":"active","label":"Construction work active right now?","type":"boolean"},{"id":"barriers","label":"Dust barriers / green netting in place?","type":"boolean"},{"id":"sprinkling","label":"Water sprinkling in use?","type":"boolean"},{"id":"uncovered","label":"Uncovered material or debris on site?","type":"boolean"},{"id":"notes","label":"Anything else worth recording?","type":"text"}]'::jsonb,
  '1 inspecting officer', 'Standard inspection kit',
  60, 0, 2000,
  'A compliance notice prompts the site to install or repair dust-control measures', 168, 24,
  72, array['pm10','pm25'],
  'A notice does not guarantee compliance; re-inspection may be needed. No mechanism yet to track notice-to-compliance rate.',
  'Geotagged photos of covering/wheel-wash/track-out status; copy of the notice issued, if any',
  'PM10/PM2.5 at the nearest station before the notice and after the verification window',
  'expert_estimate', 'Municipal building/construction enforcement', false, true
from city_config c where c.city_code = 'delhi'
on conflict (slug) do nothing;

insert into intervention_playbooks (
  slug, city_id, source_category, min_evidence_level, action_type, approval_level,
  title, instructions, checklist, required_team, required_equipment,
  estimated_minutes, estimated_cost_min, estimated_cost_max,
  expected_effect, expected_duration_hours, expected_time_to_effect_hours,
  verification_window_hours, recommended_pollutants,
  known_limitations, required_proof, verification_method, evidence_basis,
  responsible_agency_type, for_regional, is_active
)
select
  'delhi-open-burning-extinguish',
  c.id, 'open_burning', 'corroborated', 'extinguish_removal', 'command',
  'Extinguish active burning and remove the waste pile',
  'Verify the fire is genuinely burning waste (not a permitted activity). Extinguish the fire. Arrange removal of the remaining waste pile to prevent reignition. Identify the responsible party where possible.',
  '[{"id":"active","label":"Fire still burning?","type":"boolean"},{"id":"material","label":"What is burning?","type":"text"},{"id":"extinguished","label":"Extinguished during this visit?","type":"boolean"},{"id":"party","label":"Responsible party identified?","type":"boolean"}]'::jsonb,
  '2-person crew + fire-safety equipment', 'Water/extinguishing equipment, waste collection vehicle',
  90, 3000, 10000,
  'Immediately stops the combustion source; PM/NO2 from open burning at this location should cease', 24, 1,
  24, array['pm25','pm10','co'],
  'Reignition is common if waste is not fully removed. Does not address why waste accumulated (root cause = collection frequency).',
  'Geotagged photo of the extinguished site and, separately, of the cleared site; note on responsible party if identified',
  'PM2.5/PM10 at the nearest station before and after; citizen confirmation of no further smoke',
  'expert_estimate', 'Municipal sanitation / fire safety', false, true
from city_config c where c.city_code = 'delhi'
on conflict (slug) do nothing;

insert into intervention_playbooks (
  slug, city_id, source_category, min_evidence_level, action_type, approval_level,
  title, instructions, checklist, required_team, required_equipment,
  estimated_minutes, estimated_cost_min, estimated_cost_max,
  expected_effect, expected_duration_hours, expected_time_to_effect_hours,
  verification_window_hours, recommended_pollutants,
  known_limitations, required_proof, verification_method, evidence_basis,
  responsible_agency_type, for_regional, is_active
)
select
  'delhi-vehicular-traffic-management',
  c.id, 'vehicular', 'corroborated', 'traffic_management', 'command',
  'Traffic-point management at a congestion/idling hotspot',
  'Deploy traffic personnel at the identified congestion point during peak hours to reduce idling and improve flow; check for visibly smoking vehicles and refer them for emission testing.',
  '[{"id":"congestion","label":"Standing/idling queue present?","type":"boolean"},{"id":"smoke","label":"Visibly smoking vehicles?","type":"boolean"},{"id":"notes","label":"Anything else worth recording?","type":"text"}]'::jsonb,
  '2 traffic personnel', 'Standard traffic-management equipment',
  240, 2000, 6000,
  'Reduced idling and smoother flow lowers localized vehicular emissions during the deployment window', 4, 1,
  6, array['no2','pm25'],
  'Effect does not persist after personnel leave; this is a mitigation, not a fix. Congestion may simply relocate.',
  'Photo of the deployment; count of smoking-vehicle referrals if any',
  'NO2/PM2.5 near the deployment point during the shift compared to before',
  'expert_estimate', 'Traffic police', false, true
from city_config c where c.city_code = 'delhi'
on conflict (slug) do nothing;

insert into intervention_playbooks (
  slug, city_id, source_category, min_evidence_level, action_type, approval_level,
  title, instructions, checklist, required_team, required_equipment,
  estimated_minutes, estimated_cost_min, estimated_cost_max,
  expected_effect, expected_duration_hours, expected_time_to_effect_hours,
  verification_window_hours, recommended_pollutants,
  known_limitations, required_proof, verification_method, evidence_basis,
  responsible_agency_type, for_regional, is_active
)
select
  'delhi-industrial-stop-work',
  c.id, 'industrial', 'officially_verified', 'stop_work', 'authorised_legal',
  'Stop-work order: unpermitted or non-compliant industrial emission',
  'Once the source is officially verified (authorised officer confirmation or compliance record), issue a stop-work order until pollution-control equipment is operating and consent is current. Requires authorised approval before dispatch.',
  '[{"id":"operating","label":"Unit operating?","type":"boolean"},{"id":"stack","label":"Visible stack emission?","type":"boolean"},{"id":"apc","label":"Pollution-control equipment running?","type":"boolean"},{"id":"consent","label":"Valid consent displayed?","type":"boolean"},{"id":"notes","label":"Anything else worth recording?","type":"text"}]'::jsonb,
  'Enforcement officer + technical inspector', 'Standard enforcement kit',
  120, 0, 5000,
  'Halts the emitting process at the unit until compliant', 720, 4,
  72, array['pm25','so2','no2'],
  'Legal process may be contested or delayed; effect on ambient air depends on how many other sources contribute regionally.',
  'Copy of the stop-work order; inspection report; approver signature (actions.approved_by)',
  'PM2.5/SO2/NO2 at the nearest station before the order and after the verification window',
  'literature', 'State Pollution Control Board / DPCC', false, true
from city_config c where c.city_code = 'delhi'
on conflict (slug) do nothing;

insert into intervention_playbooks (
  slug, city_id, source_category, min_evidence_level, action_type, approval_level,
  title, instructions, checklist, required_team, required_equipment,
  estimated_minutes, estimated_cost_min, estimated_cost_max,
  expected_effect, expected_duration_hours, expected_time_to_effect_hours,
  verification_window_hours, recommended_pollutants,
  known_limitations, required_proof, verification_method, evidence_basis,
  responsible_agency_type, for_regional, is_active
)
select
  'delhi-regional-advisory',
  c.id, null, 'suspected', 'advisory_monitoring', 'automatic',
  'Regional pollution: monitoring and public advisory protocol',
  'Confirm the elevated pollution is regionally driven (wind-rose attribution / low forecast local excess relative to background). No local enforcement action is appropriate. Issue a public advisory (health guidance, activity recommendations) and continue monitoring; escalate to state/regional coordination channels if sustained.',
  '[{"id":"advisory_issued","label":"Public advisory issued?","type":"boolean"},{"id":"monitoring_continued","label":"Monitoring continued at increased frequency?","type":"boolean"},{"id":"notes","label":"Notes","type":"text"}]'::jsonb,
  'None (advisory/communications, not field deployment)', 'None',
  30, 0, 500,
  'No expected reduction in ambient pollution — the source is not locally controllable. Reduces public exposure through behaviour, not emissions.', null, null,
  null, array['pm25','pm10'],
  'Local action has no material effect on regionally-transported pollution; a before/after comparison at a single local station is not a meaningful test of this playbook and will typically read inconclusive or ineffective by construction — that is expected, not a failure of the playbook.',
  'Copy or link of the advisory issued',
  'None locally meaningful; regional coordination outcome is out of scope for this phase',
  'expert_estimate', 'City communications / public health', true, true
from city_config c where c.city_code = 'delhi'
on conflict (slug) do nothing;
