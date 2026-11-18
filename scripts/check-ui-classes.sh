#!/usr/bin/env bash
# Gleam pages get their look from app/src/ui.gleam and app/src/ui/ only.
# Fail if any other module names a CSS class, so styles cannot drift per page.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root/app/src"

if hits="$(grep -rn --include='*.gleam' -E 'attribute\.class(es)?\(' . | grep -vE '^\./ui(\.gleam|/)')"; then
  printf 'CSS classes belong in app/src/ui.gleam or app/src/ui/. Use a ui function instead:\n%s\n' "$hits" >&2
  exit 1
fi
printf 'ui class check passed\n'
