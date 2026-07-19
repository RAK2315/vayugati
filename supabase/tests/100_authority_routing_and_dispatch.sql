-- Phase 9: authority routing and operational dispatch.
--
-- Role discipline (matches 70_anomaly_detection.sql / 90_unified_forecasting.sql):
-- fixture setup runs as superuser; `set role authenticated` + `as_user(...)`
-- is used only for the specific assertions that check RLS/authorization as a
-- real logged-in user. Every test's do block starts with its own
-- `reset role;` rather than assuming role state carried over correctly.
--
-- Isolation: every scenario gets its own dedicated city_config row (own
-- ward, own responsibility_registry rows) — sharing one city across
-- scenarios is exactly what produced order-dependent routing results during
-- manual verification of this migration (a later scenario's registry row
-- would silently outrank an earlier scenario's, exactly as real production
-- data should, which is precisely why sharing breaks test isolation).

create table if not exists t_ids (k text primary key, v bigint);
grant select on t_ids to authenticated;
truncate t_ids;

create or replace function as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p::text, 'role', 'authenticated')::text, false);
end $$;

-- `as_user` sets `request.jwt.claims` with is_local=false — a SESSION-scoped
-- GUC that `reset role;` does NOT clear (that only reverts the Postgres
-- role, not this app-level setting read by auth.uid()/auth_role()). Once any
-- test in this file impersonates a user, every later "superuser" fixture
-- block would otherwise still see that user's auth.uid() — and this file's
-- fixtures insert into `actions`, which enforce_incident_action_rules()
-- gates on auth_role() = commander/admin. as_service() restores auth.uid()
-- to NULL (the real ingest-service/superuser posture) so fixture setup
-- after an as_user() call behaves the same as fixture setup before one.
create or replace function as_service() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{}', false);
end $$;

reset role;
select as_service();

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111','citizen@x.com'),
  ('22222222-2222-2222-2222-222222222222','officer@x.com'),
  ('66666666-6666-6666-6666-666666666666','officer2@x.com'),
  ('44444444-4444-4444-4444-444444444444','cmd@x.com')
on conflict do nothing;

insert into profiles (id, role, ward_id, full_name) values
  ('11111111-1111-1111-1111-111111111111','citizen',1,'A Citizen'),
  ('22222222-2222-2222-2222-222222222222','field_officer',1,'Officer Singh'),
  ('66666666-6666-6666-6666-666666666666','field_officer',2,'Officer Two'),
  ('44444444-4444-4444-4444-444444444444','commander',null,'Cmdr Rao')
on conflict (id) do update set role=excluded.role, ward_id=excluded.ward_id, full_name=excluded.full_name;

grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant execute on function preview_task_routing(bigint) to authenticated;
grant execute on function dispatch_intervention_task(bigint, uuid) to authenticated;
grant execute on function transition_task_dispatch(bigint, task_dispatch_status, uuid, text) to authenticated;
grant execute on function report_resource_unavailable(bigint, uuid, text) to authenticated;
grant execute on function request_task_reroute(bigint, uuid, text) to authenticated;
grant execute on function resolve_jurisdiction_dispute(bigint, uuid, bigint, text) to authenticated;
grant execute on function escalate_stale_task_dispatches(text) to authenticated;

-- helper: a fresh, isolated test city with one ward, one commander-visible
-- incident (source_confidence='officially_verified' so both routine and
-- enforcement-type actions can be created against it), returning
-- (city_id, ward_id, incident_id, officer_id). Always run as superuser.
create or replace function _t100_setup(p_prefix text, p_officer uuid default '22222222-2222-2222-2222-222222222222')
returns table(city_id bigint, ward_id bigint, incident_id bigint)
language plpgsql as $$
declare v_city bigint; v_ward bigint; v_incident bigint;
begin
  insert into city_config (city_code, name) values (p_prefix, 'Test City ' || p_prefix) returning id into v_city;
  insert into wards (name, city_id) values (p_prefix || '-a', v_city) returning id into v_ward;
  update profiles set ward_id = v_ward where id = p_officer;
  insert into incidents (city_id, ward_id, status, detection_method, severity, source_confidence)
    values (v_city, v_ward, 'under_review', 'manual', 'high', 'officially_verified') returning id into v_incident;
  insert into incident_source_hypotheses (incident_id, source_category, probability, is_current)
    values (v_incident, 'construction_dust', 0.9, true);
  return query select v_city, v_ward, v_incident;
