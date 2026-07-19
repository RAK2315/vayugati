-- ============================================================
-- source_attribution_enum — additive migration (Phase 11 correction)
--
-- Split out of 20260722000000_source_attribution.sql after actually running
-- `supabase db push` against the real hosted project for the first time
-- (Phase 11) surfaced a genuine bug: `supabase db push` applies each
-- migration FILE inside its own single transaction, unlike this repo's own
-- local test harness (`supabase/tests/run.sh`, bare `psql -f`), which
-- auto-commits each STATEMENT independently. Postgres refuses to use a
-- newly-added enum value until the transaction that added it has committed
-- — even later in the very same transaction — so the original migration's
-- own header comment ("safe here because ... a later statement in this
-- SAME file can already use the new label") was true under `psql -f` but
-- false under `supabase db push`, and `get_incident_responsible_authority`
-- (which compares `source_category` directly against the string literals
-- 'regional_transport'/'mixed'/'unresolved') failed with
-- "unsafe use of new value ... (SQLSTATE 55P04)" partway through applying
-- 20260722000000_source_attribution.sql to hosted. That migration's own
-- transaction aborted cleanly (nothing partially applied), and this
-- earlier, standalone migration now guarantees the three new enum labels
-- are committed and safely usable before 20260722000000_source_attribution.sql
-- (which no longer contains the `alter type` statements) ever runs.
--
-- Nothing here is destructive: three new labels appended to the EXISTING
-- `source_category` enum (`regional_transport`, `mixed`, `unresolved`); the
-- pre-existing 7 labels are unchanged. Idempotent (`add value if not
-- exists`) — safe to re-run.
-- ============================================================

alter type source_category add value if not exists 'regional_transport';
alter type source_category add value if not exists 'mixed';
alter type source_category add value if not exists 'unresolved';
