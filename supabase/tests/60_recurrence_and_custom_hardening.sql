-- Phase 5.1: citizen recurrence reporting + custom intervention hardening.
-- Run as `authenticated` (a superuser bypasses RLS and would make this suite
-- pass vacuously). This file seeds its own incident/report fixtures (distinct
-- ids from every other test file) so it can run standalone via run.sh.

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
  ('33333333-3333-3333-3333-333333333333','citizen2@x.com'),
  ('22222222-2222-2222-2222-222222222222','officer@x.com'),
  ('55555555-5555-5555-5555-555555555555','officer2@x.com'),
  ('44444444-4444-4444-4444-444444444444','cmd@x.com')
on conflict do nothing;

insert into profiles (id, role, ward_id, full_name) values
  ('11111111-1111-1111-1111-111111111111','citizen',1,'A Citizen'),
  ('33333333-3333-3333-3333-333333333333','citizen',1,'Another Citizen'),
  ('22222222-2222-2222-2222-222222222222','field_officer',1,'Officer Singh'),
  ('55555555-5555-5555-5555-555555555555','field_officer',2,'Officer Two'),
  ('44444444-4444-4444-4444-444444444444','commander',null,'Cmdr Rao')
on conflict (id) do update set role=excluded.role, ward_id=excluded.ward_id, full_name=excluded.full_name;

grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant execute on function submit_incident_recurrence_report(bigint, text, text, double precision, double precision, text) to authenticated;
grant execute on function list_my_recurrence_reports(bigint) to authenticated;

-- closed incidents used across the recurrence-reporting tests, each with its
-- own citizen report so ownership never has to be shared across tests
insert into incidents (id, ward_id, status, detection_method, source_confidence, summary, closed_at, lat, lng)
values (9401, 1, 'closed', 'manual', 'officially_verified', 'closed incident 9401 (submit/duplicate/reopen)', now() - interval '2 days', 28.85, 77.09)
on conflict (id) do update set status='closed', closed_at=excluded.closed_at;

insert into incidents (id, ward_id, status, detection_method, source_confidence, summary, closed_at)
values (9402, 1, 'closed', 'manual', 'officially_verified', 'closed incident 9402 (review transitions)', now() - interval '5 days')
on conflict (id) do update set status='closed', closed_at=excluded.closed_at;

insert into incidents (id, ward_id, status, detection_method, source_confidence, summary, closed_at, lat, lng)
values (9403, 1, 'closed', 'manual', 'officially_verified', 'closed incident 9403 (new linked incident)', now() - interval '40 days', 28.85, 77.09)
on conflict (id) do update set status='closed', closed_at=excluded.closed_at;

insert into incidents (id, ward_id, status, detection_method, source_confidence, summary)
values (9404, 1, 'evidence_gathering', 'manual', 'corroborated', 'open incident 9404 (merge target / not-closed check)')
on conflict (id) do update set status='evidence_gathering';

insert into incidents (id, ward_id, status, detection_method, source_confidence, summary, closed_at)
values (9409, 1, 'closed', 'manual', 'officially_verified', 'closed incident 9409 (merge source)', now() - interval '1 day')
on conflict (id) do update set status='closed', closed_at=excluded.closed_at;

-- incidents used only for custom-intervention-hardening tests
insert into incidents (id, ward_id, status, detection_method, source_confidence, summary)
values (9405, 1, 'detected', 'manual', 'suspected', 'suspected incident 9405 (custom, evidence-level gate)')
on conflict (id) do update set status='detected', source_confidence='suspected';

insert into incidents (id, ward_id, status, detection_method, source_confidence, summary)
values (9406, 1, 'evidence_gathering', 'manual', 'corroborated', 'corroborated incident 9406 (custom, commander-only + reason + enforcement-tier)')
on conflict (id) do update set status='evidence_gathering', source_confidence='corroborated';

insert into incidents (id, ward_id, status, detection_method, source_confidence, summary)
values (9407, 1, 'evidence_gathering', 'manual', 'officially_verified', 'verified incident 9407 (custom, approver required)')
on conflict (id) do update set status='evidence_gathering', source_confidence='officially_verified';

