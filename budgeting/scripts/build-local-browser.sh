#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Public disposable Supabase CLI key, never a hosted secret. Separate artifact.
if [ -n "${BUILD_CA_FILE:-}" ]; then
  set -- -v "$BUILD_CA_FILE:/usr/local/share/ca-certificates/build-ca.crt:ro"
else
  set --
fi
docker run --rm -u root "$@" -v "$PWD:/workspace" -w /workspace budgeting-flutter:latest sh -ec '
  update-ca-certificates >/dev/null
  exec su builder -s /bin/sh -c '\''
    set -eu
    export PATH=/opt/flutter/bin:$PATH
    flutter pub get
    flutter build web --no-pub --release --no-web-resources-cdn --output build/local-browser \
      --dart-define=SUPABASE_URL=http://127.0.0.1:54321 \
      --dart-define=SUPABASE_PUBLISHABLE_KEY=sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH \
      --dart-define=STRIPE_ENABLED=false
  '\''
'
