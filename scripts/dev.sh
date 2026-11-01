#!/usr/bin/env bash
# Run Fizzlayer locally with `vercel dev`.
#
#   scripts/dev.sh               Use your linked Vercel project's Development environment
#                                (a hosted development Supabase project).
#   scripts/dev.sh --local-db    Run Supabase in Docker and point the API at it.
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

  (
    umask 077
    printf '%s\nSUPABASE_URL=%s\nSUPABASE_SERVICE_ROLE_KEY=%s\nFIZZ_DEV_ORIGIN=%s\n' \
      "$env_marker" "$supabase_url" "$service_key" "$origin" >.env
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
  info "Create an invite in Studio's SQL editor:"
  printf "      select * from public.fizz_create_invites(1, 'Local development', interval '14 days');\n"
  info "Supabase keeps running after you exit; stop it with: supabase stop"
fi
info "Starting Fizzlayer at $origin (the first request compiles the API)"
FIZZ_DEV_ORIGIN="$origin" "${vercel[@]}" dev --listen "$port"
