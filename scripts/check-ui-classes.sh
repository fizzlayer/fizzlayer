#!/usr/bin/env bash
# Screens in the Gleam app get their look from app/src/ui.gleam only.
# Fail if any other module names a CSS class, so styles cannot drift per page.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root/app/src"

if hits="$(grep -rn --include='*.gleam' -E 'attribute\.class(es)?\(' . | grep -v '^\./ui\.gleam:')"; then
  printf 'CSS classes belong in app/src/ui.gleam. Use a ui function instead:\n%s\n' "$hits" >&2
  exit 1
fi
printf 'ui class check passed\n'
