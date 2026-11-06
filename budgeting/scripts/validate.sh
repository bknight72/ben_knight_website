#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
sh scripts/test-config.sh
builder_uid=$(id -u)
if [ "$builder_uid" -eq 0 ]; then
  printf '%s\n' 'Run validation as a non-root checkout owner so build outputs remain writable.' >&2
  exit 1
fi
if [ -n "${BUILD_CA_FILE:-}" ]; then
  docker build --target tooling --build-arg "BUILDER_UID=$builder_uid" --secret "id=build_ca,src=$BUILD_CA_FILE" -t budgeting-flutter:latest .
  set -- -v "$BUILD_CA_FILE:/usr/local/share/ca-certificates/build-ca.crt:ro"
else
  docker build --target tooling --build-arg "BUILDER_UID=$builder_uid" -t budgeting-flutter:latest .
  set --
fi
docker run --rm -u root "$@" -v "$PWD:/workspace" -w /workspace budgeting-flutter:latest sh -ec '
  update-ca-certificates >/dev/null
  exec su builder -s /bin/sh -c '\''
   set -eu
  export PATH=/opt/flutter/bin:$PATH
  flutter pub get
  dart format --output=none --set-exit-if-changed lib test integration_test scripts/check_coverage.dart
  flutter analyze
  flutter test --timeout 60s --coverage
  dart scripts/check_coverage.dart coverage/lcov.info lib/app.dart lib/domain.dart lib/config.dart lib/repository.dart lib/main.dart
  flutter build web --release --no-web-resources-cdn
  '\''
'
docker run --rm -v "$PWD:/workspace:ro" -w /workspace denoland/deno:latest deno test --allow-read test/bridge_test.js
docker run --rm -v "$PWD:/workspace:ro" -w /workspace denoland/deno:latest deno fmt --check scripts/audit-artifact.ts scripts/audit-artifact_test.ts scripts/package-vercel.ts scripts/package-vercel_test.ts scripts/test-config.ts
docker run --rm -v "$PWD:/workspace:ro" -w /workspace denoland/deno:latest deno test --allow-read --allow-write scripts/package-vercel_test.ts scripts/audit-artifact_test.ts
docker run --rm -v "$PWD:/workspace" -w /workspace/supabase denoland/deno:latest sh -ec '
  sh tests/run-deno.sh
  cp /tmp/budgeting-coverage/lcov.info /workspace/coverage/backend.lcov
'
docker run --rm -v "$PWD:/workspace:ro" -w /workspace budgeting-flutter:latest dart scripts/check_coverage.dart coverage/backend.lcov functions/_shared/core.ts functions/_shared/runtime.ts functions/_shared/openapi.ts functions/api/handler.ts functions/worker/handler.ts functions/stripe-webhook/handler.ts
sh scripts/test-database.sh
sh scripts/test-browser.sh
sh scripts/test-runtime.sh
docker build -t budgeting-recovery:latest recovery
docker run --rm --network none --read-only \
  --tmpfs /tmp:rw,nosuid,mode=1777 --tmpfs /run:rw,nosuid,mode=1777 \
  -v "$PWD:/workspace:ro" --entrypoint bash budgeting-recovery:latest /workspace/recovery/test.sh
