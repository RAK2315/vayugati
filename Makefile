# Supabase CLI convenience targets. Run from the repo root (where supabase/ lives).
# Requires: supabase CLI installed + `supabase link` already run once.

.PHONY: db-push db-diff gen-types

# Apply pending migrations in supabase/migrations to the linked project.
db-push:
	supabase db push

# Show the diff between local migrations and the linked remote schema.
db-diff:
	supabase db diff

# Regenerate the typed DB client for the web app from the linked schema.
gen-types:
	supabase gen types typescript --linked > web/src/lib/database.types.ts
