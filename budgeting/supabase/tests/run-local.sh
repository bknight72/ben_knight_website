#!/bin/sh
set -eu
# Run on the host; dependencies and the Supabase CLI run only in containers.
# Local-only and disposable: refuses pre-existing project containers to protect operator data.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
EXISTING=$(docker ps -a --filter name=_private-budgeting --format '{{.Names}}')
if [ -n "$EXISTING" ]; then
  printf '%s\n' 'Refusing existing private-budgeting stack. Stop it explicitly before a fresh isolated run.' >&2
  exit 1
fi
set --
if [ -n "${BUDGETING_CA_CERT:-}" ]; then
  set -- --secret "id=corporate_ca,src=$BUDGETING_CA_CERT"
fi
if [ "${BUDGETING_LOCAL_REUSE_IMAGE:-false}" = true ]; then
  docker image inspect budgeting-supabase-test:latest >/dev/null
else
  docker build "$@" -t budgeting-supabase-test:latest -f "$ROOT/supabase/tests/Dockerfile" "$ROOT/supabase/tests"
fi
set --
if [ -n "${BUDGETING_CA_CERT:-}" ]; then
  set -- -v "$BUDGETING_CA_CERT:/run/corporate-ca.crt:ro" -e NODE_EXTRA_CA_CERTS=/run/corporate-ca.crt
fi
if [ "${BUDGETING_BROWSER_INTEGRATION:-false}" = true ]; then
  ARTIFACT=${BUDGETING_BROWSER_ARTIFACT:-$ROOT/build/web}
  if [ ! -f "$ARTIFACT/main.dart.js" ]; then
    printf '%s\n' 'Browser integration requires an existing release artifact configured for local Supabase.' >&2
    exit 1
  fi
  docker image inspect budgeting-browser:latest >/dev/null
  VOLUME="budgeting-browser-fixture-$$"
  docker volume create --driver local --opt type=tmpfs --opt device=tmpfs --opt o=size=1m "$VOLUME" >/dev/null
  trap 'docker volume rm "$VOLUME" >/dev/null 2>&1 || true' EXIT INT TERM
  set -- "$@" -v "$VOLUME:/run/budgeting-browser" \
    -e BUDGETING_BROWSER_INTEGRATION=true -e LOCAL_BROWSER_FIXTURE=/run/budgeting-browser/fixture.json \
    -e "LOCAL_BROWSER_VOLUME=$VOLUME" -e "LOCAL_BROWSER_ARTIFACT=$ARTIFACT" -e "LOCAL_BROWSER_SERVER=budgeting-auth-browser-$$"
fi
docker run --rm --network host \
  "$@" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$ROOT:$ROOT" -w "$ROOT" \
  budgeting-supabase-test:latest sh supabase/tests/local-container.sh
