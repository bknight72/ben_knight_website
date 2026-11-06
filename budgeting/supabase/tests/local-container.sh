#!/bin/sh
set -eu
# Never load operator env files or enable Stripe. CLI binds only local development ports.
export STRIPE_ENABLED=false STRIPE_LIVE_AUTHORIZED=false
# Bound transient registry failures; all package operations remain container-only.
export npm_config_fetch_retries=2 npm_config_fetch_timeout=30000
supabase_cli() {
  if command -v supabase >/dev/null 2>&1; then supabase "$@"; else npx --yes supabase "$@"; fi
}
cleanup() {
  if [ -n "${LOCAL_BROWSER_SERVER:-}" ]; then docker rm -f "$LOCAL_BROWSER_SERVER" >/dev/null 2>&1 || true; fi
  supabase_cli stop --no-backup >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM
supabase_cli start -x studio,imgproxy,storage-api,realtime,postgres-meta,logflare,vector,supavisor
supabase_cli status -o json | deno run --allow-read --allow-write=/run/budgeting-browser --allow-env --allow-net --allow-run supabase/tests/local-runner.ts
