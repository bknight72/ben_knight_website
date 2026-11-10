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
  if [ "$(basename "$migration")" = 202611100001_stripe_linking_lifecycle.sql ]; then
    docker exec "$name" psql -U postgres -v ON_ERROR_STOP=1 -f /tests/tests/linking_upgrade_fixture.sql
  fi
  docker exec "$name" psql -U postgres -v ON_ERROR_STOP=1 -f "/tests/migrations/$(basename "$migration")"
done
docker exec "$name" psql -U postgres -v ON_ERROR_STOP=1 -f /tests/tests/linking_upgrade_assert.sql
docker exec "$name" psql -U postgres -v ON_ERROR_STOP=1 -f /tests/tests/authorization.sql
docker exec "$name" psql -U postgres -v ON_ERROR_STOP=1 -f /tests/tests/concurrency.sql
docker exec "$name" psql -U postgres -v ON_ERROR_STOP=1 -f /tests/tests/usage_and_leases.sql
docker exec "$name" psql -U postgres -v ON_ERROR_STOP=1 -f /tests/tests/linking_lifecycle.sql
docker exec "$name" psql -U postgres -v ON_ERROR_STOP=1 -f /tests/tests/linking_concurrency.sql
docker exec "$name" psql -U postgres -v ON_ERROR_STOP=1 -f /tests/tests/budgeteer.sql
docker exec "$name" psql -U postgres -v ON_ERROR_STOP=1 -f /tests/tests/budgeteer_concurrency.sql
# A second empty database verifies clean initialization independently of populated upgrade.
docker exec "$name" createdb -U postgres fresh
docker exec "$name" psql -U postgres -d fresh -v ON_ERROR_STOP=1 -f /tests/tests/bootstrap.sql
for migration in supabase/migrations/*.sql; do
  docker exec "$name" psql -U postgres -d fresh -v ON_ERROR_STOP=1 -f "/tests/migrations/$(basename "$migration")"
done
docker exec "$name" psql -U postgres -d fresh -v ON_ERROR_STOP=1 -f /tests/tests/linking_lifecycle.sql
docker exec "$name" psql -U postgres -d fresh -v ON_ERROR_STOP=1 -f /tests/tests/budgeteer.sql
