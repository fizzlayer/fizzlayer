#!/bin/sh
# Starts fizz-guard, fizz-agent, and the unmodified agentgateway in one container.
# It does not print the environment or the config file.
set -eu
port="${PORT:-3000}"
export FIZZ_LISTEN_PORT="$port"
export FIZZ_CONFIG_OUT="${FIZZ_CONFIG_OUT:-/tmp/fizz-config.yaml}"
export FIZZ_GUARD_LISTEN="${FIZZ_GUARD_LISTEN:-127.0.0.1:9001}"
unset FIZZ_GUARD_ADMIN_TOKEN || true

fizz-guard serve &
guard_pid=$!
fizz-agent pull &
agent_pid=$!

i=0
while [ ! -s "$FIZZ_CONFIG_OUT" ]; do
  i=$((i + 1))
  if [ "$i" -gt 60 ]; then
    echo "fizz-hosted: config was not ready" >&2
    kill "$guard_pid" "$agent_pid" 2>/dev/null || true
    exit 1
  fi
  if ! kill -0 "$guard_pid" 2>/dev/null || ! kill -0 "$agent_pid" 2>/dev/null; then
    echo "fizz-hosted: a process stopped" >&2
    exit 1
  fi
  sleep 1
done

agentgateway -f "$FIZZ_CONFIG_OUT" &
proxy_pid=$!

while kill -0 "$guard_pid" 2>/dev/null && kill -0 "$agent_pid" 2>/dev/null && kill -0 "$proxy_pid" 2>/dev/null; do
  sleep 2
done
echo "fizz-hosted: a process stopped" >&2
kill "$guard_pid" "$agent_pid" "$proxy_pid" 2>/dev/null || true
exit 1
