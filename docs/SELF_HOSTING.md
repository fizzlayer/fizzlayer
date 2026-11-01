# Self-host Fizzlayer

Run your own Fizzlayer instance with your own Vercel project and Supabase project. Vercel serves the web app and Rust API; Supabase provides PostgreSQL, Auth, and storage. Devices and agents connect to your instance's HTTPS origin.

This is the deployment path supported by the repository today. It does not include a standalone application server or a Docker Compose stack for running the entire product on a VPS. The optional private Supabase Compute worker is not required by the app; no Compute deployment is needed to apply the database migrations. See the [technical reference](REFERENCE.md) for API and authentication details.

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

Apply all files in `supabase/migrations/` in their recorded order. They contain the schema, server RPCs, invite flow, storage configuration, ownership policies, and security changes. SQL migrations do not configure SMTP, OAuth providers, or all Auth dashboard settings.

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
| `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `STRIPE_PRICE_TINKERER`, `STRIPE_PRICE_PRO` | For paid plans | Stripe billing; set all four or none. See [billing with Stripe](REFERENCE.md#billing-with-stripe) |

Keep credentials in Vercel's environment settings. The service-role key bypasses database RLS and must never appear in `public/`, client JavaScript, or committed files. No browser Supabase key is required. Optional provider credentials can be omitted; ingestion and dashboard alerts work without chat, speech, or phone calls.

AgentPhone requires an agent with an attached voice-enabled number. Calls use its first attached number. Configure provider spending limits before enabling paid features. Set call credentials only in environments that should dispatch notifications: setting a key in a preview also enables sending there.

### Use your own domain

Attach your domain to the Vercel project and configure DNS as directed by Vercel. Enable automatic exposure of Vercel system environment variables. The request guard in [`src/security.rs`](../src/security.rs) accepts the exact hosts supplied by `VERCEL_URL`, `VERCEL_BRANCH_URL`, and `VERCEL_PROJECT_PRODUCTION_URL`, plus localhost and the original hosted service's domains.

Make your intended domain the project's production domain and confirm it is the value of `VERCEL_PROJECT_PRODUCTION_URL`. Additional custom aliases are not automatically allowed: either redirect them to that canonical domain at Vercel, or explicitly extend the host allowlist in your fork. Do not remove the host or origin checks. There is no `SITE_URL` environment setting in this app.

Remove or replace the original `fizz-zeta.vercel.app` → `fizzlayer.com` redirect in [`vercel.json`](../vercel.json). Keep the security headers. Review hosted-service URLs in landing-page metadata, installer examples, and support links before publishing your fork; those are not rewritten by an environment variable.

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

Accounts require invitations. In your Supabase SQL editor, create your initial codes:

```sql
select * from public.fizz_create_invites(5, 'Initial users', interval '14 days');
```

Copy the returned codes when created: the database stores only their hashes. Open `https://sensors.example.com/app.html`, sign up with an invite, confirm the email, and complete onboarding. Invite codes are single-use and expire after the requested interval.

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

This starts Supabase with `supabase start` if it is not already running, then writes a temporary `.env` with the local URL and service-role key. `vercel dev` uses that file instead of the project's cloud variables. The script removes the file when it exits and refuses to overwrite a `.env` it did not create. Startup applies the migrations to a fresh local database; use `supabase migration up --local` for subsequent migrations. Create an invite in local Studio at `http://127.0.0.1:54323`. Confirmation emails arrive in the local inbox at `http://127.0.0.1:54324`. Supabase keeps running after the script exits; stop it with `supabase stop`.

The local `supabase/config.toml` disables Google sign-in and seeding, and uses `http://localhost:3000` for Auth redirects. To test Google sign-in locally, set `SUPABASE_AUTH_EXTERNAL_GOOGLE_CLIENT_ID` and `SUPABASE_AUTH_EXTERNAL_GOOGLE_SECRET`, then enable `[auth.external.google]`. The app accepts HTTP Supabase URLs only on loopback. Production Supabase connections require HTTPS.

## Verify and operate

Before opening access, exercise one complete flow: invite sign-up and confirmation, sign-in and recovery, sensor creation, one ingested reading, a threshold alert, CLI pairing and revocation, and a read through MCP. Test enabled Google/passkey, speech, and call integrations separately with accounts and numbers you control.

The database regression suites use transactions and roll back their fixtures. Run linked commands sequentially because they share a temporary database login:

```sh
supabase db query --linked --file supabase/tests/authenticated_owner_rls.sql
supabase db query --linked --file supabase/tests/security_hardening.sql
supabase db query --linked --file supabase/tests/plan_limits.sql
supabase db query --linked --file supabase/tests/billing.sql
```

New accounts start on the Hobbyist plan: 3 connected devices and 100 Fizz chat messages a month. To remove the limits on your own instance, set them to `NULL`:

```sql
update public.fizz_plans set device_limit = null, monthly_credits = null where id = 'hobbyist';
```

The [plans reference](REFERENCE.md#plans-and-limits) covers how limits are enforced and how to move one account to another plan.

Use a recent Supabase CLI with `db query` support; the repository's security audit records version 2.120.0. See the [security audit](SECURITY_AUDIT.md) for test coverage and remaining limitations. Its recorded results describe the original instance at the time of that audit, not your new deployment.

- Monitor Vercel function errors, the status response, Supabase storage/database growth, and provider usage. Configure backups and test restoration for your own instance.
- Sample sensors advance on authenticated dashboard/Sensors reads, at most once every 15 seconds per sensor. They are not a scheduled background stream.
- Numeric readings evaluate dashboard alerts in the database. Reading-writing API requests dispatch queued calls; there is no independent notification worker. Retries depend on subsequent requests, and ambiguous provider outcomes stop for review.
- Phone notifications currently support US voice calls. SMS and physical actuator control are not implemented.
- Phone sensor collection requires an open browser page and device permissions. HTTPS is required for production browser sensor and microphone features.
- Fizz sessions last 12 hours. Device, agent, and session credentials are stored as hashes; protect the CLI's local credential file and rotate/revoke credentials from the app when needed.
- The private `fizz-worker` Compute service is a health server reserved for future work. Deploying it does not add background alert processing or sample generation.

When updating, review and apply new database migrations before releasing API changes that require them. An application rollback does not roll back database migrations; plan schema compatibility and recovery separately.
