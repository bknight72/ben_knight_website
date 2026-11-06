#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077
[[ $# == 3 || $# == 4 ]] || { printf 'Usage: bash budgeting/scripts/backup.sh PRIVATE_DB_ENV AGE_RECIPIENTS OUTPUT.age [PUBLIC_DATABASE_CA]\n' >&2; exit 1; }
root=$(cd "$(dirname "$0")/../recovery" && pwd)
[[ -f $1 && -f $2 && -d $(dirname "$3") && ! -e $3 ]] || { printf 'Require existing private inputs/output directory and a new output path.\n' >&2; exit 1; }
envfile=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
recipients=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
ca_args=()
if [[ $# == 4 ]]; then
  [[ -f $4 ]] || { printf 'Public database CA file must exist.\n' >&2; exit 1; }
  ca=$(cd "$(dirname "$4")" && pwd)/$(basename "$4")
  ca_args=(--mount "type=bind,src=$ca,dst=/run/database-ca.crt,readonly")
fi
docker build --pull -q -t budgeting-recovery:latest "$root" >/dev/null
partial=$(mktemp "${3}.partial.XXXXXX")
trap 'rm -f "$partial"' EXIT
docker run --rm --user "$(id -u):$(id -g)" --read-only --tmpfs /tmp:rw,noexec,nosuid,mode=1777 --env-file "$envfile" "${ca_args[@]}" --mount "type=bind,src=$recipients,dst=/run/recipients,readonly" budgeting-recovery:latest backup >"$partial"
[[ -s $partial ]] || exit 1
# Hard-link publication refuses to overwrite even if a competing writer appeared.
ln "$partial" "$3"
printf 'Encrypted backup created. Store outside Git and public hosting.\n'
