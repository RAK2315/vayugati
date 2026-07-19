-- ============================================================
-- profile_role_immutability — additive migration (Phase 11 hotfix)
--
-- Fixes a genuine privilege-escalation vulnerability found while manually
-- walking through the real hosted Vercel deployment for the first time:
-- `profiles_self_update` (schema.sql) is `using (id = auth.uid())` only —
-- it restricts WHICH ROW a user can update, but never WHICH COLUMNS. The
-- same gap exists on `profiles_insert_self`. Neither RLS policy has ever
-- been tightened by any later migration.
--
-- Concretely, before this migration: any self-registered citizen could
-- call the REST API directly (bypassing the frontend UI entirely, which
-- never offers this — but nothing stopped a raw HTTP request) and do
--   PATCH /rest/v1/profiles?id=eq.<their-own-uid>   body: {"role":"admin"}
-- or set role/ward_id to anything at all on their very first signup
-- INSERT. RLS allowed both.
--
-- Fix: a single BEFORE INSERT OR UPDATE trigger, not a further RLS
-- tightening, because "the new value must equal the old value" (for
-- UPDATE) and "the new value must equal a fixed default regardless of what
-- was submitted" (for INSERT) both need OLD/NEW row access that a plain
-- RLS policy can't cleanly express.
--
-- Preserves every legitimate path:
--   * the ingest/admin service_role connection (auth.uid() is null) is
--     completely unaffected — same "trusted backend" convention already
--     used throughout this schema (see dispatch_intervention_task,
--     run_anomaly_detection, etc.)
--   * an existing admin acting on their OWN profile row (the only row RLS
--     currently lets any authenticated role reach at all — there is still
--     no in-app "admin edits another user's profile" path; that remains
--     direct SQL, per docs/DELHI_DATA_GAP_REPORT.md / docs/PILOT_RUNBOOK.md)
--     may still change role/ward_id
--   * every other authenticated role (citizen/field_officer/commander)
--     can update their own profile's OTHER columns exactly as before —
--     only role and ward_id are protected
--
-- Nothing here is destructive: no existing row is touched, no column is
-- dropped or narrowed, no policy is removed.
-- ============================================================

create or replace function enforce_profile_role_immutability() returns trigger
language plpgsql as $$
begin
  -- service_role / unauthenticated backend context (ingest, admin scripts
  -- connecting with the service_role key) bypasses this check entirely.
  if auth.uid() is null then
    return new;
  end if;

  -- only a SELF-referential write is restricted at all. RLS's own
  -- profiles_self_update/profiles_insert_self already limit every
  -- authenticated role to id = auth.uid() only, so this is currently
  -- always true for any row an authenticated caller can reach in
  -- production — but making it explicit here (rather than relying on
  -- RLS alone) means this trigger's own intent stays precise even in a
  -- superuser/test-harness context where RLS is bypassed but auth.uid()
  -- may still resolve to some earlier session's impersonated user.
  if new.id is distinct from auth.uid() then
    return new;
  end if;

  -- an existing admin may set their own role/ward_id freely.
  if auth_role() = 'admin' then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.role is distinct from 'citizen' then
      raise exception 'New accounts start as citizen. Role is assigned by an administrator, not at signup.';
    end if;
    if new.ward_id is not null then
      raise exception 'Ward assignment is set by an administrator, not at signup.';
    end if;
  elsif tg_op = 'UPDATE' then
    if new.role is distinct from old.role then
      raise exception 'You cannot change your own role.';
    end if;
    if new.ward_id is distinct from old.ward_id then
      raise exception 'You cannot change your own ward assignment.';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists enforce_profile_role_immutability_trg on profiles;
create trigger enforce_profile_role_immutability_trg
before insert or update on profiles
for each row execute function enforce_profile_role_immutability();
