# Self-host Fizzlayer

Run your own Fizzlayer instance with your own Vercel project and Supabase project. Vercel serves the web app and Rust API; Supabase provides PostgreSQL, Auth, and storage. Devices and agents connect to your instance's HTTPS origin.

This is the deployment path supported by the repository today. It does not include a standalone application server or a Docker Compose stack for running the entire product on a VPS. HTTPS ingest, the dashboard, and MCP work without the Compute worker. Live sockets and MQTT need the `fizz-worker` service described below. See the [technical reference](REFERENCE.md) for API and authentication details.

## Prerequisites

- A checkout or fork of this repository.
- A current stable Rust toolchain supporting edition 2024.
- The [Vercel CLI](https://vercel.com/docs/cli) and a Vercel account.
- The [Supabase CLI](https://supabase.com/docs/guides/local-development/cli/getting-started) and a Supabase project you control. The repository's local database configuration uses PostgreSQL 17.
- An HTTPS domain for production and an SMTP provider for account confirmation and password recovery.

Commands below run from the repository root. Replace example domains and project references with your own.

## 1. Create the database

Create a Supabase project, then authenticate and link this checkout to it:

```sh
supabase login
supabase link --project-ref YOUR_PROJECT_REF
supabase db push --linked
```

Apply all files in `supabase/migrations/` in their recorded order. They contain the schema, server RPCs, sign-up flow, storage configuration, ownership policies, and security changes. SQL migrations do not configure SMTP, OAuth providers, or all Auth dashboard settings.

> **Upgrading an invite-only instance:** `20261105000000_open_sign_up.sql` removes the invite requirement. Apply the migration first, then deploy the matching code: the new code calls functions the migration adds, so deploying it first breaks sign-in. The old code keeps working, and keeps requiring invites, until the new code is live, because the invite functions stay until a later cleanup migration. Once the new code is deployed, anyone who can reach your deployment can create an account, including people who already have a Supabase Auth user from an earlier sign-in that was turned away. To stay private, run `update public.fizz_instance_settings set sign_up_open = false;` after applying the migration and before deploying the code.

Use a separate Supabase project for development or staging. Preview deployments pointing at the production database can write production data. Review migrations and backups before updating an existing instance; do not use `db reset` against production.

## 2. Configure Supabase Auth

For an instance at `https://sensors.example.com`, configure the following in the Supabase dashboard:

| Setting | Value |
| --- | --- |
| Authentication → URL Configuration → Site URL | `https://sensors.example.com` |
| Redirect URLs | `https://sensors.example.com/api/auth` and `https://sensors.example.com/app.html` |
| Email provider | Enable sign-ups and email confirmation |
| SMTP | Your sender credentials and verified sender address |
| Minimum password length | 12 characters |
| Secure password change | Enabled |
| Anonymous sign-ins | Disabled |

Configure an email rate limit appropriate to your expected traffic. Supabase's built-in sender is limited and is not a production email service. Enable breached-password protection if available for your project.

**Google sign-in (optional).** Create a Google Cloud OAuth client of type **Web application**. Set its authorized redirect URI to `https://YOUR_PROJECT_REF.supabase.co/auth/v1/callback`, then enable Google in Supabase Auth with the client ID and secret. These credentials belong in Supabase, not in the browser or Vercel environment.

**GitHub sign-in (optional).** Create a GitHub OAuth App (GitHub → Settings → Developer settings → OAuth Apps). Set its authorization callback URL to `https://YOUR_PROJECT_REF.supabase.co/auth/v1/callback`, then enable GitHub in Supabase Auth with the client ID and secret. Like Google's, these credentials belong only in Supabase.

**Passkeys (optional).** Enable passkeys and set the relying party ID to `sensors.example.com`, allowed origin to `https://sensors.example.com`, and display name to `Fizzlayer`. Customers register passkeys from Settings after signing in. Choose the domain before enrollment: changing the relying party ID invalidates existing passkeys. A passkey for your production domain does not work on unrelated preview domains.

The app does not provide a TOTP/MFA challenge flow. Do not enable an enrollment flow that users cannot complete through this UI.

For local development, also allow `http://localhost:3000/api/auth` and `http://localhost:3000/app.html`. Use a separate development Auth configuration for localhost passkeys.

The narrow [production security profile](../supabase/config.production-security.toml) records additional settings to review, including database SSL enforcement. It is not a complete instance configuration. Do not push the full `supabase/config.toml` to production: it contains local URLs and development settings.

## 3. Configure Vercel

Import your repository into a new Vercel project, or run `vercel link` and select your own project. Use:

| Project setting | Value |
| --- | --- |
| Framework preset | Other |
| Root directory | Repository root |
| Build command | Leave unset |
| Output directory | Leave unset |

The `api/*.rs` entry points use Vercel's Rust runtime, and `public/` contains static assets. `cargo check` checks compilation; it does not start an HTTP server.

Add these server-side environment variables to each environment you use:

| Variable | Required | Purpose |
| --- | --- | --- |
| `SUPABASE_URL` | Yes | Your Supabase project URL, such as `https://YOUR_PROJECT_REF.supabase.co` |
| `SUPABASE_SERVICE_ROLE_KEY` | Yes | Your project's service-role credential |
| `AI_GATEWAY_API_KEY` | For chat | Vercel AI Gateway credential; the API also supports Vercel's injected `VERCEL_OIDC_TOKEN` when an API key is absent |
| `AI_GATEWAY_MODEL` | No | Gateway model ID; defaults to `openai/gpt-5-mini` |
| `ELEVENLABS_API_KEY` | For voice chat | Speech-to-text and text-to-speech credential |
| `ELEVENLABS_VOICE_ID` | No | Voice ID; defaults to George (`JBFqnCBsd6RMkjVDRZzb`) |
| `AGENTPHONE_API_KEY` | For alert calls | AgentPhone credential |
| `AGENTPHONE_AGENT_ID` | Sometimes | Required when the AgentPhone account has multiple agents; a sole agent is selected automatically |
| `CRON_SECRET` | For silence alerts and call retries | Long random secret. Vercel Cron sends it as `Authorization: Bearer <CRON_SECRET>` on `GET /api/cron`. Use the same value if an external scheduler calls that path |
| `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `STRIPE_PRICE_TINKERER`, `STRIPE_PRICE_PRO` | For paid plans | Stripe billing; set all four or none. See [billing with Stripe](REFERENCE.md#billing-with-stripe) |
| `FIZZ_STREAM_URL` | For live sockets and MQTT | Public base URL of the `fizz-worker` Compute service, including any gateway path. Example: `https://YOUR_PROJECT_REF.supabase.co/workers/v1/fizz-worker`. Empty leaves streaming off; HTTPS ingest is unchanged |
| `FIZZ_MQTT_TCP_URL` | No | Advertised plain MQTT URL, such as `mqtt://mqtt.example.com:1883`, when that port is actually reachable. Leave unset on the Compute public URL |

Keep credentials in Vercel's environment settings. The service-role key bypasses database RLS and must never appear in `public/`, client JavaScript, or committed files. No browser Supabase key is required. Optional provider credentials can be omitted; ingestion and dashboard alerts work without chat, speech, or phone calls. Pairing calls and alert calls use the same `AGENTPHONE_API_KEY` and `AGENTPHONE_AGENT_ID`. No new variable is required. Hobbyist accounts are not able to place either call.

AgentPhone requires an agent with an attached voice-enabled number. Calls use its first attached number. Configure provider spending limits before enabling paid features. Set call credentials only in environments that should dispatch notifications: setting a key in a preview also enables sending there.

### Use your own domain

Attach your domain to the Vercel project and configure DNS as directed by Vercel. Enable automatic exposure of Vercel system environment variables. The request guard in [`src/security.rs`](../src/security.rs) accepts the exact hosts supplied by `VERCEL_URL`, `VERCEL_BRANCH_URL`, and `VERCEL_PROJECT_PRODUCTION_URL`, plus localhost and the original hosted service's domains.

Make your intended domain the project's production domain and confirm it is the value of `VERCEL_PROJECT_PRODUCTION_URL`. Additional custom aliases are not automatically allowed: either redirect them to that canonical domain at Vercel, or explicitly extend the host allowlist in your fork. Do not remove the host or origin checks. There is no `SITE_URL` environment setting in this app.

Remove or replace the original `fizz-zeta.vercel.app` → `fizzlayer.com` redirect in [`vercel.json`](../vercel.json). Keep the security headers. Review hosted-service URLs in landing-page metadata, installer examples, and support links before publishing your fork; those are not rewritten by an environment variable.

### Page analytics (optional)

Every page loads [`public/analytics.js`](../public/analytics.js), which sends cookieless page views to Vercel Web Analytics with query strings and fragments removed. To collect them, open **Analytics** for the project in the Vercel dashboard, choose **Enable**, and redeploy; until then the script's request returns 404 and nothing is recorded. It never loads on localhost. If you don't want analytics, remove the script tag from the pages and the page-view item from the privacy policy.

## 4. Deploy and create your first account

Run the source checks, then deploy to your linked project:

```sh
cargo test --locked --all-targets
cargo test --locked --manifest-path cli/Cargo.toml
vercel deploy --prod
```

For subsequent releases, test against a separate staging database before deploying production. Environment changes require a new deployment to take effect.

Check the API:

```sh
curl --fail https://sensors.example.com/api/status
```

Expect `"status":"ok"` and `"database":"connected"`. A database failure still returns a JSON response with HTTP 200, so monitoring must inspect those fields. `unconfigured` means the Supabase variables are missing; `unavailable` means configuration or the connection failed. `invalid_host` means the request host was not allowed by the configuration described above.

Anyone who can reach your deployment can create an account. Open `https://sensors.example.com/app.html`, create an account, confirm the email, and complete onboarding. New sign-ups are limited to 10 an hour per network. To keep a private instance closed after creating your own accounts, run `update public.fizz_instance_settings set sign_up_open = false;` in the Supabase SQL editor; existing accounts can still sign in. This also covers Supabase Auth users that have no Fizzlayer account yet, which turning off **Allow new users to sign up** in Supabase Auth settings does not.

## 5. Connect devices and agents

Install the CLI using the [CLI guide](CLI.md), then pair against your instance:

```sh
FIZZ_API=https://sensors.example.com fizz pair
fizz run --once
```

The CLI saves the paired API origin with the device credentials. Claim the displayed code on your instance's Sensors or Agents page, then approve it on the device. `FIZZ_API` can override the saved origin; do not accidentally point a paired device at another instance.

For MCP clients, use `https://sensors.example.com/api/mcp` and a token created on your Agents page. Sensor HTTP clients use `https://sensors.example.com/api/ingest` with their sensor-scoped key. Phone links generated by your instance use its request origin.

## Local development

The simplest development setup uses a separate hosted Supabase project with the same migrations. Link your development Vercel project, configure its Development environment, then run:

```sh
scripts/dev.sh
```

The script links the directory to a Vercel project if needed, runs `cargo check --locked`, then starts `FIZZ_DEV_ORIGIN=http://localhost:3000 vercel dev`. `vercel dev` reads the linked project's Development variables. Alternatively, create `.env.local` yourself with `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` for your development database. This file is ignored by Git. Add optional provider credentials only when testing those features. Open `http://localhost:3000` and check `/api/status`. Use this hostname consistently. `FIZZ_DEV_ORIGIN` sets the browser-facing loopback origin during `vercel dev`, whose proxy can otherwise expose an internal function port in OAuth callbacks. It is ignored outside Vercel development and accepts only HTTP loopback origins.

For a local Supabase database, install Docker and run:

```sh
scripts/dev.sh --local-db
```

This starts Supabase with `supabase start` if it is not already running, then writes a temporary `.env` with the local URL and service-role key. `vercel dev` uses that file instead of the project's cloud variables. The script removes the file when it exits and refuses to overwrite a `.env` it did not create. Because that file replaces the project's cloud variables, the script copies any `STRIPE_*` variables from your shell into it; see [billing with Stripe](REFERENCE.md#billing-with-stripe) for testing checkout locally. Startup applies the migrations to a fresh local database; use `supabase migration up --local` for subsequent migrations. Create an account at the app URL; Studio is at `http://127.0.0.1:54323`. Confirmation emails arrive in the local inbox at `http://127.0.0.1:54324`. Supabase keeps running after the script exits; stop it with `supabase stop`.

The local `supabase/config.toml` disables Google and GitHub sign-in and seeding, and uses `http://localhost:3000` for Auth redirects. To test Google sign-in locally, set `SUPABASE_AUTH_EXTERNAL_GOOGLE_CLIENT_ID` and `SUPABASE_AUTH_EXTERNAL_GOOGLE_SECRET`, then enable `[auth.external.google]`. GitHub works the same way with `SUPABASE_AUTH_EXTERNAL_GITHUB_CLIENT_ID`, `SUPABASE_AUTH_EXTERNAL_GITHUB_SECRET`, and `[auth.external.github]`, using a separate GitHub OAuth App whose callback URL is `http://127.0.0.1:54321/auth/v1/callback`. The app accepts HTTP Supabase URLs only on loopback. Production Supabase connections require HTTPS.

## Verify and operate

Before opening access, exercise one complete flow: sign-up and confirmation, sign-in and recovery, sensor creation, one ingested reading, a threshold alert, CLI pairing and revocation, and a read through MCP. Test enabled Google/GitHub/passkey, speech, and call integrations separately with accounts and numbers you control.

The database regression suites use transactions and roll back their fixtures. Run linked commands sequentially because they share a temporary database login:

```sh
supabase db query --linked --file supabase/tests/authenticated_owner_rls.sql
supabase db query --linked --file supabase/tests/security_hardening.sql
supabase db query --linked --file supabase/tests/plan_limits.sql
supabase db query --linked --file supabase/tests/billing.sql
supabase db query --linked --file supabase/tests/silence_alerts.sql
supabase db query --linked --file supabase/tests/verified_phones.sql
supabase db query --linked --file supabase/tests/homeassistant.sql
```

New accounts start on the Hobbyist plan: 3 connected devices and 10 Fizz chat messages a month. To remove the limits on your own instance, set them to `NULL`:

```sql
update public.fizz_plans set device_limit = null, monthly_credits = null where id = 'hobbyist';
```

The [plans reference](REFERENCE.md#plans-and-limits) covers how limits are enforced and how to move one account to another plan.

Use a recent Supabase CLI with `db query` support; the repository's security audit records version 2.120.0. See the [security audit](SECURITY_AUDIT.md) for test coverage and remaining limitations. Its recorded results describe the original instance at the time of that audit, not your new deployment.

- Monitor Vercel function errors, the status response, Supabase storage/database growth, and provider usage. Configure backups and test restoration for your own instance.
- Sample sensors advance on authenticated dashboard/Sensors reads, at most once every 15 seconds per sensor. They are not a scheduled background stream.
- Numeric readings evaluate threshold alerts in the database. A silence alert fires when a sensor has sent no reading for the rule's window (default 10 minutes, minimum 1). `GET /api/cron`, authorized with `CRON_SECRET`, scans for silence and sends queued calls, including retries, for up to about 36 seconds. The request that stored a reading still sends up to three queued calls, and the claim is locked so the two paths cannot double-call. A blank `CRON_SECRET` is treated as unset. Ambiguous provider outcomes stop for review.
- `vercel.json` registers a `* * * * *` cron for `/api/cron` and gives `api/cron.rs` a `maxDuration` of 60 seconds. That needs Vercel Pro: an every-minute schedule is rejected on the Hobby plan and fails the deployment. On Hobby, remove the `crons` entry from `vercel.json`. Then, on Hobby or on any host without Vercel Cron, run the same request yourself once a minute: `curl -fsS -H "Authorization: Bearer $CRON_SECRET" https://sensors.example.com/api/cron`. Apply `supabase/migrations/20261104000000_silence_alerts.sql` before relying on the route. That migration builds an index on `fizz_sensor_readings (sensor_id, received_at desc)` inside the migration transaction, which locks reading writes until the build finishes. On a large table, create that index with `CREATE INDEX CONCURRENTLY` before `db push`; the migration then finds the index already present.
- An MCP token can attach a phone number to an alert only when that number is already saved on an active alert in the workspace. The owner adds the number from the dashboard or by asking Fizz.
- Phone notifications currently support US voice calls. SMS and physical actuator control are not implemented.
- Phone sensor collection requires an open browser page and device permissions. HTTPS is required for production browser sensor and microphone features.
- Fizz sessions last 12 hours. Device, agent, and session credentials are stored as hashes; protect the CLI's local credential file and rotate/revoke credentials from the app when needed.
- The `fizz-worker` Compute service is the live socket and MQTT listener. Deploying it is a separate step from `db push` and from the Vercel deploy. Until `FIZZ_STREAM_URL` is set, `GET /api/stream` returns `{"enabled": false}` and devices keep using HTTPS. See [Live stream and MQTT](#live-stream-and-mqtt).
- `supabase/migrations/20261111000000_live_stream.sql` adds `fizz_stream_tokens` and an index on `fizz_sensor_readings (received_at, id)`. The index build locks reading writes until it finishes. On a large table, create that index with `CREATE INDEX CONCURRENTLY` before `db push`.

When updating, review and apply new database migrations before releasing API changes that require them. An application rollback does not roll back database migrations; plan schema compatibility and recovery separately.

## Live stream and MQTT

Vercel functions cannot hold a WebSocket or an MQTT session. Supabase Compute, in private alpha as of the 27 October 2026 announcement, runs a long-lived HTTP service in the same project as Postgres. Fizzlayer uses that for `fizz-worker`. The worker is public (`exposure = "public"` in `supabase/config.toml`) because a private service has no URL. It accepts device WebSockets at `/v1/stream`, subscriber WebSockets at `/v1/live`, and MQTT 3.1.1 over WebSocket at `/mqtt`. Every accepted reading is `fizz_ingest_event`, the same function as `POST /api/ingest`, so alerts, silence detection, Fizz, and MCP do not grow a second store. The worker then polls `fizz_live_since` and forwards new rows only to subscribers whose workspace owns them.

Checked against Supabase's announcement and product page, not against a production deploy:

| | |
| --- | --- |
| CLI | 2.120.0 or later. `compute = true` is already under `[experimental]` |
| Sizes | 2 GB / 1 vCPU (`2gb`, what this repo sets) or 4 GB / 2 vCPU |
| Region | us-west-2 only during the alpha. Confirm project `Fizz` (`bbmdkpzzzalkvthwgsek`) is in that region before pushing |
| Price | The alpha is free and is for evaluation, not production. It may change or end. No general price has been published for this service. That is separate from Postgres [compute hours](https://supabase.com/docs/guides/platform/manage-your-usage/compute), which bill the database instance |
| Lifetime | No wall-clock limit of the kind Edge Functions have (400 seconds). A service can still be restarted at any time, so readings live in Postgres |
| Idle | A public service suspends when idle and is described as resuming in under a second. Open sockets keep it awake; clients reconnect after a suspend |
| Missing | No autoscaling, GPU, or persistent disk. Agent sandboxes are not in the alpha. Every service receives all of the project's secrets |
| URL | Dashboard snippets use `https://<project-ref>.supabase.co/workers/v1/<name>`. Read the URL on the Compute page after the first push and do not guess if it differs |

The public URL is HTTP. It does not publish TCP port 1883. MQTT clients on that URL use WebSocket (`wss://.../mqtt`, subprotocol `mqtt`). ESP-IDF can do that with `MQTT_TRANSPORT_OVER_WSS`. Home Assistant's MQTT integration and Arduino `PubSubClient` speak TCP. For those, run this same image somewhere you can publish port 1883 (`MQTT_TCP_PORT=1883`) or wait until Compute exposes extra ports. Set `FIZZ_MQTT_TCP_URL` only when that address is reachable.

### Deploy the worker

Do this in the Supabase project you mean to use. Nothing in this repository deploys it for you.

1. Apply `supabase/migrations/20261111000000_live_stream.sql` with the other migrations (`supabase db push`).
2. Confirm the project is in us-west-2 and that Compute is enabled for it. The alpha is waitlisted.
3. Put `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` in the project's secrets. Compute injects project secrets into the service. The worker will not store readings without them. Add `FIZZ_STREAM_ORIGINS` only if the browser origin is not `https://fizzlayer.com` or `https://www.fizzlayer.com` (comma-separated). Loopback origins are always allowed.
4. From the repo root, with Supabase CLI 2.120.0 or later:

   ```sh
   supabase compute push --project-ref YOUR_PROJECT_REF
   ```

   The image is `supabase/compute/fizz-worker`. It listens on `PORT` (the platform sets this; locally it defaults to 8080). `GET /health` returns `{"service":"fizz-worker","status":"ok"}`.
5. Copy the public URL from the Compute page. On Vercel, set `FIZZ_STREAM_URL` to that base, for example `https://YOUR_PROJECT_REF.supabase.co/workers/v1/fizz-worker`, with no trailing slash. Redeploy the API. `GET /api/stream` should then return `"enabled": true`.
6. The site's Content-Security-Policy allows `https://*.supabase.co` and `wss://*.supabase.co`. If the public URL is on another host, add that host to `connect-src` in `vercel.json`.

A streamed reading still creates alert rows in the database. The worker does not dial AgentPhone. `/api/cron` places queued calls, so a call that follows a socket or MQTT reading can wait until the next cron run instead of leaving on the ingest request itself.

Locally, without Compute:

```sh
SUPABASE_URL=http://127.0.0.1:54321 SUPABASE_SERVICE_ROLE_KEY=... \
  cargo run --manifest-path supabase/compute/fizz-worker/Cargo.toml
FIZZ_STREAM_URL=http://127.0.0.1:8080 scripts/dev.sh --local-db
```

`MQTT_TCP_PORT=1883` also opens a plain MQTT listener on that port. The image runs as uid 65532 and needs outbound HTTPS to the Supabase API.
