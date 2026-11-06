#!/bin/sh
set -eu
# Invoke inside denoland/deno:latest with supabase mounted at /work.
deno check functions/api/index.ts functions/stripe-webhook/index.ts functions/worker/index.ts
deno test --allow-env --coverage=/tmp/budgeting-coverage tests
deno coverage --lcov --output=/tmp/budgeting-coverage/lcov.info /tmp/budgeting-coverage
deno run --allow-read tests/check_coverage.ts /tmp/budgeting-coverage/lcov.info
