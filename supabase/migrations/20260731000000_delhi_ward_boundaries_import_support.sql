-- Phase 2 (Delhi City Pack): additive columns needed to import the real
-- 250-ward MCD boundary set (docs/data/delhi-ward-import-report.md)
-- alongside the existing 13 seeded hotspot wards, without touching them.
--
-- wards.name is globally unique and the 13 hotspot wards already occupy
-- it - the 250 imported municipal wards need a natural key that can't
-- collide with that seed data, hence ward_number (scoped per city, not
-- global) rather than reusing name. All new columns are nullable/defaulted
-- so the 13 existing rows are completely unaffected.
alter table wards add column if not exists ward_number int;
alter table wards add column if not exists zone text;
alter table wards add column if not exists metadata jsonb not null default '{}'::jsonb;

-- Upsert key for the import script (city_id, ward_number). A plain (non-
-- partial) unique index is enough: Postgres never treats two NULLs as
-- equal for uniqueness, so the 13 existing hotspot rows (ward_number is
-- null on all of them) can coexist under this index without collision,
-- and a plain index - unlike a partial one - works directly as a
-- supabase-js `.upsert(..., { onConflict: 'city_id,ward_number' })` target.
create unique index if not exists wards_city_ward_number_key
  on wards (city_id, ward_number);

comment on column wards.ward_number is 'Official MCD ward number (1-250), only set for imported municipal-boundary wards - null for the 13 seeded hotspot wards.';
comment on column wards.zone is 'Municipal zone grouping - not present in the source ward file (Phase 1 audit); left null rather than fabricated.';
comment on column wards.metadata is 'Import-time extras (source FID, population figures, source document) for imported municipal wards - {} for the 13 seeded hotspot wards.';