insert into incidents (id, ward_id, status, detection_method, source_confidence, classification, summary)
values (9408, 1, 'evidence_gathering', 'manual', 'officially_verified', 'regional', 'regional incident 9408 (custom, classification compatibility)')
on conflict (id) do update set status='evidence_gathering', source_confidence='officially_verified', classification='regional';

insert into reports (id, reporter_id, ward_id, description, incident_id) values
  (9601, '11111111-1111-1111-1111-111111111111', 1, 'report on 9401', 9401),
  (9602, '11111111-1111-1111-1111-111111111111', 1, 'report on 9402', 9402),
  (9603, '11111111-1111-1111-1111-111111111111', 1, 'report on 9403', 9403),
  (9604, '11111111-1111-1111-1111-111111111111', 1, 'report on 9409', 9409)
on conflict (id) do update set incident_id = excluded.incident_id;

set role authenticated;

select 'TEST 26: citizen recurrence report — submit, closed-only, ownership, no auto-reopen/enforcement' as t;
do $$
declare v_report_id bigint; v_status text; v_action_count int; v_public boolean;
begin
  perform as_user('11111111-1111-1111-1111-111111111111');

  -- 26a: a citizen not linked to 9404 (and 9404 is not closed anyway) is refused.
  begin
    perform submit_incident_recurrence_report(9404, 'returned', null, null, null, null);
    raise notice '26a FAIL: recurrence accepted on a non-closed incident';
  exception when others then raise notice '26a PASS: blocked (%)', sqlerrm;
  end;

  -- 26b: citizen linked to 9401 (closed) may submit.
  select submit_incident_recurrence_report(9401, 'returned', 'Smell is back near the market', 28.851, 77.091, null)
    into v_report_id;
  insert into t_ids (k, v) values ('report_9401', v_report_id) on conflict (k) do update set v = excluded.v;
  raise notice '26b PASS: recurrence report % submitted on closed incident 9401', v_report_id;

  -- 26d: a citizen with NO report linked to 9401 is refused, even though 9401 is closed.
  perform as_user('33333333-3333-3333-3333-333333333333');
  begin
    perform submit_incident_recurrence_report(9401, 'returned', null, null, null, null);
    raise notice '26d FAIL: unlinked citizen could report recurrence';
  exception when others then raise notice '26d PASS: blocked (%)', sqlerrm;
  end;

  -- 26e/26f/26g check the incident's own state as the commander, whose read
  -- is unfiltered — 26d deliberately left the session as an unlinked citizen,
  -- who cannot read incident 9401 at all under RLS.
  perform as_user('44444444-4444-4444-4444-444444444444');

  -- 26e: the incident itself must NOT have been auto-reopened by the report.
  select status::text into v_status from incidents where id = 9401;
  if v_status = 'closed' then raise notice '26e PASS: incident 9401 is still closed after a recurrence report';
  else raise notice '26e FAIL: incident status is %', v_status; end if;

  -- 26f: no enforcement task (actions row) was created by the report either.
  select count(*) into v_action_count from actions where incident_id = 9401;
  if v_action_count = 0 then raise notice '26f PASS: no actions row was created by the recurrence report';
  else raise notice '26f FAIL: % actions row(s) exist on 9401', v_action_count; end if;

  -- 26g: a public event was written to the ORIGINAL incident's timeline.
  select is_public into v_public from incident_events where incident_id = 9401 and event_type = 'recurrence_submitted' limit 1;
  if v_public is true then raise notice '26g PASS: recurrence_submitted event is public and on the original incident';
  else raise notice '26g FAIL: no public recurrence_submitted event found'; end if;
end $$;

