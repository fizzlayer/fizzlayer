#!/usr/bin/env bash
# Run Fizzlayer locally with `vercel dev`.
#
#   scripts/dev.sh               Use your linked Vercel project's Development environment
#                                (a hosted development Supabase project).
#   scripts/dev.sh --local-db    Run Supabase in Docker and point the API at it. STRIPE_*
#                                variables set in this shell (test-mode keys) are passed on.
#
# Options:
#   --port N       Port for the app (default 3000; Supabase Auth redirects expect 3000)
#   --skip-check   Skip `cargo check` before starting
#   -h, --help     Show this help
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

local_db=0
port=3000
skip_check=0
env_marker="# Written by scripts/dev.sh --local-db; removed when it exits."

usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local-db) local_db=1 ;;
    --port) [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || die "--port needs a number"; port="$2"; shift ;;
    --skip-check) skip_check=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
  shift
done

origin="http://localhost:$port"
status_pid=""

cleanup() {
  [[ -n "$status_pid" ]] && kill "$status_pid" 2>/dev/null
  if [[ $local_db -eq 1 && -f .env && "$(head -n1 .env)" == "$env_marker" ]]; then
    rm -f .env
  fi
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Prefer installed CLIs; fall back to npx so a first run needs only Node.js.
vercel=(vercel)
if ! command -v vercel >/dev/null; then
  command -v npx >/dev/null || die "install the Vercel CLI (npm i -g vercel)"
  warn "vercel not found; using npx vercel (install it with: npm i -g vercel)"
  vercel=(npx --yes vercel)
fi
command -v cargo >/dev/null || die "install stable Rust from https://rustup.rs"

if [[ ! -f .vercel/project.json ]]; then
  info "Linking this directory to a Vercel project"
  "${vercel[@]}" link
fi

if [[ $local_db -eq 1 ]]; then
  supabase=(supabase)
  if ! command -v supabase >/dev/null; then
    command -v npx >/dev/null || die "install the Supabase CLI: https://supabase.com/docs/guides/local-development/cli/getting-started"
    warn "supabase not found; using npx supabase"
    supabase=(npx --yes supabase)
  fi
  docker info >/dev/null 2>&1 || die "Docker is not running; start it and try again"

  # vercel dev reads a .env file instead of the project's cloud variables, so a temporary
  # one points the API at the local database. Never overwrite a .env we did not write.
  if [[ -f .env ]] && [[ "$(head -n1 .env)" != "$env_marker" ]]; then
    die ".env already exists; move it aside to use --local-db"
  fi

  if ! "${supabase[@]}" status >/dev/null 2>&1; then
    info "Starting local Supabase (the first run downloads its Docker images)"
    "${supabase[@]}" start
  fi
  status="$("${supabase[@]}" status -o env)"
  read_status() { sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p" <<<"$status" | head -n1; }
  supabase_url="$(read_status API_URL)"
  service_key="$(read_status SERVICE_ROLE_KEY)"
  [[ -n "$supabase_url" && -n "$service_key" ]] || die "could not read the local Supabase URL and service-role key"

  # The .env replaces the project's cloud variables, so pass Stripe settings from this shell.
  stripe_env="$(env | grep -E '^STRIPE_[A-Z_]+=' | sort || true)"
  case "$stripe_env" in
    *"STRIPE_SECRET_KEY="[rs]k_live_*) die "use a test-mode Stripe key with --local-db, not a live one" ;;
  esac
  stripe_count="$(grep -cE '^STRIPE_(SECRET_KEY|WEBHOOK_SECRET|PRICE_TINKERER|PRICE_PRO)=.' <<<"$stripe_env" || true)"
  if [[ $stripe_count -gt 0 && $stripe_count -lt 4 ]]; then
    warn "billing needs STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET, STRIPE_PRICE_TINKERER and STRIPE_PRICE_PRO; $stripe_count of 4 are set"
  fi

  (
    umask 077
    printf '%s\nSUPABASE_URL=%s\nSUPABASE_SERVICE_ROLE_KEY=%s\nFIZZ_DEV_ORIGIN=%s\n' \
      "$env_marker" "$supabase_url" "$service_key" "$origin" >.env
    if [[ -n "$stripe_env" ]]; then printf '%s\n' "$stripe_env" >>.env; fi
  )
elif [[ -f .env ]]; then
  warn ".env exists, so vercel dev uses it instead of your project's Development variables"
fi

if [[ $skip_check -eq 0 ]]; then
  info "Checking the Rust API compiles"
  cargo check --locked
fi

# Report database connectivity once the API has compiled and answered.
(
  for _ in $(seq 1 300); do
    if body="$(curl -fsS --max-time 300 "$origin/api/status" 2>/dev/null)"; then
      if grep -q '"database": *"connected"' <<<"$body"; then
        info "Fizzlayer is ready at $origin (database connected)"
      else
        warn "the API is up but /api/status reports: $body"
      fi
      exit 0
    fi
    sleep 2
  done
) &
status_pid=$!

if [[ $local_db -eq 1 ]]; then
  info "Supabase Studio: http://127.0.0.1:54323 · Email inbox: http://127.0.0.1:54324"
  info "Create an account at the app URL, then confirm it from the email inbox."
  info "Supabase keeps running after you exit; stop it with: supabase stop"
fi
if [[ ! -f public/analytics.js || ! -f public/nav.js || ! -f public/sensor-kinds.js || ! -f public/status.js || ! -f public/enterprise.js || ! -f public/gateway-beta.js ]]; then
  info "Building the Gleam frontend"
  "${root}/scripts/build-frontend.sh"
fi
info "Starting Fizzlayer at $origin (the first request compiles the API)"
FIZZ_DEV_ORIGIN="$origin" "${vercel[@]}" dev --listen "$port"