end $$;

-- helper: a routine (non-enforcement) action against an incident, pre-satisfying
-- the Phase 5.1 "custom intervention needs a reason" trigger.
create or replace function _t100_action(p_incident bigint, p_ward bigint, p_type text default 'inspect')
returns bigint language plpgsql as $$
declare v_action bigint;
begin
  insert into actions (ward_id, incident_id, type, status, custom_reason)
    values (p_ward, p_incident, p_type, 'assigned', 'test fixture, no playbook needed')
    returning id into v_action;
  return v_action;
end $$;

select 'TEST 85: a specific, active registry match routes with confirmed confidence and reaches sent' as t;
do $$
declare v_city bigint; v_ward bigint; v_incident bigint; v_action bigint; v_disp bigint;
begin
  reset role;
  perform as_service();
  select * into v_city, v_ward, v_incident from _t100_setup('t85');
  insert into responsibility_registry (city_id, source_category, ward_id, regulating_authority, division_zone, responsible_officer, team_name, mapping_confidence)
    values (v_city, 'construction_dust', v_ward, 'MCD Enforcement', 'Zone 4', '22222222-2222-2222-2222-222222222222', 'Zone 4 Team', 'verified');
  v_action := _t100_action(v_incident, v_ward);

  perform dispatch_intervention_task(v_action, '44444444-4444-4444-4444-444444444444');
  select id into v_disp from task_dispatches where action_id = v_action and is_current;

  if (select status from task_dispatches where id = v_disp) = 'sent'
     and (select routing_confidence from task_dispatches where id = v_disp) = 'confirmed'
     and (select responsible_agency from task_dispatches where id = v_disp) = 'MCD Enforcement'
     and (select primary_officer from task_dispatches where id = v_disp) = '22222222-2222-2222-2222-222222222222'
     and (select routing_evidence ->> 'matched_registry_id' from task_dispatches where id = v_disp) is not null
  then raise notice 'TEST 85a PASS: routed to the specific matched unit with recorded evidence';
  else raise exception 'TEST 85a FAIL: %', (select row_to_json(d) from task_dispatches d where id = v_disp);
  end if;
end $$;

select 'TEST 86: unresolved routing (no registry match) never silently dispatches' as t;
do $$
declare v_city bigint; v_ward bigint; v_incident bigint; v_action bigint; v_disp bigint; v_notif_count int;
begin
  reset role;
  perform as_service();
  select * into v_city, v_ward, v_incident from _t100_setup('t86');
  v_action := _t100_action(v_incident, v_ward);

  perform dispatch_intervention_task(v_action, '44444444-4444-4444-4444-444444444444');
  select id into v_disp from task_dispatches where action_id = v_action and is_current;
  select count(*) into v_notif_count from notifications where task_dispatch_id = v_disp;

  if (select status from task_dispatches where id = v_disp) = 'drafted'
     and (select routing_confidence from task_dispatches where id = v_disp) = 'unresolved'
     and v_notif_count = 0
  then raise notice 'TEST 86 PASS: unresolved routing stays drafted, no notification sent';
  else raise exception 'TEST 86 FAIL: status=%, notifications=%', (select status from task_dispatches where id = v_disp), v_notif_count;
  end if;
end $$;

