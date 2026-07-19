-- Local-only stub of the parts of Supabase that schema.sql / migrations depend on.
-- This file is NEVER shipped: it exists so the real migrations can be applied and
-- RLS exercised against a disposable Postgres. Mirrors Supabase's actual shapes:
--   auth.uid()  -> request.jwt.claims ->> 'sub'   (uuid)
--   auth.role() -> request.jwt.claims ->> 'role'  (text)

create schema if not exists auth;
create schema if not exists storage;

create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  email text
);

create or replace function auth.uid() returns uuid
language sql stable as $$
  select nullif(current_setting('request.jwt.claims', true)::json ->> 'sub', '')::uuid
$$;

create or replace function auth.role() returns text
language sql stable as $$
  select coalesce(current_setting('request.jwt.claims', true)::json ->> 'role', 'anon')
$$;

-- storage stubs used by 20260714010000_report_photos.sql
create table if not exists storage.buckets (
  id text primary key,
  name text not null,
  public boolean not null default false
);

create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets(id),
  name text,
  owner uuid
);

create or replace function storage.foldername(name text) returns text[]
language sql immutable as $$
  select string_to_array(name, '/')
$$;

-- Supabase's DB roles. RLS is bypassed by superusers, so tests must run as these.
do $$ begin create role anon nologin; exception when duplicate_object then null; end $$;
do $$ begin create role authenticated nologin; exception when duplicate_object then null; end $$;
do $$ begin create role service_role nologin bypassrls; exception when duplicate_object then null; end $$;

grant usage on schema public, auth, storage to anon, authenticated, service_role;
