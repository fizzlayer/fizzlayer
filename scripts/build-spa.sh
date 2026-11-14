#!/usr/bin/env bash
# Build the Gleam SPA into public/app. Does not compile the Rust API.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

bash "$root/scripts/install-gleam-toolchain.sh"
# shellcheck disable=SC1091
source "${FIZZ_TOOLCHAIN:-/tmp/fizz-gleam-toolchain}/env.sh"

python3 "$root/scripts/write_spa_config.py" "$root/app/assets/config.json"

cd "$root/app"
npm ci
gleam run -m lustre/dev build --minify --outdir=dist
python3 "$root/scripts/prefix_spa_assets.py" dist/index.html

rm -rf "$root/public/app"
mkdir -p "$root/public/app"
cp -a dist/. "$root/public/app/"

test -f "$root/public/app/index.html"
test -f "$root/public/app/fizz_spa.js"
test -f "$root/public/app/spa.css"
test -f "$root/public/app/config.json"
grep -q 'src="/app/fizz_spa.js"' "$root/public/app/index.html"
grep -q 'href="/app/spa.css"' "$root/public/app/index.html"
# The existing site script stays at /app.js. The bundle lives under /app/.
test -f "$root/public/app.js"
test -f "$root/public/install.sh"
test -f "$root/public/ha.html"
test ! -e "$root/public/fizz_spa.js"

if [[ "${VERCEL:-}" == "1" ]]; then
  rm -rf "$root/app/node_modules" "$root/app/build" "$root/app/.lustre" "$root/app/dist"
fi

printf 'SPA built at public/app\n'