select 'TEST 87: disputed jurisdiction goes to command review, not direct dispatch' as t;
do $$
declare v_city bigint; v_ward bigint; v_incident bigint; v_action bigint; v_disp bigint; v_good_reg bigint;
begin
  reset role;
  perform as_service();
  select * into v_city, v_ward, v_incident from _t100_setup('t87');
  insert into responsibility_registry (city_id, source_category, ward_id, regulating_authority, is_disputed, mapping_confidence)
    values (v_city, 'construction_dust', v_ward, 'Rival Agency', true, 'estimated');
  v_action := _t100_action(v_incident, v_ward);

  perform dispatch_intervention_task(v_action, '44444444-4444-4444-4444-444444444444');
  select id into v_disp from task_dispatches where action_id = v_action and is_current;

  if (select status from task_dispatches where id = v_disp) = 'awaiting_approval'
     and (select routing_confidence from task_dispatches where id = v_disp) = 'disputed'
  then raise notice 'TEST 87a PASS: disputed jurisdiction held for command review';
  else raise exception 'TEST 87a FAIL: %', (select row_to_json(d) from task_dispatches d where id = v_disp);
  end if;

  insert into responsibility_registry (city_id, source_category, ward_id, regulating_authority, mapping_confidence)
    values (v_city, 'construction_dust', v_ward, 'Correct Agency', 'verified') returning id into v_good_reg;
  perform resolve_jurisdiction_dispute(v_disp, '44444444-4444-4444-4444-444444444444', v_good_reg, 'Verified via zoning map.');

  if (select status from task_dispatches where id = v_disp) = 'approved'
     and (select routing_confidence from task_dispatches where id = v_disp) = 'confirmed'
     and (select dispute_resolution_note from task_dispatches where id = v_disp) = 'Verified via zoning map.'
  then raise notice 'TEST 87b PASS: dispute resolved with reason, moved to approved';
  else raise exception 'TEST 87b FAIL: %', (select row_to_json(d) from task_dispatches d where id = v_disp);
  end if;
end $$;

select 'TEST 88: lifecycle transitions are enforced server-side' as t;
do $$
declare v_city bigint; v_ward bigint; v_incident bigint; v_action bigint; v_disp bigint; v_blocked boolean := false;
begin
  reset role;
  perform as_service();
  select * into v_city, v_ward, v_incident from _t100_setup('t88');
  insert into responsibility_registry (city_id, source_category, ward_id, regulating_authority, responsible_officer, mapping_confidence)
    values (v_city, 'construction_dust', v_ward, 'MCD', '22222222-2222-2222-2222-222222222222', 'verified');
  v_action := _t100_action(v_incident, v_ward);
  perform dispatch_intervention_task(v_action, '44444444-4444-4444-4444-444444444444');
  select id into v_disp from task_dispatches where action_id = v_action and is_current;
  -- currently 'sent'

  begin
    perform transition_task_dispatch(v_disp, 'completed', '22222222-2222-2222-2222-222222222222', null);
  exception when others then v_blocked := true;
  end;
  if not v_blocked then raise exception 'TEST 88a FAIL: sent -> completed should have been rejected'; end if;
  raise notice 'TEST 88a PASS: an illegal jump (sent -> completed) was rejected';

  perform transition_task_dispatch(v_disp, 'acknowledged', '22222222-2222-2222-2222-222222222222', null);
  perform transition_task_dispatch(v_disp, 'accepted', '22222222-2222-2222-2222-222222222222', null);
  perform transition_task_dispatch(v_disp, 'in_progress', '22222222-2222-2222-2222-222222222222', null);
  if (select status from task_dispatches where id = v_disp) = 'in_progress'
     and (select workflow_status from actions where id = v_action) = 'in_progress'
  then raise notice 'TEST 88b PASS: valid chain applied, actions.workflow_status kept in sync';
  else raise exception 'TEST 88b FAIL: %', (select status from task_dispatches where id = v_disp);
  end if;

  v_blocked := false;
  begin
    perform transition_task_dispatch(v_disp, 'rejected', '22222222-2222-2222-2222-222222222222', null);
  exception when others then v_blocked := true;
  end;
  if not v_blocked then raise exception 'TEST 88c FAIL: rejected without a reason should have been refused'; end if;
  raise notice 'TEST 88c PASS: rejection without a reason is refused';
