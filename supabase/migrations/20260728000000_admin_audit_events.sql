-- ============================================================
-- admin_audit_events — additive migration (Phase 11: field-officer onboarding)
--
-- An immutable log of administrative actions that happen OUTSIDE any
-- single incident's own lifecycle (onboarding a field officer, deactivating
-- one, and similar future account-management actions) — `incident_events`
-- exists for exactly this purpose already but is scoped to one incident;
-- creating a user account isn't about any incident at all, so it needs its
-- own append-only table rather than being force-fit into that one or left
-- unaudited.
--
-- Insert-only, matching the exact discipline already used for
-- incident_events/action_evidence: no update/delete RLS policy exists at
-- all, so a row can never be edited or removed once written, by anyone,
-- including an admin. Only the service_role connection ever writes here
-- (matching job_runs' own "no authenticated write policy" pattern) — an
-- admin-facing UI action would still go through a SECURITY DEFINER
-- function or the service_role-backed onboarding script, never a direct
-- authenticated INSERT.
--
-- Nothing here is destructive: one new table, two new RLS policies, no
-- existing object touched.
-- ============================================================

create table if not exists admin_audit_events (
  id           bigserial primary key,
  event_type   text not null check (event_type in (
                 'field_officer_onboarded', 'field_officer_deactivated',
                 'field_officer_onboarding_failed'
               )),
  actor        text not null,             -- e.g. 'onboard_field_officer.py (service_role)'
  target_email text,
  target_user_id uuid,
  city_id      int references city_config(id),
  ward_id      int references wards(id),
  details      jsonb not null default '{}'::jsonb,
  created_at   timestamptz not null default now()
);
create index if not exists admin_audit_events_created_idx on admin_audit_events (created_at desc);
create index if not exists admin_audit_events_target_idx on admin_audit_events (target_user_id);

alter table admin_audit_events enable row level security;

do $$ begin
  create policy admin_audit_events_read on admin_audit_events
    for select using (auth_role() in ('commander', 'admin'));
exception when duplicate_object then null;
end $$;

-- Deliberately no insert/update/delete policy for any authenticated role —
-- only the service_role connection (which bypasses RLS entirely) ever
-- writes here, exactly like job_runs.
