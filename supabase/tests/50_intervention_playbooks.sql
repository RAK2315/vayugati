-- Phase 5: intervention playbooks — seed data, the playbook-tier evidence-level
-- gate, playbook_id/version/checklist snapshotting, usage-metric data, and RLS.
-- Run as `authenticated` (a superuser bypasses RLS and would make this suite
-- pass vacuously). This file seeds its own incident/report fixtures (distinct
-- ids from 40_intervention_and_impact.sql) so it can run standalone via run.sh.

create table if not exists t_ids (k text primary key, v bigint);
grant select on t_ids to authenticated;
truncate t_ids;

create or replace function as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p::text, 'role', 'authenticated')::text, false);
end $$;

reset role;

-- ---------- fixtures ----------
insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111','citizen@x.com'),
  ('22222222-2222-2222-2222-222222222222','officer@x.com'),
  ('44444444-4444-4444-4444-444444444444','cmd@x.com')
on conflict do nothing;

insert into profiles (id, role, ward_id, full_name) values
  ('11111111-1111-1111-1111-111111111111','citizen',1,'A Citizen'),
  ('22222222-2222-2222-2222-222222222222','field_officer',1,'Officer Singh'),
  ('44444444-4444-4444-4444-444444444444','commander',null,'Cmdr Rao')
on conflict (id) do update set role=excluded.role, ward_id=excluded.ward_id, full_name=excluded.full_name;

grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant execute on function record_impact_evaluation(bigint,bigint,double precision,double precision,int,text,double precision,text) to authenticated;

-- a suspected, a corroborated, and an officially_verified incident in ward 1
insert into incidents (id, ward_id, status, detection_method, source_confidence, summary)
values (9301, 1, 'detected', 'manual', 'suspected', 'suspected incident for playbook tests')
on conflict (id) do update set status='detected', source_confidence='suspected';

insert into incidents (id, ward_id, status, detection_method, source_confidence, summary)
values (9302, 1, 'evidence_gathering', 'manual', 'corroborated', 'corroborated incident for playbook tests')
on conflict (id) do update set status='evidence_gathering', source_confidence='corroborated';

insert into incidents (id, ward_id, status, detection_method, source_confidence, summary)
values (9303, 1, 'evidence_gathering', 'manual', 'officially_verified', 'verified incident for playbook tests')
on conflict (id) do update set status='evidence_gathering', source_confidence='officially_verified';

set role authenticated;

select 'TEST 20: seeded playbooks exist and are well-formed' as t;
do $$
declare n int;
begin
  perform as_user('44444444-4444-4444-4444-444444444444');
  select count(*) into n from intervention_playbooks where slug like 'delhi-%';
  if n = 6 then raise notice '20a PASS: all 6 seeded Delhi playbooks present';
  else raise notice '20a FAIL: found % (expected 6)', n; end if;

  select count(*) into n from intervention_playbooks
   where slug = 'delhi-regional-advisory' and for_regional and source_category is null;
  if n = 1 then raise notice '20b PASS: the regional playbook has no specific source category';
  else raise notice '20b FAIL'; end if;

  select count(*) into n from intervention_playbooks
   where slug = 'delhi-industrial-stop-work' and min_evidence_level = 'officially_verified' and action_type = 'stop_work';
  if n = 1 then raise notice '20c PASS: the one enforcement-tier seeded playbook is correctly tiered';
  else raise notice '20c FAIL'; end if;
end $$;