select 'TEST 27: citizen RLS scoping on recurrence reports' as t;
do $$
declare n int; v_report_id bigint;
begin
  select v into v_report_id from t_ids where k = 'report_9401';

  -- 27a: a citizen has ZERO direct read on incident_recurrence_reports — the
  -- table itself, not just the row — they must go through list_my_recurrence_reports.
  perform as_user('11111111-1111-1111-1111-111111111111');
  select count(*) into n from incident_recurrence_reports;
  if n = 0 then raise notice '27a PASS: citizen has zero direct read on incident_recurrence_reports';
  else raise notice '27a FAIL: citizen can read % row(s) directly', n; end if;

  -- 27b: list_my_recurrence_reports returns exactly their own report on 9401,
  -- with citizen-safe columns only.
  select count(*) into n from list_my_recurrence_reports(9401) where report_id = v_report_id;
  if n = 1 then raise notice '27b PASS: citizen sees their own report via the RPC';
  else raise notice '27b FAIL: got % row(s)', n; end if;

  -- 27c: a different citizen sees nothing for a report that is not theirs.
  perform as_user('33333333-3333-3333-3333-333333333333');
  select count(*) into n from list_my_recurrence_reports(9401);
  if n = 0 then raise notice '27c PASS: another citizen sees zero reports on 9401';
  else raise notice '27c FAIL: got % row(s)', n; end if;
end $$;

select 'TEST 28: duplicate recurrence reports are handled safely' as t;
do $$
declare v_first bigint; v_second bigint; n int;
begin
  perform as_user('11111111-1111-1111-1111-111111111111');
  select v into v_first from t_ids where k = 'report_9401';

  -- 28a: submitting again while the first report is still pending returns the
  -- SAME report id — idempotent, not a second row.
  select submit_incident_recurrence_report(9401, 'partially_returned', 'still happening', null, null, null) into v_second;
  if v_second = v_first then raise notice '28a PASS: duplicate submission returned the existing pending report %', v_first;
  else raise notice '28a FAIL: got a new id % (expected %)', v_second, v_first; end if;

  reset role;
  select count(*) into n from incident_recurrence_reports where incident_id = 9401 and reporter_id = '11111111-1111-1111-1111-111111111111';
  set role authenticated;
  if n = 1 then raise notice '28b PASS: exactly one row exists despite two submit calls';
  else raise notice '28b FAIL: % rows exist', n; end if;
end $$;

select 'TEST 29: command review — dismiss / request more evidence / confirm' as t;
do $$
declare v_report_id bigint; v_status text;
begin
  perform as_user('11111111-1111-1111-1111-111111111111');
  select submit_incident_recurrence_report(9402, 'unable_to_confirm', 'not sure', null, null, null) into v_report_id;
  insert into t_ids (k, v) values ('report_9402', v_report_id) on conflict (k) do update set v = excluded.v;

  -- 29a: a citizen cannot write to incident_recurrence_reports at all — the
  -- write policy's USING clause excludes them, so (same pattern as a citizen's
  -- own UPDATE of reports.incident_id elsewhere in this suite) this is a
  -- silent 0-row no-op under RLS rather than a raised exception.
  update incident_recurrence_reports set review_status = 'confirmed' where id = v_report_id;
  reset role;
  select review_status into v_status from incident_recurrence_reports where id = v_report_id;
  set role authenticated;
  if v_status = 'pending' then raise notice '29a PASS: citizen''s update affected 0 rows (RLS), status still pending';
  else raise notice '29a FAIL: status changed to % via a citizen update', v_status; end if;

  -- 29b: commander can move it to "more evidence requested".
  perform as_user('44444444-4444-4444-4444-444444444444');
  update incident_recurrence_reports
    set review_status = 'more_evidence_requested', public_response = 'Please add a photo.',
        reviewed_by = '44444444-4444-4444-4444-444444444444', reviewed_at = now()
    where id = v_report_id;
  select review_status into v_status from incident_recurrence_reports where id = v_report_id;
  if v_status = 'more_evidence_requested' then raise notice '29b PASS: commander requested more evidence';
  else raise notice '29b FAIL: status is %', v_status; end if;

  -- 29c: commander then confirms it (standalone confirm, no reopen/new/merge yet).
  update incident_recurrence_reports
    set review_status = 'confirmed', public_response = 'Confirmed as a genuine recurrence.', reviewed_at = now()
    where id = v_report_id;
  select review_status into v_status from incident_recurrence_reports where id = v_report_id;
  if v_status = 'confirmed' then raise notice '29c PASS: commander confirmed the recurrence';
  else raise notice '29c FAIL: status is %', v_status; end if;

  -- 29d: 9402 itself is untouched — confirming does not by itself reopen anything.
  select status into v_status from incidents where id = 9402;
  if v_status = 'closed' then raise notice '29d PASS: incident 9402 remains closed after a standalone confirm';
  else raise notice '29d FAIL: incident status is %', v_status; end if;
