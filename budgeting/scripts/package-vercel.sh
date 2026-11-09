#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Run after the public-configured release build. Never copy the source or .env.
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:/workspace" -w /workspace denoland/deno:latest sh -ec 'deno run --allow-read scripts/audit-artifact.ts && deno run --allow-read --allow-write scripts/package-vercel.ts'
