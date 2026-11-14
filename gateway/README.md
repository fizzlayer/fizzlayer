# Fizzlayer gateway

Fizzlayer's connection layer in front of a workspace's MCP servers. The data plane is **unmodified [agentgateway](https://github.com/agentgateway/agentgateway)** v1.7.0, pinned by image digest. Fizzlayer does not rebuild that image and does not use the agentgateway or Linux Foundation marks as its brand. See [NOTICE](NOTICE) and [UPSTREAM.md](UPSTREAM.md).

This directory is the part Fizzlayer owns:

| Piece | Role |
|---|---|
| `fizz-config` | Reads `gateway.servers` and writes agentgateway YAML. A rewrite is atomic, so the proxy's file watch can hot-reload it. |
| Client JWTs | ES256 tokens, `iss=fizzlayer`, `aud` = the gateway URL, `sub`, `ws`, `jti`. agentgateway checks them with `jwtAuth`. |
| `fizz-guard` | ExtMcp service. `tools/call` is allow, deny, or approve. `tools/list` pins each tool's name, description, and input schema. A changed description is removed from the list. A call is denied unless that pin is approved. |
| `sample-mcp` | Three tools for the local test: `ping`, `admin_reset`, `move_funds`. |

Upstream credentials are not rendered. A server with `auth_kind` other than `none` fails the render instead of putting a secret in the YAML. Shared gateways refuse stdio servers.

## Local test

From the repository root, with Docker:

```sh
gateway/compose/test.sh
```

The script writes `gateway/compose/.env` with a random database password and admin token and does not print them. It applies the gateway migrations, runs `supabase/tests/gateway_rls.sql`, then an MCP client calls through the gateway with a Fizzlayer JWT.

The probe checks three things:

- `ping` is allowed. `admin_reset` is denied. Neither rejected call reaches the sample server.
- `note` starts with an approved pin. After its description changes, `tools/list` no longer includes it, `tools/call` is rejected, and a pin alert is stored.
- `move_funds` is rejected with the approval-retry message. The local approval API marks that row approved. The same call is then allowed once. A second retry is rejected again, and the sample server's counter stays at 1.

The local seed sets `unreviewed_tools` to `show` so that first list can be approved. The column default elsewhere is `hide`.

While that stack is up, the approval page is at <http://127.0.0.1:9002/>. Paste `FIZZ_GUARD_ADMIN_TOKEN` from `gateway/compose/.env`. The page does not place a phone call.

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

`supabase/migrations/20261114000000_gateway.sql` adds the `gateway` schema: workspaces (one per customer account), gateways, servers, secrets, policies, tool pins, client tokens, approvals, audit, and daily usage. `supabase/migrations/20261114000300_gateway_policies.sql` adds pin status, pin alerts, the approval preview, and the shared phone-call budget function. Row level security ties rows to `fizz_customers.auth_user_id`. `gateway.secrets` has no authenticated policy. Table privileges for `authenticated` stay revoked, same as the other server tables; the SQL test grants them inside a transaction that rolls back.

`20261114000400` is reserved for the control-plane API and is not used here. Applying `20261114000300_gateway_policies.sql` to the hosted project is a separate step (`supabase db push` against the linked project). This directory does not do that.

`gateway_runtime` is the login used by the local guard and config generator. The migration creates it `NOLOGIN`. Compose sets a password only in the local database.

This directory does not add `gateway` to the Data API schemas in `supabase/config.toml`.

## Policies

`gateway.gateways.unreviewed_tools` is `hide` or `show` (default `hide`). A tool the guard has not seen is stored with `status = unreviewed`. `hide` removes it from `tools/list`. `show` leaves it listed. Either way, `tools/call` is denied until the pin is approved.

An approved pin stores `sha256` of the canonical JSON `{"description","inputSchema","name"}`. If a later `tools/list` has a different hash, the tool is removed from that list, `status` becomes `changed`, and `gateway.pin_alerts` gets one open row. The description preview on that row is untrusted text from the MCP server, cut to 200 characters. `tools/call` stays denied until the observed hash is approved.

Approving a pending call is single-use. The guard stores `sha256` of the canonical arguments, rejects with:

`Approval required: an approver was notified (id …). Ask the user to approve, then retry the same call.`

and returns immediately. The default TTL is 10 minutes (`FIZZ_APPROVAL_TTL_SECS`). The guard does not wait inside the 10-second agentgateway timeout.

Notifications go through the policy's `notify_channel`:

| Channel | What fizz-guard does |
|---|---|
| `log` | Writes one line: channel, tool, server, short id, result. No argument values. |
| `webhook` | POSTs that same summary to `FIZZ_APPROVAL_WEBHOOK_URL` with a 2-second timeout. A URL with a username or password is ignored. If the POST fails, the approval row still exists. |
| `phone` | Checks `gateway.phone_approval_budget`. It does **not** place a call and does **not** call `gateway.reserve_phone_approval_call`. Hobbyist is 0 calls, Tinkerer 20, Pro 100, shared with sensor phone alerts for the UTC month. Enterprise is unlimited. If those billing tables are not in the database, the function returns `billing_unreachable` and `allowed: false`, and the attempt is recorded as `skipped`. A stubbed attempt (`stubbed`) means the budget would have allowed a call; it still does not dial and does not count. Only `reserved`, which this process never writes, counts toward the cap. |

The real dialer, when you want one, is the AgentPhone client in `src/notify.rs`. It is a different package. Wire it to `reserve_phone_approval_call` before it dials.

Self-host compose uses Postgres, the same as the local test. `DATABASE_URL=memory://` keeps pins and approvals in memory and drops them when the process exits. That store has no billing tables, so a phone approval is always `billing_unreachable`. SQLite is not wired.

Set `FIZZ_GUARD_ADMIN_TOKEN` to open the local API on `FIZZ_GUARD_ADMIN_LISTEN` (default `127.0.0.1:9002`):

- `GET /approvals` and `POST /approvals/decision` with `{"id","status":"approved"|"denied"}`
- `GET /alerts` and `POST /alerts/approve` with `{"gateway_id","server","tool"}`
- `GET /` is the same actions as a page

Send `Authorization: Bearer <token>`. Without the token, the admin listener stays off and approvals can still be updated in SQL by the owning user. The token can decide every pending row in that database. Do not publish port 9002 on a shared gateway.

`usage_daily` counts calls the guard sees. Metering caps and upstream OAuth are not implemented. `failureMode` stays `failClosed`: if fizz-guard is down, or this process returns an error, agentgateway denies the call.
