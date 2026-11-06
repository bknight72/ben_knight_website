#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Parse configuration inside a container; never install validation packages on host.
docker run --rm -v "$PWD/..:/repo:ro" -w /repo denoland/deno:latest deno run --allow-read budgeting/scripts/test-config.ts
