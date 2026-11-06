#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
name="budgeting-runtime-$$"
trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT INT TERM
test -f build/web/main.dart.js || { printf '%s\n' 'Build the release artifact before runtime checks.' >&2; exit 1; }
docker run -d --name "$name" --user nginx --read-only \
  --tmpfs /tmp/nginx:rw,uid=101,gid=101,mode=0700 \
  -v "$PWD/build/web:/usr/share/nginx/html:ro" \
  -v "$PWD/nginx.conf:/etc/nginx/nginx.conf:ro" \
  --entrypoint nginx nginx:latest -g 'daemon off;' >/dev/null
docker exec "$name" nginx -t
docker exec "$name" curl --retry 5 --retry-connrefused --retry-delay 1 --fail --silent http://127.0.0.1:8080/health
docker stop --time 30 "$name" >/dev/null
test "$(docker inspect --format '{{.State.ExitCode}}' "$name")" = 0
