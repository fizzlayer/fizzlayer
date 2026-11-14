#!/bin/sh
# Download the pinned upstream release binary to validate generated YAML.
# The file is gitignored. Its checksum is gateway/pins/agentgateway.toml.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
pin="$root/pins/agentgateway.toml"
dest="$root/.local-bin/agentgateway"
expected=$(sed -n 's/^linux_amd64_sha256 = "\([0-9a-f]*\)"/\1/p' "$pin")
version=$(sed -n 's/^version = "\([^"]*\)"/\1/p' "$pin")
mkdir -p "$root/.local-bin"
tmp=$(mktemp)
curl -fsSL -o "$tmp" "https://github.com/agentgateway/agentgateway/releases/download/v${version}/agentgateway-linux-amd64"
actual=$(sha256sum "$tmp" | awk '{print $1}')
if [ "$actual" != "$expected" ]; then
  rm -f "$tmp"
  echo "upstream binary checksum did not match the pin" >&2
  exit 1
fi
mv "$tmp" "$dest"
chmod 755 "$dest"
echo "$dest"
