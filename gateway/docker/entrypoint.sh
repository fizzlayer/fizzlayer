#!/bin/sh
# Local dev entrypoint. It does not print its arguments or the environment.
# Root is used only to hand the key and config directories to uid 65532.
set -eu
if [ "$(id -u)" -eq 0 ]; then
  mkdir -p /keys /config
  chown 65532:65532 /keys /config 2>/dev/null || true
  if command -v setpriv >/dev/null 2>&1; then
    exec setpriv --reuid 65532 --regid 65532 --init-groups --inh-caps -all "$@"
  fi
fi
exec "$@"