select 'TEST 21: playbook-tier evidence-level gate (Phase 5 addition to the trigger)' as t;
do $$
declare v_road_dust bigint; v_stop_work bigint; v_high_tier_inspect bigint; v_road_dust_action bigint;
begin
  perform as_user('44444444-4444-4444-4444-444444444444');
  select id into v_road_dust from intervention_playbooks where slug = 'delhi-road-dust-sweeping';
  select id into v_stop_work from intervention_playbooks where slug = 'delhi-industrial-stop-work';

  -- 21a: a corroborated-tier playbook is refused on a merely SUSPECTED incident
  -- (blocked by the pre-existing Phase 3 creation gate, which fires first).
  begin
    insert into actions (incident_id, ward_id, type, playbook_id, playbook_version, checklist_snapshot)
    select 9301, 1, action_type, id, version, checklist from intervention_playbooks where id = v_road_dust;
    raise notice '21a FAIL: playbook-based action created on a suspected incident';
  exception when check_violation then raise notice '21a PASS: blocked (suspected incident, pre-existing gate)';
  end;

  -- 21b: the road-dust playbook (needs corroborated) succeeds once corroborated.
  begin
    insert into actions (incident_id, ward_id, type, playbook_id, playbook_version, checklist_snapshot)
    select 9302, 1, action_type, id, version, checklist from intervention_playbooks where id = v_road_dust
    returning id into v_road_dust_action;
    raise notice '21b PASS: playbook-based action created on a corroborated incident (action %)', v_road_dust_action;
  exception when others then raise notice '21b FAIL: %', sqlerrm;
  end;

  -- 21c: the enforcement-tier playbook (stop_work, needs officially_verified)
  -- is refused on the merely CORROBORATED incident — by the NEW playbook-tier
  -- ordinal check specifically (the pre-existing enforcement-type check would
  -- ALSO refuse this, so 21d below isolates the ordinal check on its own).
  begin
    insert into actions (incident_id, ward_id, type, playbook_id, playbook_version, checklist_snapshot)
    select 9302, 1, action_type, id, version, checklist from intervention_playbooks where id = v_stop_work;
    raise notice '21c FAIL: enforcement-tier playbook used on a corroborated incident';
  exception when check_violation then raise notice '21c PASS: blocked (corroborated < officially_verified)';
  end;

  -- 21d: isolate the NEW ordinal check from the pre-existing enforcement-type
  -- check — a NON-enforcement action_type ('inspect') from a playbook
  -- deliberately mis-tiered to require officially_verified must STILL be
  -- refused on a corroborated incident. This is the "playbook-tier fidelity"
  -- gap the migration's comment describes: without this check, a playbook
  -- merely LABELLED as needing more evidence could be used below that label,
  -- even though its action_type never triggers the enforcement gate.
  insert into intervention_playbooks (slug, city_id, source_category, min_evidence_level, action_type, title, checklist)
  values ('test-high-tier-inspect', 1, 'road_dust', 'officially_verified', 'inspect', 'Test: over-tiered inspection', '[]'::jsonb)
  on conflict (slug) do update set min_evidence_level = 'officially_verified'
  returning id into v_high_tier_inspect;

  begin
    insert into actions (incident_id, ward_id, type, playbook_id, playbook_version, checklist_snapshot)
    select 9302, 1, action_type, id, version, checklist from intervention_playbooks where id = v_high_tier_inspect;
    raise notice '21d FAIL: over-tiered non-enforcement playbook used below its required evidence level';
  exception when check_violation then raise notice '21d PASS: blocked by the playbook-tier ordinal check alone (type is not enforcement)';
  end;

  -- 21e: the enforcement-tier playbook succeeds on the OFFICIALLY VERIFIED
  -- incident, but only once approved_by is set — the pre-existing enforcement
  -- gate is untouched by playbook selection, exactly as documented.
  begin
    insert into actions (incident_id, ward_id, type, playbook_id, playbook_version, checklist_snapshot)
    select 9303, 1, action_type, id, version, checklist from intervention_playbooks where id = v_stop_work;
    raise notice '21e FAIL: enforcement action created with no approver, even via a playbook';
  exception when check_violation then raise notice '21e PASS: blocked — still needs a named approver regardless of playbook';
  end;

  insert into actions (incident_id, ward_id, type, playbook_id, playbook_version, checklist_snapshot, approved_by, approval_level)
  select 9303, 1, action_type, id, version, checklist, '44444444-4444-4444-4444-444444444444', 'authorised_legal'
  from intervention_playbooks where id = v_stop_work;
  raise notice '21f PASS: enforcement playbook succeeds once verified AND approved';
end $$;

select 'TEST 22: playbook selection is stored and snapshotted correctly' as t;
do $$
declare
  v_playbook_id bigint; v_playbook_version int; v_checklist jsonb; v_action bigint;
  v_stored_id bigint; v_stored_version int; v_stored_checklist jsonb;
