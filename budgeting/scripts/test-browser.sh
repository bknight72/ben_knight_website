#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
name="budgeting-browser-$$"
trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT INT TERM
test -f build/web/main.dart.js || { printf '%s\n' 'Build the release artifact before browser tests.' >&2; exit 1; }
if [ -n "${BUILD_CA_FILE:-}" ]; then
  docker build --secret "id=build_ca,src=$BUILD_CA_FILE" -f scripts/browser.Dockerfile -t budgeting-browser:latest .
else
  docker build -f scripts/browser.Dockerfile -t budgeting-browser:latest .
fi
docker run -d --name "$name" --user nginx --read-only \
  --tmpfs /tmp/nginx:rw,uid=101,gid=101,mode=0700 \
  -v "$PWD/${BUDGET_BROWSER_ARTIFACT:-build/web}:/usr/share/nginx/html:ro" \
  -v "$PWD/nginx.conf:/etc/nginx/nginx.conf:ro" \
  --entrypoint nginx nginx:latest -g 'daemon off;' >/dev/null
# Shared network namespace avoids fixed ports or host service dependencies.
docker run --rm --network "container:$name" -e BUDGET_BROWSER_URL=http://127.0.0.1:8080 \
  -e BUDGET_CONFIGURED_SMOKE -e SUPABASE_URL -e SUPABASE_PUBLISHABLE_KEY \
  -e STRIPE_ENABLED -e STRIPE_PUBLISHABLE_KEY budgeting-browser:latest
