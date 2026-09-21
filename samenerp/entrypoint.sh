#!/bin/sh
set -e

echo "Samen ERP starting..."

# Wait for Postgres to be ready
echo "Waiting for PostgreSQL..."
until pg_isready -h db -p 5432 -U postgres 2>/dev/null; do
  sleep 1
done
echo "PostgreSQL is ready."

# Start the application first (needed for repo access)
echo "Starting application (background)..."
/app/samenerp/bin/samenerp daemon &
APP_PID=$!

# Wait for the app to be ready
echo "Waiting for application to start..."
sleep 5

# Run migrations
echo "Running migrations..."
/app/samenerp/bin/samenerp eval "Samenerp.Release.migrate()" || true

# Seed the operator org (idempotent — safe to re-run)
echo "Seeding operator org..."
/app/samenerp/bin/samenerp eval "Samenerp.Seeds.seed!()" || true

# Stop the daemon and start foreground
echo "Stopping daemon, starting foreground..."
/app/samenerp/bin/samenerp stop || true
sleep 2

echo "Starting Samen ERP (foreground)..."
exec /app/samenerp/bin/samenerp start
