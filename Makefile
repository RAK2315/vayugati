# Supabase CLI convenience targets. Run from the repo root (where supabase/ lives).
# Uses the CLI bundled as a web/ dev-dependency via npx, so no global install is
# needed. Still requires `make link` (or `supabase link`) to be run once first.
# Override with `make SUPABASE=supabase ...` to use a globally-installed CLI.

SUPABASE ?= npx --prefix web supabase

.PHONY: link db-push db-diff gen-types

# Link this repo to your hosted project (needs your access token — run locally).
link:
	$(SUPABASE) link --project-ref xpinidergyqkunoiukal

# Apply pending migrations in supabase/migrations to the linked project.
db-push:
	$(SUPABASE) db push

# Show the diff between local migrations and the linked remote schema.
db-diff:
	$(SUPABASE) db diff

# Regenerate the typed DB client for the web app from the linked schema.
gen-types:
	$(SUPABASE) gen types typescript --linked > web/src/lib/database.types.ts
