#!/bin/sh
set -eu

package=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
checkout_id=$(printf '%s' "$package" | cksum | cut -d ' ' -f 1)
name="budgeting-dev-$checkout_id"
image=budgeting-flutter:latest
action=${1:-start}
if [ -z "${BUILD_CA_FILE:-}" ] && [ -f "$package/dev-ca.local.crt" ]; then
  BUILD_CA_FILE="$package/dev-ca.local.crt"
fi

command -v docker >/dev/null 2>&1 || { printf '%s\n' 'Install/start Docker Desktop first.' >&2; exit 1; }
docker info >/dev/null 2>&1 || { printf '%s\n' 'Docker is unavailable. Start Docker Desktop and retry.' >&2; exit 1; }

owned() {
  label=$(docker inspect --format '{{index .Config.Labels "com.novacoast.budgeting.dev"}}' "$name" 2>/dev/null) || return 1
  [ "$label" = "$package" ] || { printf '%s\n' 'Container name collision; refusing to use an unrelated container.' >&2; exit 1; }
}

case "$action" in
  stop)
    if owned; then docker stop --time 10 "$name" >/dev/null; fi
    exit 0
    ;;
  reload|restart)
    owned || { printf '%s\n' 'Start the Budgeting development server first.' >&2; exit 1; }
    signal=USR1
    [ "$action" != restart ] || signal=USR2
    docker exec "$name" sh -ec 'test -f /workspace/flutter.pid; kill -"$1" "$(cat /workspace/flutter.pid)"' sh "$signal"
    exit 0
    ;;
  start) ;;
  *) printf '%s\n' 'Usage: sh budgeting/scripts/dev.sh start|reload|restart|stop' >&2; exit 1 ;;
esac

printf '%s\n' BUDGETING_DEV_STARTING
if owned; then
  printf '%s\n' 'This checkout already has a development container. Run the Stop Development Server task first.' >&2
  exit 1
fi

uid=$(id -u)
[ "$uid" -ne 0 ] || { printf '%s\n' 'Run development as the non-root checkout owner.' >&2; exit 1; }
if ! docker image inspect "$image" >/dev/null 2>&1; then
  set -- --target tooling --build-arg "BUILDER_UID=$uid" -t "$image"
  if [ -n "${BUILD_CA_FILE:-}" ]; then set -- "$@" --secret "id=build_ca,src=$BUILD_CA_FILE"; fi
  docker build "$@" "$package"
fi

# Mount only frontend inputs, never the package's backend .env or financial files.
set -- --rm --init --name "$name" --label "com.novacoast.budgeting.dev=$package" \
  -p 127.0.0.1:8180:8180 \
  --mount "type=volume,src=$name-work,dst=/workspace" \
  --mount "type=volume,src=$name-pub,dst=/home/builder/.pub-cache" \
  --mount "type=bind,src=$package/lib,dst=/source/lib,readonly" \
  --mount "type=bind,src=$package/web,dst=/source/web,readonly" \
  --mount "type=bind,src=$package/config.yaml,dst=/source/config.yaml,readonly" \
  --mount "type=bind,src=$package/pubspec.yaml,dst=/source/pubspec.yaml,readonly" \
  --mount "type=bind,src=$package/scripts/dev_server.dart,dst=/source/dev_server.dart,readonly"
if [ -n "${BUDGETING_DEV_PUBLIC_CONFIG:-}" ]; then
  [ -f "$BUDGETING_DEV_PUBLIC_CONFIG" ] || { printf '%s\n' 'BUDGETING_DEV_PUBLIC_CONFIG must be an absolute path to public JSON configuration.' >&2; exit 1; }
  set -- "$@" --mount "type=bind,src=$BUDGETING_DEV_PUBLIC_CONFIG,dst=/source/public-config.json,readonly"
fi
if [ -n "${BUILD_CA_FILE:-}" ]; then
  set -- "$@" --user root --mount "type=bind,src=$BUILD_CA_FILE,dst=/usr/local/share/ca-certificates/build-ca.crt,readonly"
fi

cleanup() { if owned; then docker stop --time 10 "$name" >/dev/null 2>&1 || true; fi; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [ -n "${BUILD_CA_FILE:-}" ]; then
  docker run "$@" "$image" sh -ec 'update-ca-certificates >/dev/null; exec su builder -s /bin/sh -c "export PATH=/opt/flutter/bin:\$PATH; exec dart /source/dev_server.dart"'
else
  docker run "$@" "$image" dart /source/dev_server.dart
fi