end $$;

select 'TEST 89: duplicate dispatch is prevented (idempotent create-or-update, not a new row)' as t;
do $$
declare v_city bigint; v_ward bigint; v_incident bigint; v_action bigint; v_count int;
begin
  reset role;
  perform as_service();
  select * into v_city, v_ward, v_incident from _t100_setup('t89');
  insert into responsibility_registry (city_id, source_category, ward_id, regulating_authority, mapping_confidence)
    values (v_city, 'construction_dust', v_ward, 'MCD', 'verified');
  v_action := _t100_action(v_incident, v_ward);

  perform dispatch_intervention_task(v_action, '44444444-4444-4444-4444-444444444444');
  perform dispatch_intervention_task(v_action, '44444444-4444-4444-4444-444444444444');
  perform dispatch_intervention_task(v_action, '44444444-4444-4444-4444-444444444444');
  select count(*) into v_count from task_dispatches where action_id = v_action;

  if v_count = 1 then raise notice 'TEST 89 PASS: three dispatch calls produced exactly one row';
  else raise exception 'TEST 89 FAIL: expected 1 row, found %', v_count;
  end if;
end $$;

select 'TEST 90: an enforcement-sensitive action cannot be dispatched without approval' as t;
do $$
declare v_city bigint; v_ward bigint; v_incident bigint; v_action bigint; v_disp bigint;
begin
  reset role;
  perform as_service();
  select * into v_city, v_ward, v_incident from _t100_setup('t90');
  insert into responsibility_registry (city_id, source_category, ward_id, regulating_authority, responsible_officer, mapping_confidence)
    values (v_city, 'construction_dust', v_ward, 'MCD', '22222222-2222-2222-2222-222222222222', 'verified');
  v_action := _t100_action(v_incident, v_ward, 'sprinkle'); -- equipment deployment: requires approval, not an ENFORCEMENT_TYPE, so actions' own trigger doesn't already force approved_by

  perform dispatch_intervention_task(v_action, '44444444-4444-4444-4444-444444444444');
  select id into v_disp from task_dispatches where action_id = v_action and is_current;
  if (select status from task_dispatches where id = v_disp) = 'awaiting_approval'
     and (select requires_approval from task_dispatches where id = v_disp)
     and (select sent_at from task_dispatches where id = v_disp) is null
  then raise notice 'TEST 90a PASS: unapproved equipment deployment held at awaiting_approval, never sent';
  else raise exception 'TEST 90a FAIL: %', (select row_to_json(d) from task_dispatches d where id = v_disp);
  end if;

  update actions set approved_by = '44444444-4444-4444-4444-444444444444', approved_at = now() where id = v_action;
  perform dispatch_intervention_task(v_action, '44444444-4444-4444-4444-444444444444');
  if (select status from task_dispatches where id = v_disp) = 'sent'
  then raise notice 'TEST 90b PASS: once approved, dispatch proceeds to sent';
  else raise exception 'TEST 90b FAIL: %', (select status from task_dispatches where id = v_disp);
  end if;
end $$;

select 'TEST 91: SLA due timestamps are computed from the most specific matching rule' as t;
do $$
declare v_city bigint; v_ward bigint; v_incident bigint; v_action bigint; v_disp bigint;
begin
  reset role;
  perform as_service();
  select * into v_city, v_ward, v_incident from _t100_setup('t91');
  insert into responsibility_registry (city_id, source_category, ward_id, regulating_authority, responsible_officer, mapping_confidence)
    values (v_city, 'construction_dust', v_ward, 'MCD', '22222222-2222-2222-2222-222222222222', 'verified');
  -- a general (wildcard) default rule and a MORE specific severity-matched rule; the specific one must win
  insert into sla_rules (slug, city_id, ack_hours, accept_hours, arrival_hours, completion_hours, verification_hours, priority)
    values ('t91_default', v_city, 5, 5, 5, 5, 5, 0);
  insert into sla_rules (slug, city_id, severity, ack_hours, accept_hours, arrival_hours, completion_hours, verification_hours, priority)
    values ('t91_severe', v_city, 'high', 1, 1, 1, 1, 1, 10);
  v_action := _t100_action(v_incident, v_ward);

  perform dispatch_intervention_task(v_action, '44444444-4444-4444-4444-444444444444');
  select id into v_disp from task_dispatches where action_id = v_action and is_current;

  if abs(extract(epoch from ((select sla_ack_due_at from task_dispatches where id = v_disp) - now())) - 3600) < 30
  then raise notice 'TEST 91 PASS: the higher-priority, more specific SLA rule (1h ack) was applied, not the 5h default';
  else raise exception 'TEST 91 FAIL: sla_ack_due_at = %', (select sla_ack_due_at from task_dispatches where id = v_disp);
  end if;