end $$;

select 'TEST 30: command reopens the original incident from a recurrence report' as t;
do $$
declare v_report_id bigint; v_status text; v_outcome text;
begin
  perform as_user('44444444-4444-4444-4444-444444444444');
  select v into v_report_id from t_ids where k = 'report_9401';

  update incidents set status = 'evidence_gathering', closed_at = null, updated_at = now() where id = 9401;
  update incident_recurrence_reports
    set review_status = 'confirmed', public_response = 'The problem has returned; the incident has been reopened.',
        reviewed_by = '44444444-4444-4444-4444-444444444444', reviewed_at = now()
    where id = v_report_id;
  insert into incident_events (incident_id, event_type, actor_id, note, is_public, payload)
    values (9401, 'status_changed', '44444444-4444-4444-4444-444444444444', 'The problem has returned; the incident has been reopened.', true, '{"reopened":true}');

  select status::text into v_status from incidents where id = 9401;
  if v_status <> 'closed' then raise notice '30a PASS: incident 9401 was reopened (status %)', v_status;
  else raise notice '30a FAIL: incident 9401 is still closed'; end if;

  -- 30b: the citizen's own view of the report now shows the computed
  -- 'reopened' outcome, not just the raw review_status.
  perform as_user('11111111-1111-1111-1111-111111111111');
  select outcome_kind into v_outcome from list_my_recurrence_reports(9401) where report_id = v_report_id;
  if v_outcome = 'reopened' then raise notice '30b PASS: citizen sees outcome_kind = reopened';
  else raise notice '30b FAIL: outcome_kind = %', coalesce(v_outcome, '<null>'); end if;
end $$;

select 'TEST 31: command creates a new linked incident from a recurrence report (traceability)' as t;
do $$
declare v_report_id bigint; v_new_incident bigint; v_recurrence_of bigint; v_resulting bigint;
begin
  perform as_user('11111111-1111-1111-1111-111111111111');
  select submit_incident_recurrence_report(9403, 'returned', 'different area now', 28.90, 77.20, null) into v_report_id;

  perform as_user('44444444-4444-4444-4444-444444444444');
  insert into incidents (ward_id, detection_method, summary, created_by, recurrence_of_incident_id)
    values (1, 'citizen_recurrence_report', 'Recurrence of incident #9403: new location', '44444444-4444-4444-4444-444444444444', 9403)
    returning id into v_new_incident;
  update incident_recurrence_reports
    set review_status = 'confirmed', resulting_incident_id = v_new_incident,
        public_response = 'Confirmed — a new incident has been opened to track this.',
        reviewed_by = '44444444-4444-4444-4444-444444444444', reviewed_at = now()
    where id = v_report_id;

  select recurrence_of_incident_id into v_recurrence_of from incidents where id = v_new_incident;
  if v_recurrence_of = 9403 then raise notice '31a PASS: new incident % traces back to 9403 via recurrence_of_incident_id', v_new_incident;
  else raise notice '31a FAIL: recurrence_of_incident_id = %', v_recurrence_of; end if;

  select resulting_incident_id into v_resulting from incident_recurrence_reports where id = v_report_id;
  if v_resulting = v_new_incident then raise notice '31b PASS: the report traces forward to the new incident %', v_new_incident;
  else raise notice '31b FAIL: resulting_incident_id = %', v_resulting; end if;

  -- 31c: the ORIGINAL incident 9403 itself was not reopened by this disposition.
  if (select status from incidents where id = 9403) = 'closed' then
    raise notice '31c PASS: original incident 9403 remains closed (a new incident was opened instead)';
  else raise notice '31c FAIL: incident 9403 status changed'; end if;
