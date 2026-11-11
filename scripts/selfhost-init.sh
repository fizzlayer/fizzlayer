#!/bin/sh
# Write a secret .env by running `fizz-serve init` inside the API image.
# The host needs Docker, a POSIX shell, and (to download this file) curl.
# Inside a checkout this writes deploy/.env. On its own, it writes ./.env.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
if [ -f "$repo_root/deploy/docker-compose.yml" ] && [ -f "$repo_root/scripts/selfhost-init.sh" ]; then
  out="$repo_root/deploy/.env"
else
  out="$(pwd)/.env"
fi
force=
if [ "${1:-}" = "--force" ]; then
  force=--force
elif [ -n "${1:-}" ]; then
  echo "Unknown argument. Use --force to replace an existing file." >&2
  exit 1
fi
if [ -f "$out" ] && [ -z "$force" ]; then
  echo "$out already exists. Pass --force to replace it." >&2
  exit 1
fi
command -v docker >/dev/null 2>&1 || {
  echo "Docker is required to generate secrets." >&2
  exit 1
}
dir=$(CDPATH= cd -- "$(dirname "$out")" && pwd)
base=$(basename "$out")
image=${FIZZ_API_IMAGE:-fizzlayer/fizzlayer-api:latest}
docker run --rm --user "$(id -u):$(id -g)" -v "$dir:/out" "$image" init --out "/out/$base" $force
echo "Wrote $out"
