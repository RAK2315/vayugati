-- ============================================================
-- 0001_weather.sql — additive migration
--
-- Phase 0 ingests Open-Meteo weather hourly, but the locked
-- readings table only has pollutant columns. This adds a
-- separate weather table (per ward, per hour) so weather
-- history accumulates alongside readings for the Phase 2
-- forecast features. Nothing in schema.sql is modified.
--
-- Run AFTER schema.sql.
-- ============================================================

create table weather (
  id            bigserial primary key,
  ward_id       int not null references wards(id) on delete cascade,
  ts            timestamptz not null,
  temp_c        double precision,
  humidity      double precision,   -- relative humidity, %
  wind_speed    double precision,   -- km/h at 10m
  wind_dir      double precision,   -- degrees at 10m (needed for the Phase 3 pollution rose)
  precipitation double precision,   -- mm
  pressure      double precision,   -- surface pressure, hPa
  unique (ward_id, ts)
);
create index on weather (ward_id, ts desc);

alter table weather enable row level security;

-- same posture as readings: any authenticated user reads,
-- writes come from the ingest service via service_role (bypasses RLS)
create policy weather_read on weather for select using (auth.role() = 'authenticated');
