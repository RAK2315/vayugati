-- End-to-end test of the Phase 3 report->incident workflow, run as `authenticated`
-- so RLS is actually in force.
\set ON_ERROR_STOP on

-- ---------- clean slate ----------
delete from incident_events;
delete from incident_evidence;
delete from incident_source_hypotheses;
delete from evidence_missions;
delete from actions;
delete from impact_evaluations;
delete from reports;
delete from incidents;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'a@example.com'),
  ('22222222-2222-2222-2222-222222222222', 'officer@example.com'),
  ('33333333-3333-3333-3333-333333333333', 'b@example.com'),
  ('44444444-4444-4444-4444-444444444444', 'cmd@example.com')
on conflict do nothing;

insert into profiles (id, role, ward_id) values
  ('11111111-1111-1111-1111-111111111111', 'citizen', 1),
  ('22222222-2222-2222-2222-222222222222', 'field_officer', 1),
  ('33333333-3333-3333-3333-333333333333', 'citizen', 1),
  ('44444444-4444-4444-4444-444444444444', 'commander', null)
on conflict (id) do update set role = excluded.role, ward_id = excluded.ward_id;

create or replace function as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p::text, 'role', 'authenticated')::text, false);
end $$;

create or replace function mkreport(p_user uuid, p_lat double precision, p_lng double precision,
                                    p_cat text, p_desc text)
returns bigint language plpgsql as $$
declare v_id bigint;
begin
  insert into reports (reporter_id, ward_id, lat, lng, description, ai_category, ai_meta)
  values (p_user, 1, p_lat, p_lng, p_desc, nullif(p_cat,'')::source_category,
          jsonb_build_object('confidence', 0.8))
  returning id into v_id;
  return v_id;
end $$;

set role authenticated;

-- ============ 1. first report creates an incident ============
select as_user('11111111-1111-1111-1111-111111111111');
select 'TEST 1: first report creates incident' as t;
\gset
select link_report_to_incident(mkreport('11111111-1111-1111-1111-111111111111',
       28.850, 77.090, 'open_burning', 'burning waste')) as inc1 \gset
select
  case when count(*) = 1 then 'PASS: 1 incident created' else 'FAIL: ' || count(*) end as r,
  (select source_confidence::text from incidents where id = :inc1) as confidence,
  (select status::text from incidents where id = :inc1) as status
from incidents;

-- ============ 2. same reporter, nearby, same category -> links, stays suspected ============
select 'TEST 2: duplicate from SAME reporter links, does NOT corroborate' as t;
select link_report_to_incident(mkreport('11111111-1111-1111-1111-111111111111',
       28.8503, 77.0902, 'open_burning', 'still burning')) as inc2 \gset
select
  case when :inc2 = :inc1 then 'PASS: linked to same incident' else 'FAIL: new incident made' end as r,
  case when (select source_confidence from incidents where id = :inc1) = 'suspected'
       then 'PASS: still suspected (one person is not independent)'
       else 'FAIL: wrongly corroborated' end as r2,
  (select count(*) from incidents) as total_incidents;

-- ============ 3. DIFFERENT reporter, nearby, same category -> corroborated ============
select 'TEST 3: second INDEPENDENT reporter corroborates' as t;
select as_user('33333333-3333-3333-3333-333333333333');
select link_report_to_incident(mkreport('33333333-3333-3333-3333-333333333333',
       28.8501, 77.0901, 'open_burning', 'smoke here too')) as inc3 \gset
select
  case when :inc3 = :inc1 then 'PASS: linked to same incident' else 'FAIL' end as r,
  case when (select source_confidence from incidents where id = :inc1) = 'corroborated'
       then 'PASS: upgraded to corroborated' else 'FAIL: ' ||
       (select source_confidence::text from incidents where id = :inc1) end as r2,
  (select count(*) from incidents) as total_incidents;

-- ============ 4. far away (>750m) -> new incident ============
select 'TEST 4: report >750m away creates a NEW incident' as t;
select link_report_to_incident(mkreport('33333333-3333-3333-3333-333333333333',
       28.8700, 77.0900, 'open_burning', 'different site 2km north')) as inc4 \gset
select case when :inc4 <> :inc1 then 'PASS: separate incident' else 'FAIL: wrongly merged' end as r,
       (select count(*) from incidents) as total_incidents;

-- ============ 5. different category, same place -> new incident ============
select 'TEST 5: different source category creates a NEW incident' as t;
select link_report_to_incident(mkreport('33333333-3333-3333-3333-333333333333',
       28.8502, 77.0903, 'construction_dust', 'dust from site')) as inc5 \gset
select case when :inc5 <> :inc1 then 'PASS: separate incident' else 'FAIL: wrongly merged' end as r,
       (select count(*) from incidents) as total_incidents;

-- ============ 6. idempotency ============
select 'TEST 6: re-linking the same report is a no-op' as t;
select link_report_to_incident((select min(id) from reports)) as again \gset
select case when :again = :inc1 then 'PASS: returns same incident, no duplicate' else 'FAIL' end as r,
       (select count(*) from incidents) as total_incidents;

-- ============ 7. authorisation: cannot link someone else's report ============
reset role; reset request.jwt.claims;
