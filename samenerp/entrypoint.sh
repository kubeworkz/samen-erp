#!/bin/sh
set -e

echo "Samen ERP starting..."

# Wait for Postgres to be ready
echo "Waiting for PostgreSQL..."
until pg_isready -h db -p 5432 -U postgres 2>/dev/null; do
  sleep 1
done
echo "PostgreSQL is ready."

# ORDER MATTERS: migrate BEFORE the application starts.
#
# `Application.ensure_all_started(:samenerp)` boots Oban, whose database peer
# queries `oban_peers` the moment it starts — a table that only exists once the
# migrations have run. Booting the app first therefore crashes on a fresh
# database (ERROR 42P01 undefined_table public.oban_peers) and the container
# never comes up. `Samenerp.Release.migrate/0` is safe here because
# `Ecto.Migrator.with_repo/3` starts only :ecto_sql, the adapter and the repo —
# not the application — so it can create that table first.
#
# The failures are NOT swallowed: with `set -e` an error here aborts the boot,
# which is what deploy-prod.sh's "Migration and seed complete" gate checks for.
echo "Running migrations..."
if ! /app/samenerp/bin/samenerp eval "Samenerp.Release.migrate()"; then
  echo "MIGRATION FAILED — refusing to start the application" >&2
  exit 1
fi

# Seeding uses the Ash domains, so it runs with the app started — now that the
# schema exists. PHX_SERVER=false keeps that started app QUIET: no listener, so
# nothing answers /healthz until the real `start` below. Without it the container
# serves a green probe while the seed is still running.
echo "Seeding..."
if ! PHX_SERVER=false /app/samenerp/bin/samenerp eval "
  {:ok, _} = Application.ensure_all_started(:samenerp)
  Samenerp.Seeds.seed!()
  IO.puts(\"Migration and seed complete.\")
"; then
  echo "SEED FAILED — refusing to start the application" >&2
  exit 1
fi

# Start the application in foreground
echo "Starting Samen ERP..."
exec /app/samenerp/bin/samenerp start
