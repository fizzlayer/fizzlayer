# Fizzlayer gateway

Fizzlayer's connection layer in front of a workspace's MCP servers. The data plane is **unmodified [agentgateway](https://github.com/agentgateway/agentgateway)** v1.7.0, pinned by image digest. Fizzlayer does not rebuild that image and does not use the agentgateway or Linux Foundation marks as its brand. See [NOTICE](NOTICE) and [UPSTREAM.md](UPSTREAM.md).

This directory is the part Fizzlayer owns:

| Piece | Role |
|---|---|
| `fizz-config` | Reads `gateway.servers` and writes agentgateway YAML. A rewrite is atomic, so the proxy's file watch can hot-reload it. |
| Client JWTs | ES256 tokens, `iss=fizzlayer`, `aud` = the gateway URL, `sub`, `ws`, `jti`. agentgateway checks them with `jwtAuth`. |
| `fizz-guard` | ExtMcp service on `tools/call`. Allow and deny are enforced. Approve stores a pending row and rejects; the same call is allowed once after that row is marked `approved`. Phone, Slack, and push are not wired. |
| `sample-mcp` | Three tools for the local test: `ping`, `admin_reset`, `move_funds`. |

Upstream credentials are not rendered. A server with `auth_kind` other than `none` fails the render instead of putting a secret in the YAML. Shared gateways refuse stdio servers.

## Local test

From the repository root, with Docker:

```sh
gateway/compose/test.sh
```

The script writes `gateway/compose/.env` with a random database password and does not print it. It applies the migration, runs `supabase/tests/gateway_rls.sql`, then an MCP client calls `ping` through the gateway with a Fizzlayer JWT. `admin_reset` is denied and leaves an audit row. `move_funds` is rejected with the approval-retry message and a pending approval. The sample server's counter stays at zero for both rejected tools.

Unit tests, including a check that the pinned agentgateway binary accepts the generated YAML:

```sh
gateway/scripts/fetch-agentgateway.sh
AGENTGATEWAY_BIN="$PWD/gateway/.local-bin/agentgateway" \
  REQUIRE_UPSTREAM_VALIDATE=1 \
  cargo test --locked --manifest-path gateway/Cargo.toml
```

`cargo test` alone skips that binary check.

To leave the stack up after a successful render:

```sh
cd gateway/compose
docker compose --env-file .env up -d postgres fizz-config fizz-config-watch fizz-guard sample-mcp agentgateway
```

The published port is `localhost:3000`. Tokens minted for this compose file use audience `http://agentgateway:3000/mcp`, which resolves inside the compose network.

## Database

`supabase/migrations/20261114000000_gateway.sql` adds the `gateway` schema: workspaces (one per customer account), gateways, servers, secrets, policies, tool pins, client tokens, approvals, audit, and daily usage. Row level security ties rows to `fizz_customers.auth_user_id`. `gateway.secrets` has no authenticated policy. Table privileges for `authenticated` stay revoked, same as the other server tables; the SQL test grants them inside a transaction that rolls back.

`gateway_runtime` is the login used by the local guard and config generator. The migration creates it `NOLOGIN`. Compose sets a password only in the local database.

Applying this to the hosted project is a separate step (`supabase db push` against the linked project). This directory does not add `gateway` to the Data API schemas in `supabase/config.toml`.

## What is stubbed

An `approve` policy inserts `gateway.approvals` with `status = pending` and returns:

`Approval required: an approver was notified (id …). Ask the user to approve, then retry the same call.`

Nothing notifies a person. Marking that row `approved` (the owner update policy allows it) lets one identical retry through. Tool pinning, metering caps, and upstream OAuth are not implemented. `usage_daily` counts calls the guard sees.
