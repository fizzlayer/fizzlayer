# Fizzlayer

**The physical layer for AI agents.**

Connect sensors, phones, and Linux devices to your AI agents. Fizzlayer brings their readings into one dashboard so you can ask questions, watch changes, and set alerts. Fizz, the built-in assistant, helps you understand what your devices are reporting.

[Website](https://fizzlayer.com) · [Documentation](https://fizzlayer.com/docs.html) · [Interactive demo](https://fizzlayer.com/demo.html) · [Self-hosting](docs/SELF_HOSTING.md) · [CLI guide](docs/CLI.md)

## What you can do

- **See your devices in one place.** Stream real readings or explore the dashboard with sample sensors.
- **Connect the hardware you have.** Pair a Linux device with the CLI, share phone sensors from a browser, or send readings over HTTP.
- **Give agents access through MCP.** Issue revocable tokens to read sensor data and optionally create dashboard alerts.
- **Let a browser agent do it for you.** Every page exposes [WebMCP](docs/REFERENCE.md#webmcp-browser-agents) tools, so an agent pointed at the site can onboard, manage sensors and alerts, and start a plan checkout. Agents that read first can start at [`/llms.txt`](https://fizzlayer.com/llms.txt).
- **Ask Fizz about your readings.** Use typed chat or optional voice conversations to understand measurements and create threshold alerts.
- **Act on changes.** Track alerts in the dashboard and optionally receive voice calls to US phone numbers.

Fizzlayer includes a static web app, a Rust API deployed as Vercel Functions, a Supabase database and authentication layer, and a Rust device CLI. It monitors sensor data; physical actuator control is not implemented.

## Get started

Try the [interactive demo](https://fizzlayer.com/demo.html) without an account. It uses simulated sensors and local example replies to show the dashboard, alerts, and call previews.

[Create a free account](https://fizzlayer.com/app.html), start with sample data, then connect a device from the **Sensors** or **Agents** page. You can also [deploy your own instance](docs/SELF_HOSTING.md).

## Fizzlayer CLI

The command-line tool is named `fizz`. Install it on a Linux device, including a Raspberry Pi:

```sh
curl -fsSL https://fizzlayer.com/install.sh | sh
fizz pair
```

Enter the displayed pairing code on the **Sensors** or **Agents** page, or ask a connected agent to claim it. Approve the request at the device, then start streaming:

```sh
fizz run --every 60
```

The CLI reports CPU temperature, system load, memory usage, and disk usage where available. Send custom readings with:

```sh
fizz send temperature_c 22.4 humidity_pct 48
fizz status
```

For your own deployment, set its origin when pairing:

```sh
FIZZ_API=https://fizz.example.com fizz pair
```

The CLI remembers that origin. The [CLI guide](docs/CLI.md) covers supported architectures, source builds, configuration, systemd installation, and revoking a device.

## Self-hosting

Deploy Fizzlayer into your own **Vercel and Supabase accounts**. The current API uses the Vercel Functions runtime; this repository does not include a standalone server or Docker Compose deployment.

1. Clone the repository and install stable Rust, the Vercel CLI, and the Supabase CLI.
2. Create a Supabase project, link it, and apply the database migrations:

   ```sh
   git clone https://github.com/nisargap/Fizz.git
   cd Fizz
   supabase login
   supabase link --project-ref YOUR_PROJECT_REF
   supabase db push --linked
   ```

3. Import the repository into Vercel using the **Other** framework preset and the repository root. Set `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` as server-side environment variables.
4. Configure Supabase Auth, email delivery, and redirects for your deployment's domain. Deploy the app and verify that `/api/status` reports `database: "connected"`.
5. Open `/app.html` on your deployment and create your first account. Anyone who can reach the deployment can sign up; to close a private instance afterwards, turn off new sign-ups in Supabase Auth settings.

Every account is a customer account; there is no separate administrator role. Keep the service-role key on the server and out of browser assets.

Follow the [complete self-hosting guide](docs/SELF_HOSTING.md) for domain configuration, local development, email and optional Google/passkey setup, environment variables, and production checks. Chat, speech, outbound calls, and paid plans (Stripe) require their respective provider configuration; the core sensor and dashboard flows work independently.

## Connect an AI agent

Create a token on the **Agents** page and configure your MCP client to use your instance's `/api/mcp` endpoint. Tokens can read data and claim pairing requests that require approval at the device. You can optionally allow dashboard alert creation.

For Claude Code:

```sh
claude mcp add --transport http fizz https://fizzlayer.com/api/mcp \
  --header "Authorization: Bearer YOUR_AGENT_TOKEN"
```

A browser agent can also create the token itself with the `create_agent_connection` WebMCP tool; see [WebMCP](docs/REFERENCE.md#webmcp-browser-agents).

Replace the origin for a self-hosted instance. Supported tools include `list_sensors`, `get_readings`, `list_alerts`, `create_alert`, and `pair_device`. See the [agent connection reference](docs/REFERENCE.md#agent-connections-mcp) for protocol details and additional client configuration.

## Send readings over HTTP

Create an API sensor on the **Sensors** page and copy its sensor ID and key. For a Temperature sensor:

```sh
curl https://fizzlayer.com/api/ingest \
  -H 'Authorization: Bearer YOUR_SENSOR_API_KEY' \
  -H 'Content-Type: application/json' \
  -d '{"sensor_id":"YOUR_SENSOR_ID","event_id":"sample-001","metrics":{"temperature_c":27.4}}'
```

Use a new `event_id` for each sample; retrying the same ID is idempotent. Keys are scoped to a single sensor. This endpoint also supports microcontrollers that cannot run the CLI. See the [sensor API reference](docs/REFERENCE.md#sensor-api) for routes, phone pairing, and alert behavior.

## Development

After configuring your development Supabase project and local environment as described in the [self-hosting guide](docs/SELF_HOSTING.md):

```sh
scripts/dev.sh             # uses your linked Vercel project's Development variables
scripts/dev.sh --local-db  # or runs Supabase locally in Docker instead
```

The script checks that the API compiles, starts `vercel dev` at `http://localhost:3000`, and reports when `/api/status` shows a connected database. Run `scripts/dev.sh --help` for options.

To test paid plans locally, use Stripe test-mode keys and prices with the local database, and forward webhooks with the [Stripe CLI](https://docs.stripe.com/stripe-cli):

```sh
stripe listen --forward-to localhost:3000/api/stripe-webhook   # in one terminal

STRIPE_SECRET_KEY=sk_test_... STRIPE_WEBHOOK_SECRET=whsec_... \
STRIPE_PRICE_TINKERER=price_... STRIPE_PRICE_PRO=price_... \
scripts/dev.sh --local-db                                      # in another
```

`stripe listen --print-secret` prints the webhook secret. Sign up at `http://localhost:3000`, confirm the email in the local inbox (`http://127.0.0.1:54324`), then upgrade in **Settings** with the test card `4242 4242 4242 4242`. The script refuses live Stripe keys. See [billing with Stripe](docs/REFERENCE.md#billing-with-stripe) for details.

Run the Rust test suites:

```sh
cargo test --locked --all-targets
cargo test --locked --manifest-path cli/Cargo.toml
```

| Path | Contents |
| --- | --- |
| `public/` | Landing page, dashboard, phone pairing, and CLI installer |
| `api/` | Rust Vercel Function entry points |
| `src/` | Authentication, sensor ingestion, MCP, chat, and integrations |
| `cli/` | The `fizz` device CLI |
| `supabase/migrations/` | Database schema, access policies, and server functions |
| `supabase/tests/` | SQL checks for ownership and security protections |
| `hardware/` | Device firmware and hardware guides |
| `tools/demo/` | Dashboard walkthrough and recording tools |

## Documentation

- [User documentation](https://fizzlayer.com/docs.html) (`public/docs.html`; its WebMCP tool table is generated by `node scripts/agent-cards.mjs`)
- [Self-hosting and operations](docs/SELF_HOSTING.md)
- [CLI installation and usage](docs/CLI.md)
- [Accounts, APIs, and integrations](docs/REFERENCE.md)
- [Product architecture](docs/PRODUCT_PLAN.md)
- [Security audit and operational findings](docs/SECURITY_AUDIT.md)