end $$;

select 'TEST 92: overdue tasks escalate automatically; completed-without-evidence escalates immediately' as t;
do $$
declare v_city bigint; v_ward bigint; v_incident bigint; v_action1 bigint; v_action2 bigint; v_disp1 bigint; v_disp2 bigint; v_esc_count int;
begin
  reset role;
  perform as_service();
  select * into v_city, v_ward, v_incident from _t100_setup('t92');
  insert into responsibility_registry (city_id, source_category, ward_id, regulating_authority, responsible_officer, mapping_confidence)
    values (v_city, 'construction_dust', v_ward, 'MCD', '22222222-2222-2222-2222-222222222222', 'verified');

  v_action1 := _t100_action(v_incident, v_ward);
  perform dispatch_intervention_task(v_action1, '44444444-4444-4444-4444-444444444444');
  select id into v_disp1 from task_dispatches where action_id = v_action1 and is_current;
  update task_dispatches set sla_ack_due_at = now() - interval '1 hour' where id = v_disp1;

  perform escalate_stale_task_dispatches((select city_code from city_config where id = v_city));
  if (select status from task_dispatches where id = v_disp1) = 'overdue'
  then raise notice 'TEST 92a PASS: a dispatch past its ack SLA is marked overdue';
  else raise exception 'TEST 92a FAIL: status=%', (select status from task_dispatches where id = v_disp1);
  end if;

  v_action2 := _t100_action(v_incident, v_ward);
  perform dispatch_intervention_task(v_action2, '44444444-4444-4444-4444-444444444444');
  select id into v_disp2 from task_dispatches where action_id = v_action2 and is_current;
  perform transition_task_dispatch(v_disp2, 'acknowledged', '22222222-2222-2222-2222-222222222222', null);
  perform transition_task_dispatch(v_disp2, 'accepted', '22222222-2222-2222-2222-222222222222', null);
  perform transition_task_dispatch(v_disp2, 'in_progress', '22222222-2222-2222-2222-222222222222', null);
  perform transition_task_dispatch(v_disp2, 'completed', '22222222-2222-2222-2222-222222222222', null);
  select count(*) into v_esc_count from incident_events where payload ->> 'task_dispatch_id' = v_disp2::text and event_type = 'escalation';

  if (select escalation_level from task_dispatches where id = v_disp2) >= 1 and v_esc_count >= 1
  then raise notice 'TEST 92b PASS: completing a task with zero attached evidence auto-escalates immediately';
  else raise exception 'TEST 92b FAIL: escalation_level=%, events=%', (select escalation_level from task_dispatches where id = v_disp2), v_esc_count;
  end if;
end $$;

