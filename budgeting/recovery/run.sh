#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077
export PGCONNECT_TIMEOUT=15
# connect.py supplies libpq settings without exposing the URL in arguments.
fail() { printf '%s\n' "$1" >&2; exit 1; }
sql() { psql -X -qAt -v ON_ERROR_STOP=1 "$@" 2>/dev/null; }
client=$(pg_dump --version | cut -d ' ' -f 3 | cut -d . -f 1)
server=$(sql -c 'show server_version_num') || fail 'Database connection failed.'
[[ $((server / 10000)) == "$client" ]] || fail 'PostgreSQL server/client major mismatch; use matching tooling before recovery.'

case ${1:-} in
backup)
  # One pg_dump snapshot covers both application schemas, including ACLs/RLS.
  { printf 'BUDGETING-RECOVERY-1\npostgres-major=%s\nschemas=public,private\nformat=plain-sql\napp-baseline=202611040001_budgeting\n\n' "$client"
    pg_dump --no-owner --schema=public --schema=private --format=plain 2>/dev/null
  } | age --recipients-file /run/recipients 2>/dev/null || fail 'Backup failed; incomplete ciphertext must be discarded.'
  ;;
restore)
  target=${2:?Explicit disposable target required}
  [[ $target =~ ^disposable_[a-z0-9_]+$ ]] || fail 'Target name must start disposable_ and contain only lowercase letters, numbers and underscores.'
  [[ ${3:-} == "RESTORE $target" ]] || fail 'Exact destructive-target confirmation is required.'
  [[ $(sql -c 'select current_database()') == "$target" ]] || fail 'Connection does not match confirmed disposable target.'
  schedules=$(sql -c "select exists(select 1 from pg_namespace where nspname='cron')")
  [[ $schedules == f ]] || fail 'Target has pg_cron installed; remove schedules/extension before restoring.'
  # Copy ciphertext only, protecting the two verification passes from host changes.
  scratch=$(mktemp -d)
  trap 'rm -rf "$scratch"' EXIT
  cp /run/backup.age "$scratch/backup.age"
  decrypt() { age --decrypt --identity /run/identity "$scratch/backup.age" 2>/dev/null; }
  decrypt >/dev/null || fail 'Backup authentication failed (wrong identity or corrupt/truncated ciphertext); target unchanged.'
  header=$(decrypt | { for _ in 1 2 3 4 5 6; do IFS= read -r line; printf '%s\n' "$line"; done; cat >/dev/null; })
  expected=$(printf 'BUDGETING-RECOVERY-1\npostgres-major=%s\nschemas=public,private\nformat=plain-sql\napp-baseline=202611040001_budgeting' "$client")
  [[ $header == "$expected" ]] || fail 'Unsupported backup manifest or PostgreSQL major; target unchanged.'
  # The SQL is trusted executable content. Never restore an untrusted backup.
  # COMMIT is emitted only after decryption and safety sanitization succeed.
  if ! {
    printf 'BEGIN;\nDROP SCHEMA IF EXISTS private CASCADE;\nDROP SCHEMA public CASCADE;\n'
    decrypt | { for _ in 1 2 3 4 5 6; do IFS= read -r _; done; cat; } || exit 1
    cat /recovery/sanitize.sql || exit 1
    printf '\nCOMMIT;\n'
  } | sql >/dev/null; then
    fail 'Restore failed and transaction rolled back; verify target Auth UUIDs, roles and compatibility.'
  fi
  printf '%s\n' 'Restore complete. Provider state removed; keep Stripe/workers disabled. Reconcile Auth identity before access.'
  ;;
*) fail 'Expected backup or restore.' ;;
esac