end $$;

select 'TEST 32: command merges a recurrence report into an already-open nearby incident' as t;
do $$
declare v_report_id bigint; n int;
begin
  perform as_user('11111111-1111-1111-1111-111111111111');
  select submit_incident_recurrence_report(9409, 'returned', 'right next to the open one', null, null, null) into v_report_id;

  perform as_user('44444444-4444-4444-4444-444444444444');
  insert into incident_evidence (incident_id, evidence_type, supports, payload, collected_by)
    values (9404, 'recurrence_report', true, jsonb_build_object('source_report_id', v_report_id), '44444444-4444-4444-4444-444444444444');
  update incident_recurrence_reports
    set review_status = 'confirmed', resulting_incident_id = 9404,
        public_response = 'Confirmed — linked to an incident already being tracked nearby.',
        reviewed_by = '44444444-4444-4444-4444-444444444444', reviewed_at = now()
    where id = v_report_id;

  select count(*) into n from incident_evidence where incident_id = 9404 and evidence_type = 'recurrence_report';
  if n = 1 then raise notice '32a PASS: the widened evidence_type (recurrence_report) was accepted on the target incident';
  else raise notice '32a FAIL: % matching evidence rows', n; end if;

  if (select resulting_incident_id from incident_recurrence_reports where id = v_report_id) = 9404 then
    raise notice '32b PASS: the report traces to the merge target 9404';
  else raise notice '32b FAIL'; end if;
end $$;

select 'TEST 33: RLS blocks unauthorised (cross-ward) recurrence report access' as t;
do $$
declare n int;
begin
  -- 33a: a field officer in a DIFFERENT ward (2) cannot read ward-1's recurrence reports.
  perform as_user('55555555-5555-5555-5555-555555555555');
  select count(*) into n from incident_recurrence_reports where incident_id = 9401;
  if n = 0 then raise notice '33a PASS: field officer in ward 2 cannot read ward 1''s recurrence reports';
  else raise notice '33a FAIL: read % row(s) across wards', n; end if;

  -- 33b: a field officer in the SAME ward can.
  perform as_user('22222222-2222-2222-2222-222222222222');
  select count(*) into n from incident_recurrence_reports where incident_id = 9401;
  if n > 0 then raise notice '33b PASS: field officer in ward 1 can read incident 9401''s recurrence reports (% row(s))', n;
  else raise notice '33b FAIL: ward-scoped officer read 0 rows'; end if;
end $$;

