#!/bin/sh
set -e

echo "Samen ERP starting..."

# Wait for Postgres to be ready
echo "Waiting for PostgreSQL..."
until pg_isready -h db -p 5432 -U postgres 2>/dev/null; do
  sleep 1
done
echo "PostgreSQL is ready."

# Run migrations
echo "Running migrations..."
/app/samenerp/bin/samenerp eval "Samenerp.Release.migrate()" || true

# Seed the operator org (idempotent — safe to re-run)
echo "Seeding operator org..."
/app/samenerp/bin/samenerp eval "Samenerp.Seeds.seed!()" || true

# Start the application
echo "Starting Samen ERP..."
exec /app/samenerp/bin/samenerp start
