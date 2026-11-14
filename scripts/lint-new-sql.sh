#!/bin/sh
# Lint SQL files added since a base revision. Applied migrations are checksummed
# and are not reformatted, so this never opens a file that is already on the base.
set -eu

base=${1:-origin/main}

files=$(
  git diff --name-only --diff-filter=A "$base"...HEAD -- supabase/migrations supabase/tests \
    | grep '\.sql$' || true
)

if [ -z "$files" ]; then
  echo "No new SQL files to lint."
  exit 0
fi

echo "Linting new SQL:"
printf '%s\n' "$files"

set --
# shellcheck disable=SC2086
while IFS= read -r file; do
  set -- "$@" "$file"
done <<EOF
$files
EOF

python3 -m sqlfluff lint "$@"
