#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
export BUDGET_CONFIGURED_SMOKE=true
if [ "${BUDGET_HOSTED_SMOKE:-false}" = true ]; then
  if [ -n "${BUILD_CA_FILE:-}" ]; then
    docker build --secret "id=build_ca,src=$BUILD_CA_FILE" -f scripts/browser.Dockerfile -t budgeting-browser:latest .
  else
    docker build -f scripts/browser.Dockerfile -t budgeting-browser:latest .
  fi
  docker run --rm -e BUDGET_BROWSER_URL -e BUDGET_CONFIGURED_SMOKE -e BUDGET_HOSTED_SMOKE \
    -e SUPABASE_URL -e SUPABASE_PUBLISHABLE_KEY -e VERCEL_PROJECT_NAME -e VERCEL_AUTOMATION_BYPASS_SECRET budgeting-browser:latest
else
  export BUDGET_BROWSER_ARTIFACT=.vercel/output/static
  sh scripts/test-browser.sh
fi
