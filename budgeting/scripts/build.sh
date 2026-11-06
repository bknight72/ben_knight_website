#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Only these public values are embedded. Never pass a backend .env to docker build.
set -- --target build -t budgeting-build:latest \
  --build-arg "SUPABASE_URL=${SUPABASE_URL:-}" \
  --build-arg "SUPABASE_PUBLISHABLE_KEY=${SUPABASE_PUBLISHABLE_KEY:-}" \
  --build-arg "STRIPE_PUBLISHABLE_KEY=${STRIPE_PUBLISHABLE_KEY:-}" \
  --build-arg "STRIPE_ENABLED=${STRIPE_ENABLED:-false}"
if [ -n "${BUILD_CA_FILE:-}" ]; then set -- "$@" --secret "id=build_ca,src=$BUILD_CA_FILE"; fi
docker build "$@" .
container=$(docker create budgeting-build:latest)
trap 'docker rm "$container" >/dev/null' EXIT INT TERM
# Replace stale static output instead of mixing previous build artifacts.
docker run --rm -v "$PWD:/workspace" -w /workspace denoland/deno:latest deno eval 'await Deno.remove("build/web", {recursive:true}).catch(e => {if (!(e instanceof Deno.errors.NotFound)) throw e;}); await Deno.mkdir("build/web", {recursive:true});'
mkdir -p build/web
docker cp "$container:/workspace/build/web/." build/web/
sh scripts/package-vercel.sh
