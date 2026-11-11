# Fizzlayer architecture

Fizzlayer connects sensor readings to a dashboard, threshold alerts, and AI agents. The application uses a static web interface, Rust API functions on Vercel, and Supabase for authentication and persistent data. This document describes the implemented system; installation and configuration are covered in [Self-hosting](SELF_HOSTING.md) and the [CLI guide](CLI.md).

## Components

| Component | Responsibility | Source |
| --- | --- | --- |
| Web application | Account setup, sensor management, charts, chat, phone pairing, and agent credentials | [`public/`](../public/) |
| Rust API | Request validation, authentication, ownership checks, provider calls, and database RPCs | [`api/`](../api/), [`src/`](../src/) |
| Supabase | Auth users, customer records, sensor readings, credential hashes, alert rules, and notification queue | [`supabase/migrations/`](../supabase/migrations/) |
| Device CLI | Device pairing, Linux telemetry, custom readings, and systemd unit generation | [`cli/`](../cli/) |
| MCP endpoint | Authenticated sensor access and scoped agent actions | [`src/mcp.rs`](../src/mcp.rs) |

The public interactive demo uses simulated data and local replies. It does not require an account or call the product API. The `fizz-worker` Compute service holds WebSocket and MQTT connections and writes readings through the same database function as `POST /api/ingest`. Alert rows, silence detection, Fizz, and MCP do not depend on the worker being up; a reading stored by HTTPS still follows the original path. Live delivery to dashboards does.

## Reading flow

A sensor instance belongs to one customer and has a type, name, mode, and current status. Supported types are Water, Gas, Radio, Temperature, Pressure, Humidity, Sound, Phone, and Custom.

1. API sensors and paired CLI devices send readings to `POST /api/ingest` with a key scoped to their sensor, or hold a WebSocket or MQTT-over-WebSocket connection on `fizz-worker`. Clients learn the addresses from `GET /api/stream` (production uses `/compute/v1/fizz-worker` and does not offer TCP 1883). Those connections call the same ingest function. Phone devices send readings through `/api/phone` using their paired device credentials.
2. Rust validates the request and calls Supabase RPCs. The database validates credentials, ownership, metrics, and event identity before storing readings.
3. Numeric readings trigger database evaluation of enabled threshold rules. A separate minute scan evaluates silence rules (no reading for N minutes). Matching events appear in the dashboard. A call is queued only when the plan includes calls and the number is still paired, and the sender checks both again immediately before dialing.
4. The dashboard requests current values and recent history. Chat and MCP requests retrieve customer-scoped context from the same stored data.

A unique `event_id` makes ingestion retries idempotent for each sensor. Keys can be rotated or revoked independently. Sample streams advance on authenticated reads, at most once per 15 seconds per sensor; they are not continuously scheduled background jobs.

## Identity and access

Supabase Auth verifies email/password, Google, GitHub, and passkey sign-ins. Anyone can sign up; a new customer is created on first sign-in. Fizzlayer then issues its own 12-hour session in an HttpOnly, Secure, SameSite=Lax cookie. Session and device credentials are stored as hashes.

The browser talks to the Fizzlayer API. The server-side Supabase client in [`src/store/mod.rs`](../src/store/mod.rs) uses a service-role credential, which is never sent to the browser. Database RLS policies restrict authenticated customer ownership, while server-side authorization remains essential because service-role requests bypass RLS. The [security audit](SECURITY_AUDIT.md) documents protections and validation.

Agent tokens are managed separately from account sessions and sensor keys. Agents can read sensors, readings, and alerts. Alert creation requires an explicit token permission. A call is allowed only for a number the owner has already paired in the dashboard; the token cannot pair a phone. Otherwise the alert stays on the dashboard. Device pairing is available through MCP, but the person at the device must approve the claim before it connects.

## AI and optional providers

Typed chat uses Vercel AI Gateway with customer-scoped readings and consented phone context. Alert requests are validated and saved through database functions; the model does not evaluate threshold crossings. An AI provider outage does not prevent sensor ingestion or database alert evaluation.

ElevenLabs supplies speech transcription and synthesized replies for the dashboard's voice chat. AgentPhone supplies optional outbound alert calls. These integrations are configured with server-side credentials and are independent of basic sensor ingestion.

The notification queue is drained during reading-related requests and by `GET /api/cron`. The cron path is what delivers silence alerts and retries when no later reading arrives. It is invoked by Vercel Cron on Pro, or by an external scheduler, once a minute. Each cron run places at most one call. Dispatch is bounded, a call is claimed once, and provider failures do not reject an accepted reading. Calls are subject to cooldowns and account budgets, and they are placed only for Tinkerer, Pro, and Enterprise. A number must be paired with a spoken code before any alert can call it; pairing itself is rate-limited per account, number, and network. Hobbyist alerts stay on the dashboard. A downgrade skips calls that are still queued. Provider acceptance does not confirm that someone answered a call.

## Deployment boundaries

The hosted application runs as Vercel Functions plus static assets, with a Supabase project providing Postgres, PostgREST, and Auth. `deploy/docker-compose.yml` runs the same API and the live worker on one machine, with Postgres, GoTrue, and PostgREST, or pointed at Supabase Cloud. Self-hosting instructions cover both.

Phone motion, location, and microphone capabilities depend on browser permissions and platform support. Sharing requires the phone page to remain active and can stop when the browser suspends it. The system monitors readings and sends alerts; it does not control physical actuators.