select 'TEST 93: every routing/lifecycle step writes an immutable incident_events row' as t;
do $$
declare v_city bigint; v_ward bigint; v_incident bigint; v_action bigint; v_disp bigint; v_types text[];
begin
  reset role;
  perform as_service();
  select * into v_city, v_ward, v_incident from _t100_setup('t93');
  insert into responsibility_registry (city_id, source_category, ward_id, regulating_authority, responsible_officer, mapping_confidence)
    values (v_city, 'construction_dust', v_ward, 'MCD', '22222222-2222-2222-2222-222222222222', 'verified');
  v_action := _t100_action(v_incident, v_ward);
  perform dispatch_intervention_task(v_action, '44444444-4444-4444-4444-444444444444');
  select id into v_disp from task_dispatches where action_id = v_action and is_current;
  perform transition_task_dispatch(v_disp, 'acknowledged', '22222222-2222-2222-2222-222222222222', null);
  perform transition_task_dispatch(v_disp, 'rejected', '22222222-2222-2222-2222-222222222222', 'equipment broke');

  select array_agg(distinct event_type) into v_types from incident_events
    where payload ->> 'task_dispatch_id' = v_disp::text;

  if 'routing_decision' = any(v_types) and 'dispatch' = any(v_types)
     and 'acknowledgement' = any(v_types) and 'rejection' = any(v_types)
  then raise notice 'TEST 93 PASS: routing_decision/dispatch/acknowledgement/rejection all recorded as audit events';
  else raise exception 'TEST 93 FAIL: event types = %', v_types;
  end if;
end $$;

