#!/bin/sh
set -e

echo "Samen ERP starting..."

# Wait for Postgres to be ready
echo "Waiting for PostgreSQL..."
until pg_isready -h db -p 5432 -U postgres 2>/dev/null; do
  sleep 1
done
echo "PostgreSQL is ready."

# Run migrations and seed via eval (starts app briefly)
echo "Running migrations and seeding..."
/app/samenerp/bin/samenerp eval "
  Application.ensure_all_started(:samenerp)
  Samenerp.Release.migrate()
  Samenerp.Seeds.seed!()
  IO.puts(\"Migration and seed complete.\")
" || true

# Start the application in foreground
echo "Starting Samen ERP..."
exec /app/samenerp/bin/samenerp start