begin
  perform as_user('44444444-4444-4444-4444-444444444444');
  select id, version, checklist into v_playbook_id, v_playbook_version, v_checklist
    from intervention_playbooks where slug = 'delhi-construction-dust-inspection';

  insert into actions (incident_id, ward_id, type, playbook_id, playbook_version, checklist_snapshot, playbook_notes_override)
  select 9302, 1, action_type, id, version, checklist, 'Focus on the east gate specifically.'
  from intervention_playbooks where id = v_playbook_id
  returning id into v_action;
  insert into t_ids (k, v) values ('construction_action', v_action) on conflict (k) do update set v = excluded.v;
  insert into t_ids (k, v) values ('construction_playbook', v_playbook_id) on conflict (k) do update set v = excluded.v;

  select playbook_id, playbook_version, checklist_snapshot
    into v_stored_id, v_stored_version, v_stored_checklist
    from actions where id = v_action;

  if v_stored_id = v_playbook_id then raise notice '22a PASS: playbook_id stored on the action';
  else raise notice '22a FAIL'; end if;

  if v_stored_version = v_playbook_version then raise notice '22b PASS: playbook_version snapshotted';
  else raise notice '22b FAIL'; end if;

  if v_stored_checklist = v_checklist and jsonb_array_length(v_stored_checklist) > 0 then
    raise notice '22c PASS: checklist_snapshot matches the playbook''s checklist at creation time (% items)', jsonb_array_length(v_stored_checklist);
  else raise notice '22c FAIL: checklist snapshot did not match'; end if;

  -- 22d: editing the LIVE playbook's checklist afterwards must NOT retroactively
  -- change the already-created action's snapshot (that is the entire point of
  -- snapshotting rather than joining live at render time).
  update intervention_playbooks set checklist = '[{"id":"changed","label":"Different now","type":"boolean"}]'::jsonb
   where id = v_playbook_id;
  select checklist_snapshot into v_stored_checklist from actions where id = v_action;
  if v_stored_checklist = v_checklist then
    raise notice '22d PASS: action''s checklist snapshot is stable after the live playbook was edited';
  else raise notice '22d FAIL: snapshot drifted after a live playbook edit'; end if;
  -- restore the playbook for any later re-run within the same session
  update intervention_playbooks set checklist = v_checklist where id = v_playbook_id;
end $$;

select 'TEST 23: impact outcome feeds playbook usage metrics' as t;
do $$
declare v_action bigint; v_playbook bigint; v_status text;
begin
  perform as_user('44444444-4444-4444-4444-444444444444');
  select v into v_action from t_ids where k = 'construction_action';
  select v into v_playbook from t_ids where k = 'construction_playbook';

  update actions set workflow_status = 'completed', completed_at = now() where id = v_action;
  perform record_impact_evaluation(9302, v_action, 150, 80, 48, 'Station B', 0.9, 'good coverage');

  select workflow_status::text into v_status from actions where id = v_action;
  if v_status = 'effective' then
    raise notice '23a PASS: the evaluated outcome (effective) is readable via actions.playbook_id — this is exactly what a usage-metrics tally (tallyPlaybookUsage) aggregates client-side';
  else raise notice '23a FAIL: got %', v_status; end if;

  -- the batched usage query the client uses: all workflow_status values for this playbook_id
  if (select count(*) from actions where playbook_id = v_playbook and workflow_status = 'effective') = 1 then
    raise notice '23b PASS: usage-metrics query finds exactly 1 effective use of this playbook';
  else raise notice '23b FAIL'; end if;
end $$;

select 'TEST 24: citizens cannot read intervention_playbooks at all' as t;
do $$
declare n int;
begin
  perform as_user('11111111-1111-1111-1111-111111111111');
  select count(*) into n from intervention_playbooks;
  if n = 0 then raise notice '24a PASS: citizen has zero read on intervention_playbooks (no internal playbook/enforcement detail exposed)';
  else raise notice '24a FAIL: citizen can read % playbook row(s)', n; end if;

  -- unchanged Phase 2 policy, exercised here for the first time — field
  -- officers and commanders DO see playbooks (they need to, to select one).
  perform as_user('22222222-2222-2222-2222-222222222222');
  select count(*) into n from intervention_playbooks where slug like 'delhi-%';
  if n = 6 then raise notice '24b PASS: field officer can read the seeded playbooks';
  else raise notice '24b FAIL: field officer read % rows', n; end if;
end $$;

select 'TEST 25: citizens cannot write intervention_playbooks' as t;
do $$
begin
  perform as_user('11111111-1111-1111-1111-111111111111');
  begin
    insert into intervention_playbooks (slug, title, checklist) values ('citizen-attempt', 'Citizen attempt', '[]'::jsonb);
    raise notice '25a FAIL: citizen created a playbook';
  exception when others then raise notice '25a PASS: blocked (%)', sqlerrm;
  end;
end $$;

reset role;
reset request.jwt.claims;

-- cleanup the ad-hoc test playbook so re-running this file within the same
-- session stays idempotent at the row level too (the `on conflict (slug)`
-- above already makes the insert itself idempotent; this just keeps the
-- fixture set clean for a human inspecting the table after a manual run).
delete from intervention_playbooks where slug = 'test-high-tier-inspect';
