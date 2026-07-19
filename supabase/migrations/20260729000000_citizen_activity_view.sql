-- ============================================================
-- list_citizen_report_activity — additive migration (5-tab build: Citizens)
--
-- The one real RLS gap identified for the commander-facing Citizens page:
-- profiles_self_read already lets commander/admin read every `reports` row
-- (reports_read has no ward scoping for those roles), but it does NOT let
-- commander read another user's `full_name` (profiles_self_read is
-- self + admin only). A narrow, read-only SECURITY DEFINER function - the
-- exact same pattern list_assignable_officers already establishes - closes
-- that gap without relaxing profiles' own RLS for every table/column.
--
-- Aggregated server-side (one row per reporter) rather than joining
-- reports+profiles client-side, so the page never has to fetch every
-- individual report just to compute a per-citizen count.
--
-- Nothing here is destructive: one new function, no existing object touched.
-- ============================================================

create or replace function list_citizen_report_activity()
returns table (
  reporter_id      uuid,
  full_name        text,
  report_count     bigint,
  first_report_at  timestamptz,
  last_report_at   timestamptz,
  ward_count       bigint
)
language sql stable security definer set search_path = public as $$
  select
    r.reporter_id,
    p.full_name,
    count(*)::bigint as report_count,
    min(r.created_at) as first_report_at,
    max(r.created_at) as last_report_at,
    count(distinct r.ward_id)::bigint as ward_count
  from reports r
  join profiles p on p.id = r.reporter_id
  where r.reporter_id is not null
    and (select role from profiles me where me.id = auth.uid()) in ('commander', 'admin')
  group by r.reporter_id, p.full_name
  order by report_count desc
$$;

revoke all on function list_citizen_report_activity() from public;
grant execute on function list_citizen_report_activity() to authenticated;