select 'TEST 34: custom intervention — commander-only creation (closes the verified actions_write gap)' as t;
do $$
declare v_action bigint;
begin
  -- 34a: a field officer can no longer create an incident-linked action
  -- directly, even in their own ward — this was the real, verified gap in the
  -- baseline actions_write policy that this migration closes at the trigger
  -- level (see the migration's own header comment).
  perform as_user('22222222-2222-2222-2222-222222222222');
  begin
    insert into actions (incident_id, ward_id, type, recommended_action, responsible_agency, custom_reason)
      values (9406, 1, 'inspect', 'Field officer attempt', 'MCD', 'no playbook available');
    raise notice '34a FAIL: field officer created an incident-linked intervention directly';
  exception when insufficient_privilege then raise notice '34a PASS: blocked (insufficient_privilege)';
  end;

  -- 34b: a commander, with a reason, can.
  perform as_user('44444444-4444-4444-4444-444444444444');
  insert into actions (incident_id, ward_id, type, recommended_action, responsible_agency, custom_reason)
    values (9406, 1, 'inspect', 'Commander custom inspection', 'MCD Zone 3', 'No playbook covers this source category yet')
    returning id into v_action;
  insert into t_ids (k, v) values ('custom_action_9406', v_action) on conflict (k) do update set v = excluded.v;
  raise notice '34b PASS: commander created a custom incident-linked intervention (action %)', v_action;
end $$;

select 'TEST 35: custom fallback requires a non-empty reason' as t;
do $$
begin
  perform as_user('44444444-4444-4444-4444-444444444444');

  -- 35a: no reason at all.
  begin
    insert into actions (incident_id, ward_id, type, recommended_action, responsible_agency)
      values (9406, 1, 'notice', 'Custom notice, no reason given', 'MCD');
    raise notice '35a FAIL: custom action accepted with no custom_reason';
  exception when check_violation then raise notice '35a PASS: blocked (check_violation, custom_reason missing)';
  end;

  -- 35b: an all-whitespace reason is treated the same as empty.
  begin
    insert into actions (incident_id, ward_id, type, recommended_action, responsible_agency, custom_reason)
      values (9406, 1, 'notice', 'Custom notice, blank reason', 'MCD', '   ');
    raise notice '35b FAIL: custom action accepted with a whitespace-only reason';
  exception when check_violation then raise notice '35b PASS: blocked (whitespace-only reason rejected)';
  end;
end $$;

select 'TEST 36: custom fallback cannot bypass evidence-level rules' as t;
do $$
begin
  perform as_user('44444444-4444-4444-4444-444444444444');

  -- 36a: a suspected incident refuses ANY action, custom or not — the
  -- pre-existing Phase 3 gate, still in force for the custom path.
  begin
    insert into actions (incident_id, ward_id, type, recommended_action, responsible_agency, custom_reason)
      values (9405, 1, 'inspect', 'Custom inspection on a suspected incident', 'MCD', 'No playbook fits yet');
    raise notice '36a FAIL: custom action created on a merely suspected incident';
  exception when check_violation then raise notice '36a PASS: blocked (suspected incident)';
  end;

  -- 36b: a custom ENFORCEMENT action still needs an officially_verified
  -- source — typing free text instead of picking a playbook does not lower
  -- the bar. 9406 is only corroborated.
  begin
    insert into actions (incident_id, ward_id, type, recommended_action, responsible_agency, custom_reason)
      values (9406, 1, 'penalty', 'Custom penalty, no playbook', 'MCD', 'No enforcement playbook exists for this case');
    raise notice '36b FAIL: custom enforcement action created on a corroborated (not verified) incident';
  exception when check_violation then raise notice '36b PASS: blocked (corroborated < officially_verified for enforcement)';
  end;
end $$;

select 'TEST 37: custom enforcement still requires a named approver' as t;
do $$
declare v_action bigint;
begin
  perform as_user('44444444-4444-4444-4444-444444444444');

  -- 37a: officially verified, but no approver -> still blocked.
  begin
    insert into actions (incident_id, ward_id, type, recommended_action, responsible_agency, custom_reason)
      values (9407, 1, 'penalty', 'Custom penalty, verified source, no approver', 'MCD', 'No enforcement playbook exists for this case');
    raise notice '37a FAIL: custom enforcement action created with no approver';
  exception when check_violation then raise notice '37a PASS: blocked (named approver required regardless of playbook)';
  end;

  -- 37b: with an approver, it succeeds.
  insert into actions (incident_id, ward_id, type, recommended_action, responsible_agency, custom_reason, approved_by, approval_level)
    values (9407, 1, 'penalty', 'Custom penalty, verified + approved', 'MCD', 'No enforcement playbook exists for this case',
            '44444444-4444-4444-4444-444444444444', 'authorised_legal')
    returning id into v_action;
  insert into t_ids (k, v) values ('custom_enforcement_9407', v_action) on conflict (k) do update set v = excluded.v;
  raise notice '37b PASS: custom enforcement action % succeeded once verified AND approved', v_action;
end $$;

select 'TEST 38: custom fallback respects regional-classification compatibility' as t;
do $$
begin
  perform as_user('44444444-4444-4444-4444-444444444444');

  -- 38a: a regional incident refuses a local custom action type.
  begin
    insert into actions (incident_id, ward_id, type, recommended_action, responsible_agency, custom_reason)
      values (9408, 1, 'sprinkle', 'Local sprinkling on a regional-source incident', 'MCD', 'No playbook fits this yet');
    raise notice '38a FAIL: local custom action type accepted on a regional incident';
  exception when check_violation then raise notice '38a PASS: blocked (regional incident, local action type)';
  end;

  -- 38b: the advisory/monitoring type IS accepted on a regional incident.
  insert into actions (incident_id, ward_id, type, recommended_action, responsible_agency, custom_reason)
    values (9408, 1, 'advisory_monitoring', 'Public advisory for regional smoke', 'DPCC', 'No regional playbook exists yet');
  raise notice '38b PASS: advisory_monitoring accepted on a regional incident';
end $$;

select 'TEST 39: post-approval immutability' as t;
do $$
declare v_action bigint;
begin
  perform as_user('44444444-4444-4444-4444-444444444444');
  select v into v_action from t_ids where k = 'custom_enforcement_9407';

  -- 39a: a descriptive field cannot be silently edited once approved.
  begin
    update actions set recommended_action = 'Quietly changed after approval' where id = v_action;
    raise notice '39a FAIL: recommended_action was edited after approval';
  exception when check_violation then raise notice '39a PASS: blocked — instructions are immutable once approved';
  end;

  begin
    update actions set custom_reason = 'Quietly changed reason' where id = v_action;
    raise notice '39b FAIL: custom_reason was edited after approval';
  exception when check_violation then raise notice '39b PASS: blocked — custom_reason is immutable once approved too';
  end;

  -- 39c: a non-descriptive, purely operational field (deadline) is unaffected.
  begin
    update actions set deadline = now() + interval '5 days' where id = v_action;
    raise notice '39c PASS: operational fields (deadline) remain editable after approval';
  exception when others then raise notice '39c FAIL: %', sqlerrm;
  end;
end $$;

select 'TEST 40: guaranteed audit trigger writes creation events without client help' as t;
do $$
declare n int; v_note text;
begin
  perform as_user('44444444-4444-4444-4444-444444444444');

  -- 40a: the custom action created in TEST 34 got an event automatically —
  -- this test file never called addIncidentEvent-equivalent SQL for it.
  select count(*), max(note) into n, v_note
    from incident_events
    where incident_id = 9406 and event_type = 'custom_intervention_created';
  if n >= 1 and v_note like '%No playbook covers this source category yet%' then
    raise notice '40a PASS: custom_intervention_created event written automatically, naming the reason';
  else raise notice '40a FAIL: % matching event(s), note = %', n, coalesce(v_note, '<null>'); end if;
end $$;

-- 40b: a playbook-based action also gets its own guaranteed event type.
do $$
declare v_playbook bigint; v_action bigint; n int;
begin
  perform as_user('44444444-4444-4444-4444-444444444444');
  insert into intervention_playbooks (slug, city_id, source_category, min_evidence_level, action_type, title, checklist)
    values ('test-audit-playbook', 1, 'road_dust', 'corroborated', 'inspect', 'Test audit playbook', '[]'::jsonb)
    on conflict (slug) do update set min_evidence_level = 'corroborated'
    returning id into v_playbook;

  insert into actions (incident_id, ward_id, type, playbook_id, playbook_version, checklist_snapshot)
    select 9406, 1, action_type, id, version, checklist from intervention_playbooks where id = v_playbook
    returning id into v_action;

  select count(*) into n from incident_events where incident_id = 9406 and event_type = 'task_created' and payload->>'action_id' = v_action::text;
  if n = 1 then raise notice '40b PASS: task_created event written automatically for a playbook-based action';
  else raise notice '40b FAIL: % matching event(s)', n; end if;
end $$;

reset role;
reset request.jwt.claims;

-- No cleanup of the 'test-audit-playbook' fixture here (unlike 50_'s
-- 'test-high-tier-inspect'): TEST 40b actually used it to create an action,
-- so deleting the playbook row would violate actions_playbook_id_fkey. Its
-- own insert already uses `on conflict (slug) do update`, which is enough to
-- keep re-running this file within the same session idempotent.
