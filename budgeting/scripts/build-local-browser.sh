#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Explicit synthetic variant; the normal local artifact remains Stripe-disabled.
case "${BUDGETING_MOCK_STRIPE:-false}" in
  false) STRIPE_ENABLED=false; STRIPE_KEY=; OUTPUT=build/local-browser ;;
  true) STRIPE_ENABLED=true; STRIPE_KEY=pk_test_localSyntheticOnly123; OUTPUT=build/local-browser-stripe ;;
  *) printf '%s\n' 'BUDGETING_MOCK_STRIPE must be true or false' >&2; exit 1 ;;
esac
# Public disposable Supabase CLI key, never a hosted secret. Separate artifact.
if [ -n "${BUILD_CA_FILE:-}" ]; then
  set -- -v "$BUILD_CA_FILE:/usr/local/share/ca-certificates/build-ca.crt:ro"
else
  set --
fi
docker run --rm -u root "$@" -e "LOCAL_STRIPE_ENABLED=$STRIPE_ENABLED" -e "LOCAL_STRIPE_KEY=$STRIPE_KEY" -e "LOCAL_BROWSER_OUTPUT=$OUTPUT" -e "LOCAL_PUB_OFFLINE=${BUDGETING_PUB_OFFLINE:-false}" -v "$PWD:/workspace" -w /workspace "${BUDGETING_FLUTTER_IMAGE:-budgeting-flutter:latest}" sh -ec '
  update-ca-certificates >/dev/null
  exec su builder -s /bin/sh -c '\''
    set -eu
    export PATH=/opt/flutter/bin:$PATH
    if [ "$LOCAL_PUB_OFFLINE" = true ]; then flutter pub get --offline; else flutter pub get; fi
    flutter build web --no-pub --release --no-web-resources-cdn --output "$LOCAL_BROWSER_OUTPUT" \
      --dart-define=SUPABASE_URL=http://127.0.0.1:54321 \
      --dart-define=SUPABASE_PUBLISHABLE_KEY=sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH \
      --dart-define=STRIPE_ENABLED="$LOCAL_STRIPE_ENABLED" \
      --dart-define=STRIPE_PUBLISHABLE_KEY="$LOCAL_STRIPE_KEY"
  '\''
'
printf '{"mockStripe":%s}\n' "${BUDGETING_MOCK_STRIPE:-false}" > "$OUTPUT/local-integration.json"
