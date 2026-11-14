#!/usr/bin/env bash
# Compile the Gleam frontend and write the classic scripts in public/.
# Vercel serves those files as they are; it does not run Gleam.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/scripts/install-gleam.sh"

cd "${root}/frontend"
npm ci --no-audit --no-fund
gleam build --warnings-as-errors

npx esbuild \
  entries/sensor-kinds.js \
  entries/analytics.js \
  entries/nav.js \
  entries/status.js \
  entries/enterprise.js \
  entries/gateway-beta.js \
  --bundle \
  --format=iife \
  --platform=browser \
  --target=es2020 \
  --outdir="${root}/public" \
  --outbase=entries \
  --entry-names="[name]" \
  --banner:js="// Generated from frontend/ by scripts/build-frontend.sh. Do not edit."
