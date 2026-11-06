#!/usr/bin/env bash
set -euo pipefail
set +x
[[ $# == 5 || $# == 6 ]] || { printf 'Usage: bash budgeting/scripts/restore.sh PRIVATE_TARGET_ENV AGE_IDENTITY BACKUP.age disposable_NAME "RESTORE disposable_NAME" [PUBLIC_DATABASE_CA]\n' >&2; exit 1; }
root=$(cd "$(dirname "$0")/../recovery" && pwd)
[[ -f $1 && -f $2 && -f $3 ]] || { printf 'Private target environment, identity and ciphertext must exist.\n' >&2; exit 1; }
envfile=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
identity=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
backup=$(cd "$(dirname "$3")" && pwd)/$(basename "$3")
ca_args=()
if [[ $# == 6 ]]; then
  [[ -f $6 ]] || { printf 'Public database CA file must exist.\n' >&2; exit 1; }
  ca=$(cd "$(dirname "$6")" && pwd)/$(basename "$6")
  ca_args=(--mount "type=bind,src=$ca,dst=/run/database-ca.crt,readonly")
fi
docker build --pull -q -t budgeting-recovery:latest "$root" >/dev/null
docker run --rm --user "$(id -u):$(id -g)" --read-only --tmpfs /tmp:rw,noexec,nosuid,mode=1777 --env-file "$envfile" "${ca_args[@]}" --mount "type=bind,src=$identity,dst=/run/identity,readonly" --mount "type=bind,src=$backup,dst=/run/backup.age,readonly" budgeting-recovery:latest restore "$4" "$5"
