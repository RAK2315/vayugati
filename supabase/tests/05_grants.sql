-- Local-only. Supabase grants these automatically to the API roles; the stub
-- must do it by hand, AFTER the migrations have created the tables.
grant usage on schema public to anon, authenticated, service_role;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant select on all tables in schema public to anon;
