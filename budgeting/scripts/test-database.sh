#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
name="budgeting-test-$$"
trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT INT TERM
docker run -d --name "$name" -e POSTGRES_HOST_AUTH_METHOD=trust -v "$PWD/supabase:/tests:ro" postgres:latest >/dev/null
attempt=0
until docker exec "$name" pg_isready -U postgres >/dev/null 2>&1; do
  attempt=$((attempt + 1)); [ "$attempt" -lt 60 ] || exit 1; sleep 1
done
docker exec "$name" psql -U postgres -v ON_ERROR_STOP=1 -f /tests/tests/bootstrap.sql
for migration in supabase/migrations/*.sql; do
  docker exec "$name" psql -U postgres -v ON_ERROR_STOP=1 -f "/tests/migrations/$(basename "$migration")"
done
docker exec "$name" psql -U postgres -v ON_ERROR_STOP=1 -f /tests/tests/authorization.sql
docker exec "$name" psql -U postgres -v ON_ERROR_STOP=1 -f /tests/tests/concurrency.sql
docker exec "$name" psql -U postgres -v ON_ERROR_STOP=1 -f /tests/tests/usage_and_leases.sql
