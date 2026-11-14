#!/usr/bin/env bash
# Put Gleam 1.19.2 on PATH. Reuses a copy already installed in frontend/.tool.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="1.19.2"
tool="${root}/frontend/.tool"
mkdir -p "${tool}"

if [[ -x "${tool}/gleam" ]] && [[ "$("${tool}/gleam" --version)" == "gleam ${version}" ]]; then
  :
elif command -v gleam >/dev/null 2>&1 && [[ "$(gleam --version)" == "gleam ${version}" ]]; then
  tool="$(dirname "$(command -v gleam)")"
else
  archive="${tool}/gleam.tar.gz"
  url="https://github.com/gleam-lang/gleam/releases/download/v${version}/gleam-v${version}-x86_64-unknown-linux-musl.tar.gz"
  curl -fsSL "${url}" -o "${archive}"
  tar -xzf "${archive}" -C "${tool}"
  rm -f "${archive}"
fi

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "${tool}" >> "${GITHUB_PATH}"
fi

export PATH="${tool}:${PATH}"
