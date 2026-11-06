#!/usr/bin/env bash
# Run inside budgeting-recovery:latest, against an isolated synthetic server.
set -euo pipefail
set +x
umask 077
PYTHONDONTWRITEBYTECODE=1 python3 /workspace/recovery/test_connect.py
export PGHOST=/tmp PGUSER=postgres
initdb -D /tmp/test-pg >/dev/null
pg_ctl -D /tmp/test-pg -o '-k /tmp -c listen_addresses= -c log_statement=none' -w start >/dev/null
trap 'pg_ctl -D /tmp/test-pg -m immediate stop >/dev/null' EXIT
psql -X -v ON_ERROR_STOP=1 -d postgres -f /workspace/supabase/tests/bootstrap.sql >/dev/null
for migration in /workspace/supabase/migrations/*.sql; do
  psql -X -v ON_ERROR_STOP=1 -d postgres -f "$migration" >/dev/null
done
psql -X -v ON_ERROR_STOP=1 -d postgres -f /workspace/recovery/fixture.sql >/dev/null
createdb disposable_roundtrip
psql -X -v ON_ERROR_STOP=1 -d disposable_roundtrip -f /workspace/supabase/tests/bootstrap.sql >/dev/null
psql -X -v ON_ERROR_STOP=1 -d disposable_roundtrip -c "insert into auth.users values ('11111111-1111-4111-8111-111111111111')" >/dev/null
mkdir /tmp/keys
age-keygen -o /tmp/keys/identity 2>/dev/null
age-keygen -y /tmp/keys/identity >/tmp/keys/recipients
age-keygen -o /tmp/keys/wrong 2>/dev/null
# The test's /run mount is a tmpfs; no keys or plaintext reach the host.
cp /tmp/keys/identity /run/identity
cp /tmp/keys/recipients /run/recipients
export RECOVERY_LOCAL_SYNTHETIC=true
export DATABASE_URL='postgresql://postgres@/postgres?host=/tmp&sslmode=disable'
python3 /recovery/connect.py backup >/run/backup.age
export DATABASE_URL='postgresql://postgres@/disposable_roundtrip?host=/tmp&sslmode=disable'
python3 /recovery/connect.py restore disposable_roundtrip 'RESTORE disposable_roundtrip'
psql -X -v ON_ERROR_STOP=1 -d disposable_roundtrip -f /workspace/recovery/assert.sql >/dev/null
cp /run/backup.age /tmp/good.age
cp /tmp/keys/wrong /run/identity
if python3 /recovery/connect.py restore disposable_roundtrip 'RESTORE disposable_roundtrip'; then exit 1; fi
cp /tmp/keys/identity /run/identity
truncate -s 100 /run/backup.age
if python3 /recovery/connect.py restore disposable_roundtrip 'RESTORE disposable_roundtrip'; then exit 1; fi
cp /tmp/good.age /run/backup.age
if python3 /recovery/connect.py restore disposable_wrong 'RESTORE disposable_wrong'; then exit 1; fi
if python3 /recovery/connect.py restore disposable_roundtrip 'no'; then exit 1; fi
psql -X -v ON_ERROR_STOP=1 -d disposable_roundtrip -f /workspace/recovery/assert.sql >/dev/null
printf 'PASS: encrypted round trip, financial values/aggregate, owner/MFA RLS, replay quarantine, wrong key/corruption/confirmation; target preserved.\n'