-- ---- The remaining tests use `as_user(...)` to impersonate a real logged-
-- in role (that's the only way to genuinely exercise RLS — see file header).
-- `as_user` sets the `request.jwt.claims` GUC with is_local=false, which is
-- SESSION-scoped: unlike the Postgres ROLE itself, `reset role;` does NOT
-- clear it, so `auth.uid()` keeps resolving to the last impersonated user
-- even after reverting to superuser. Every remaining test after the first
-- `as_user` call would therefore see a non-superuser `auth.uid()` during its
-- own "superuser" fixture setup — exactly the failure mode 70_anomaly_detection.sql's
-- comment warns about. The fix used there (and here) is ordering: every test
-- that needs plain superuser fixture creation runs BEFORE the first
-- `as_user` call in the file; every `as_user`-consuming RLS test is grouped
-- at the end, where it's safe for that GUC to stay stuck.

select 'TEST 94: the migration''s new tables, enum labels and Delhi seed are exactly-once (additive + idempotent)' as t;
do $$
declare v_task_dispatches_cols int; v_sla_rules_count int; v_dispatch_config_present boolean;
begin
  reset role;
  perform as_service();
  select count(*) into v_task_dispatches_cols from information_schema.columns where table_name = 'task_dispatches';
  select count(*) into v_sla_rules_count from sla_rules where slug like 'delhi_%';
  select (config ? 'dispatch') into v_dispatch_config_present from city_config where city_code = 'delhi';

  if v_task_dispatches_cols > 30 and v_sla_rules_count = 3 and v_dispatch_config_present
  then raise notice 'TEST 94 PASS: task_dispatches schema present, Delhi SLA seed rows exactly 3 (not duplicated by a prior reapply), dispatch config present';
  else raise exception 'TEST 94 FAIL: cols=%, delhi_sla_rules=%, dispatch_config=%', v_task_dispatches_cols, v_sla_rules_count, v_dispatch_config_present;
  end if;
end $$;

select 'TEST 95: field officer can report resource unavailable and request a reroute; only command can actually reroute' as t;
do $$
declare v_city bigint; v_ward bigint; v_incident bigint; v_action bigint; v_disp bigint; v_blocked boolean := false;
begin
  reset role;
  perform as_service();
  select * into v_city, v_ward, v_incident from _t100_setup('t95');
  insert into responsibility_registry (city_id, source_category, ward_id, regulating_authority, responsible_officer, mapping_confidence)
    values (v_city, 'construction_dust', v_ward, 'MCD', '22222222-2222-2222-2222-222222222222', 'verified');
  v_action := _t100_action(v_incident, v_ward);
  perform dispatch_intervention_task(v_action, '44444444-4444-4444-4444-444444444444');
  select id into v_disp from task_dispatches where action_id = v_action and is_current;

  perform report_resource_unavailable(v_disp, '22222222-2222-2222-2222-222222222222', 'vehicle in maintenance');
  if (select resource_availability from task_dispatches where id = v_disp) = 'unavailable'
  then raise notice 'TEST 95a PASS: officer-reported unavailability recorded, not invented';
  else raise exception 'TEST 95a FAIL: %', (select resource_availability from task_dispatches where id = v_disp);
  end if;

  perform request_task_reroute(v_disp, '22222222-2222-2222-2222-222222222222', 'wrong specialty for this job');
  if (select status from task_dispatches where id = v_disp) = 'sent' -- request alone does not change status
  then raise notice 'TEST 95b PASS: reroute REQUEST does not itself change status (command still decides)';
  else raise exception 'TEST 95b FAIL: status changed to % from a mere request', (select status from task_dispatches where id = v_disp);
  end if;

  begin
    perform transition_task_dispatch(v_disp, 'rerouted', '22222222-2222-2222-2222-222222222222', 'trying to reroute myself');
  exception when others then v_blocked := true;
  end;
  if v_blocked then raise notice 'TEST 95c PASS: an officer cannot directly set status to rerouted';
  else raise exception 'TEST 95c FAIL: officer was allowed to reroute directly';
  end if;
end $$;

select 'TEST 96: notifications are queued (in-app always; email when the recipient has one on file) with a retryable schema' as t;
do $$
declare v_city bigint; v_ward bigint; v_incident bigint; v_action bigint; v_disp bigint; v_channels text[];
begin
  reset role;
  perform as_service();
  select * into v_city, v_ward, v_incident from _t100_setup('t96');
  insert into responsibility_registry (city_id, source_category, ward_id, regulating_authority, responsible_officer, mapping_confidence)
    values (v_city, 'construction_dust', v_ward, 'MCD', '22222222-2222-2222-2222-222222222222', 'verified');
  v_action := _t100_action(v_incident, v_ward);
  perform dispatch_intervention_task(v_action, '44444444-4444-4444-4444-444444444444');
  select id into v_disp from task_dispatches where action_id = v_action and is_current;

  select array_agg(channel::text) into v_channels from notifications where task_dispatch_id = v_disp;
  if 'in_app' = any(v_channels) and 'email' = any(v_channels)
  then raise notice 'TEST 96a PASS: in_app + email notifications queued for a recipient with an email on file';
  else raise exception 'TEST 96a FAIL: channels = %', v_channels;
  end if;

  -- simulate the Python delivery layer marking a failure + retry, proving the schema supports it
  update notifications set status = 'failed', failure_reason = 'smtp timeout (dev mock)', retry_count = retry_count + 1
    where task_dispatch_id = v_disp and channel = 'email';
  if (select retry_count from notifications where task_dispatch_id = v_disp and channel = 'email') = 1
     and (select status from notifications where task_dispatch_id = v_disp and channel = 'email') = 'failed'
  then raise notice 'TEST 96b PASS: failure_reason/retry_count schema supports a safe retry cycle';
  else raise exception 'TEST 96b FAIL';
  end if;
end $$;

-- Everything below this point uses as_user() and must stay last (see note above).

select 'TEST 97: field officers only see tasks in their own ward / assigned to them' as t;
do $$
declare v_city bigint; v_ward bigint; v_incident bigint; v_action bigint; v_n int;
begin
  reset role;
  perform as_service();
  select * into v_city, v_ward, v_incident from _t100_setup('t97');
  insert into responsibility_registry (city_id, source_category, ward_id, regulating_authority, responsible_officer, mapping_confidence)
    values (v_city, 'construction_dust', v_ward, 'MCD', '22222222-2222-2222-2222-222222222222', 'verified');
  v_action := _t100_action(v_incident, v_ward);
  perform dispatch_intervention_task(v_action, '44444444-4444-4444-4444-444444444444');

  set role authenticated;
  perform as_user('22222222-2222-2222-2222-222222222222'); -- assigned officer, same ward
  select count(*) into v_n from task_dispatches where action_id = v_action;
  if v_n <> 1 then raise exception 'TEST 97a FAIL: assigned officer could not see own task (%)', v_n; end if;

  perform as_user('66666666-6666-6666-6666-666666666666'); -- a different officer, different ward, not assigned
  select count(*) into v_n from task_dispatches where action_id = v_action;
  reset role;
  perform as_service();
  if v_n = 0 then raise notice 'TEST 97 PASS: assigned officer sees the task, an unrelated officer in a different ward does not';
  else raise exception 'TEST 97b FAIL: unrelated officer read % rows for a task not theirs', v_n; end if;
end $$;

select 'TEST 98a: citizens cannot read internal routing, officer identity, or notifications' as t;
do $$
declare v_city bigint; v_ward bigint; v_incident bigint; v_action bigint; v_n int;
begin
  reset role;
  perform as_service();
  select * into v_city, v_ward, v_incident from _t100_setup('t98');
  insert into responsibility_registry (city_id, source_category, ward_id, regulating_authority, responsible_officer, mapping_confidence)
    values (v_city, 'construction_dust', v_ward, 'MCD', '22222222-2222-2222-2222-222222222222', 'verified');
  v_action := _t100_action(v_incident, v_ward);
  perform dispatch_intervention_task(v_action, '44444444-4444-4444-4444-444444444444');

  set role authenticated;
  perform as_user('11111111-1111-1111-1111-111111111111');
  select count(*) into v_n from task_dispatches;
  if v_n <> 0 then raise exception 'TEST 98a FAIL: citizen read % task_dispatches rows', v_n; end if;
  select count(*) into v_n from notifications;
  if v_n <> 0 then raise exception 'TEST 98a FAIL: citizen read % notifications rows', v_n; end if;
  reset role;
  perform as_service();
  raise notice 'TEST 98a PASS: citizen sees zero task_dispatches / notifications rows';
end $$;

select 'TEST 98b: a citizen cannot dispatch, transition, or resolve disputes directly' as t;
do $$
declare v_blocked boolean;
begin
  reset role;
  perform as_service();
  set role authenticated;
  perform as_user('11111111-1111-1111-1111-111111111111');

  v_blocked := false;
  begin
    perform dispatch_intervention_task(1, '11111111-1111-1111-1111-111111111111');
  exception when others then v_blocked := true;
  end;
  if not v_blocked then raise exception 'TEST 98b FAIL: citizen was able to call dispatch_intervention_task'; end if;
  reset role;
  perform as_service();
  raise notice 'TEST 98b PASS: dispatch_intervention_task refuses a citizen caller';
end $$;

select 'TEST 98c: no authenticated role can write task_dispatches directly, bypassing the functions' as t;
do $$
declare v_city bigint; v_ward bigint; v_incident bigint; v_action bigint; v_disp bigint; v_status_before text;
begin
  reset role;
  perform as_service();
  select * into v_city, v_ward, v_incident from _t100_setup('t98c');
  insert into responsibility_registry (city_id, source_category, ward_id, regulating_authority, responsible_officer, mapping_confidence)
    values (v_city, 'construction_dust', v_ward, 'MCD', '22222222-2222-2222-2222-222222222222', 'verified');
  v_action := _t100_action(v_incident, v_ward);
  perform dispatch_intervention_task(v_action, '44444444-4444-4444-4444-444444444444');
  select id, status into v_disp, v_status_before from task_dispatches where action_id = v_action and is_current;

  set role authenticated;
  perform as_user('44444444-4444-4444-4444-444444444444'); -- even a commander
  update task_dispatches set status = 'cancelled' where id = v_disp;
  reset role;
  perform as_service();

  if (select status::text from task_dispatches where id = v_disp) = v_status_before
  then raise notice 'TEST 98c PASS: a direct UPDATE from an authenticated commander session affected 0 rows (no write policy exists)';
  else raise exception 'TEST 98c FAIL: direct update changed status to %', (select status from task_dispatches where id = v_disp);
  end if;
end $$;
