# Fizzlayer gateway

Fizzlayer's connection layer in front of a workspace's MCP servers. The data plane is **unmodified [agentgateway](https://github.com/agentgateway/agentgateway)** v1.7.0, pinned by image digest. Fizzlayer does not rebuild that image and does not use the agentgateway or Linux Foundation marks as its brand. See [NOTICE](NOTICE) and [UPSTREAM.md](UPSTREAM.md).

This directory is the part Fizzlayer owns:

| Piece | Role |
|---|---|
| `fizz-config` | Reads `gateway.servers` and writes agentgateway YAML. A rewrite is atomic, so the proxy's file watch can hot-reload it. This is the local standalone path. |
| `fizz-agent` | Linked mode. Polls `GET /api/gateway/agent/config` with a registration token and writes that same file. It does not print the token or the YAML. |
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

## Self-host

Two ways to run the data plane. Do not run both writers against the same `config.yaml`. `fizz-config watch` and `fizz-agent` would overwrite each other.

**Standalone.** Hand-edit `config.yaml`, or let `fizz-config` render it from a Postgres you operate. The compose file above is this mode. `fizz-guard` reads policies, pins, approvals, and client-token revocation from that database on each call. `DATABASE_URL=memory://` keeps those rows in the process and drops them on exit. Nothing in standalone calls the Fizzlayer API.

**Linked.** `fizz-agent` sits next to agentgateway and `fizz-guard`. It needs the control-plane origin and a registration token (`fizz_reg_…`, shown once when the gateway is created or rotated):

| Variable | Purpose |
|---|---|
| `FIZZ_API_URL` | Origin only, such as `https://fizzlayer.com`. No path, user, or password. |
| `FIZZ_REGISTRATION_TOKEN_FILE` | File containing the token. Preferred. Mode `0600`. |
| `FIZZ_REGISTRATION_TOKEN` | The token itself, if you are not using the file. |
| `FIZZ_CONFIG_OUT` | File agentgateway was started with (`-f`). Default `/config/config.yaml`. |
| `FIZZ_POLL_SECS` | Delay between pulls. Default 5. Range 1–300. |
| `FIZZ_ADMIN_URL` | Optional origin of the proxy admin listener, such as `http://127.0.0.1:15000`. |
| `FIZZ_AGENT_STATE` | Optional file for the last ETag. Default is `.fizz-agent-state` beside the config. |

```sh
export FIZZ_API_URL=https://fizzlayer.com
export FIZZ_REGISTRATION_TOKEN_FILE=/run/secrets/fizz-registration
fizz-agent pull
```

The agent sends `Authorization: Bearer`, `If-None-Match`, and `?rev=`. `304` leaves the file alone. A `200` is checked before the atomic rename: it has to be YAML with an `mcp` listener and one target kind per server. A document that fails that check is not written. The last good file keeps being served, and the agent `POST`s `/api/gateway/agent/status` with `rejected` and a short reason. That reason does not include the token or the YAML. Network errors, `401`, and `5xx` also leave the file in place and back off up to 60 seconds. A bad document does not back off as a network failure, so a corrected revision is picked up on the next poll.

agentgateway v1.7.0 watches that file (`LocalClient::watch_config_file` at the pinned commit) and hot-reloads targets and policies. A reload it rejects stays on the previous in-memory config; `GET /api/runtime` on the admin listener reports `configReload.synchronized: false`. There is no separate reload RPC. When `FIZZ_ADMIN_URL` answers, `fizz-agent` reads that flag and, if the reload was rejected, puts the previous file back so a restart does not boot the bad document. The rendered config binds admin to `127.0.0.1:15000` inside the proxy container and does not publish it. Leave `FIZZ_ADMIN_URL` unset unless that listener is reachable from the agent without exposing it on the host.

`fizz-guard` does not take policies from `fizz-agent`. The YAML only points `mcpGuardrails` at the guard. Allow, deny, approve, tool pins, approval rows, and client-token revocation are read from Postgres on each call (`gateway.policies` and the tables next to it). A policy change is visible on the next `tools/call` without a config reload, as long as `fizz-guard` uses the same database the control plane writes. Linked mode does not sync those rows over the registration token. Point `DATABASE_URL` at that database, or keep using a local database and edit policies there. `DATABASE_URL=memory://` does not follow the cloud rows.

Upstream API keys are embedded only in the registration-token YAML, as `backendAuth.key.value`. They land in `config.yaml` because agentgateway needs them. Do not log that file. The agent does not.

`20261118000100_gateway_agent.sql` stores the agent's last report on `gateway.gateways` (`agent_status`, `agent_revision`, `agent_detail`). Apply it with the other gateway migrations (`supabase db push`). Until then the status `POST` fails and the agent still keeps the last good file. Pulling config itself is the earlier `20261114000400` migration.

The linked compose test uses a mock control plane on the Docker network. It does not print the token.

```sh
gateway/compose/test-linked.sh
```

That stack adds a server through the mock, checks the new tool shows up without restarting agentgateway, then serves a bad document and checks the previous `ping` call still succeeds.

## Database

`supabase/migrations/20261114000000_gateway.sql` adds the `gateway` schema: workspaces (one per customer account), gateways, servers, secrets, policies, tool pins, client tokens, approvals, audit, and daily usage. `supabase/migrations/20261114000300_gateway_policies.sql` adds pin status, pin alerts, the approval preview, and the shared phone-call budget function. Row level security ties rows to `fizz_customers.auth_user_id`. `gateway.secrets` has no authenticated policy. Table privileges for `authenticated` stay revoked, same as the other server tables; the SQL test grants them inside a transaction that rolls back.

`20261114000400` is the control-plane API. `20261118000000` places phone approvals and is loaded by local compose. `20261118000100` stores the fizz-agent report. Local compose does not apply `004` or `00100`. Applying the gateway migrations to the hosted project is `supabase db push`. This directory does not do that.

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
| `phone` | Calls `gateway.reserve_phone_approval_call`, which takes the shared monthly cap under an account lock, and returns. It does not dial. Hobbyist is 0 calls, Tinkerer 20, Pro 100, shared with sensor phone alerts for the UTC month. Enterprise is unlimited unless `fizz_subscriptions.monthly_call_cap` is set. A full cap, a missing paired number, or billing that cannot be read is recorded as `skipped` and does not count. fizz-guard then falls back to the approval webhook, or a log line. Only `reserved` counts. `/api/cron` dials queued rows with the AgentPhone client in `src/notify.rs`. |

The dial uses the same AgentPhone path as sensor alerts (`AGENTPHONE_API_KEY` and `AGENTPHONE_AGENT_ID`). No new variable is required. The call goes to the account's most recently paired number, and only that number. AgentPhone's create-call API cannot collect a callee keypress (`digits` sends tones). The greeting names the gateway, tool, argument summary, and approval id, then tells the owner to approve or deny in the app. `gateway.apply_phone_keypress` still sets `gateway.approvals` the same way the API decision does when digit 1 (approve) or 2 (deny) is supplied. fizz-guard spends at most 2 seconds on the reserve and does not wait for the dial.

Self-host compose uses Postgres, the same as the local test. `DATABASE_URL=memory://` keeps pins and approvals in memory and drops them when the process exits. That store has no billing tables, so a phone approval is always `billing_unreachable`. SQLite is not wired.

Set `FIZZ_GUARD_ADMIN_TOKEN` to open the local API on `FIZZ_GUARD_ADMIN_LISTEN` (default `127.0.0.1:9002`):

- `GET /approvals` and `POST /approvals/decision` with `{"id","status":"approved"|"denied"}`
- `GET /alerts` and `POST /alerts/approve` with `{"gateway_id","server","tool"}`
- `GET /` is the same actions as a page

Send `Authorization: Bearer <token>`. Without the token, the admin listener stays off and approvals can still be updated in SQL by the owning user. The token can decide every pending row in that database. Do not publish port 9002 on a shared gateway.

`usage_daily` counts calls the guard sees. Metering caps and upstream OAuth are not implemented. `failureMode` stays `failClosed`: if fizz-guard is down, or this process returns an error, agentgateway denies the call.

## Control plane

The Rust API on Vercel exposes the control plane under `/api/gateway/*`. It does not change `/api/mcp`, `/install.sh`, Home Assistant, or `/.well-known/*`. A signed-in caller sends a Supabase access token as `Authorization: Bearer`, or in the existing `fizz_supabase` cookie. The account's workspace is created on first use. The account owner is `owner`. `owner` and `admin` can change a gateway; a `member` can read it and gets `403 forbidden` on writes. Another workspace gets `404`, the same as a missing gateway.

| Method | Path | What it does |
|---|---|---|
| GET | `/api/gateway/jwks` | Public JWKS for `jwtAuth`. No session. |
| GET | `/api/gateway/agent/config` | YAML for the gateway agent. `Authorization: Bearer fizz_reg_…`. `ETag` is the config revision. `If-None-Match` or `?rev=` returns `304`. |
| GET, POST | `/api/gateway/gateways` | List, or create. The create response includes `registration_token` once. |
| DELETE | `/api/gateway/gateways/{id}` | Delete the gateway and its servers, secrets, and tokens. |
| PATCH | `/api/gateway/gateways/{id}` | Set `unreviewed_tools` to `hide` or `show` on `gateway.gateways`. |
| GET, POST | `/api/gateway/gateways/{id}/servers` | List servers, or add one. `url` is http(s). `api_key` is stored encrypted and is never returned. `transport: stdio` with `command` and `args` is only for a dedicated or self-hosted gateway on a plan that includes stdio. |
| DELETE | `/api/gateway/gateways/{id}/servers/{server_id}` | Remove a server. |
| GET, PUT | `/api/gateway/gateways/{id}/policies` | List rules, or upsert one: `server_id` (optional), `tool_name` (`*` or one tool), `effect` (`allow`, `deny`, `approve`), and optional `notify_channel` (`log`, `webhook`, `phone`). |
| DELETE | `/api/gateway/gateways/{id}/policies/{policy_id}` | Remove a rule. |
| GET | `/api/gateway/gateways/{id}/pins` | List `gateway.tool_pins` for this gateway. |
| POST | `/api/gateway/gateways/{id}/pins/approve` | Approve the observed hash for `{"server","tool"}`. Same transition fizz-guard uses: `pin_sha256` becomes `observed_sha256`, status `approved`, and open pin alerts for that tool are acknowledged. |
| GET | `/api/gateway/gateways/{id}/pin-alerts` | List `gateway.pin_alerts`. `description_preview` is untrusted text from the MCP server. |
| POST | `/api/gateway/gateways/{id}/pin-alerts/{alert_id}/ack` | Set `acknowledged_at`. |
| GET | `/api/gateway/gateways/{id}/approvals` | List `gateway.approvals`. `args_preview` is key names only. |
| POST | `/api/gateway/gateways/{id}/approvals/{approval_id}/decision` | `{"status":"approved"|"denied"}` on a pending row that has not expired. |
| GET | `/api/gateway/gateways/{id}/config` | YAML preview. Credentials are omitted. `ETag` ends in `-redacted`. |
| GET, POST | `/api/gateway/gateways/{id}/tokens` | List client tokens, or mint one. The JWT is returned once. Default life is 1 hour; `ttl_seconds` can be up to 30 days. |
| DELETE | `/api/gateway/gateways/{id}/tokens/{token_id}` | Revoke a client token. `fizz-guard` reads `revoked_at`; this does not by itself reload the YAML. |
| POST | `/api/gateway/gateways/{id}/registration-token` | Rotate the agent token. The new value is returned once. |
| POST | `/api/gateway/agent/status` | `fizz-agent` report. `Authorization: Bearer fizz_reg_…`. Body is `revision`, `status` (`applied` or `rejected`), and an optional `detail` of at most 300 characters. The detail is rejected if it contains the token, a JWT, or `Bearer`. |

Creating a gateway without `mode` uses `shared` on Hobbyist and Tinkerer, and `dedicated` on Pro and Enterprise. `dedicated` is only a row: nothing is provisioned. The default URL is `https://gw.fizzlayer.com/w/{id}/mcp` or `https://{name}.gw.fizzlayer.com/mcp`. Self-host requires `public_url`.

Plan limits (platform plan §B4) are on `fizz_plans` and are returned by `GET /api/gateway/gateways` as `plan`. Over the cap, the API answers `402` with `gateway_limit`, `server_limit`, `stdio_not_included`, or `dedicated_not_included`. A downgrade disables the newest extra gateways and servers; it does not delete them. Phone-call approvals share the monthly cap already enforced by `gateway.phone_approval_budget`. This API does not place a call and does not reserve one. Client-token revocation is enforced by `fizz-guard` from `gateway.client_tokens`, not by the YAML file.

### Policy rows

`PUT /api/gateway/gateways/{id}/policies` writes the columns `fizz-guard` reads from `gateway.policies`:

| Column | Meaning |
|---|---|
| `gateway_id` | The gateway. |
| `server_id` | One server, or null for every server on that gateway. |
| `tool_name` | `*` or a tool name matching `^[A-Za-z0-9_.:-]{1,128}$`. |
| `effect` | `allow`, `deny`, or `approve`. |
| `notify_channel` | `log`, `webhook`, or `phone`. Omitted on an update keeps the current value. A new row defaults to `log`. |

Uniqueness is `(gateway_id, coalesce(server_id, zero uuid), tool_name)`. A missing rule denies the call. Pin approval writes `gateway.tool_pins` (`pin_sha256`, `observed_sha256`, `status`, `approved_at`) and acknowledges matching `gateway.pin_alerts`. Approval decisions write `gateway.approvals.status` and `decided_by` only while the row is `pending` and unexpired. `20261114000400_gateway_control_plane.sql` does not create those tables; `20261114000300_gateway_policies.sql` does.

The rendered YAML does not copy those rules. It points `mcpGuardrails` at `fizz-guard`, which reads the tables. The agent pull is the copy that may contain `backendAuth.key.value`. The signed-in preview never does. Local `fizz-config` still refuses to write a credential.

### Environment

Set these on the Vercel project `fizz`. Do not commit the values.

| Variable | Required | Purpose |
|---|---|---|
| `GATEWAY_SIGNING_KEY` | To mint tokens and serve JWKS | PKCS#8 PEM for the ES256 key. A single-line value may use `\n` for line breaks. The server does not generate one. |
| `GATEWAY_SECRET_KEY` | To store an MCP API key or PAT | Base64 of 32 bytes. Ciphertext is AES-256-GCM, `key_id` `v1`. |
| `GATEWAY_JWKS_URL` | Recommended in production | Absolute URL of `GET /api/gateway/jwks`, written into the YAML as `jwtAuth.jwks.url`. If unset, the request origin plus `/api/gateway/jwks` is used. |
| `GATEWAY_GUARD_HOST` | Optional | `host:port` of `fizz-guard` in the YAML. Default `fizz-guard:9001`. |

`20261114000400_gateway_control_plane.sql` has to be applied (`supabase db push`) before these routes can succeed. Until then they answer `503`. `20261118000100_gateway_agent.sql` adds the columns for `POST /api/gateway/agent/status`. Apply that too. It does not change phone approvals.

```sh
cargo test --locked --lib gateway::
```
