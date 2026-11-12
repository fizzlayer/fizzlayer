# Fizzlayer technical reference

Account flows, plans, sensor APIs, alerts, voice, and agent connections. For setup, start with [self-hosting](SELF_HOSTING.md); for devices, see the [CLI guide](CLI.md).

## Customer onboarding

Anyone can create an account from `/app.html` with email and password, Google, or GitHub. New accounts start on the free Hobbyist plan. Sign-up is limited at two steps, each with its own buckets: when a confirmation email is requested (`fizz_sign_up_allowed`), and when a Fizzlayer account is created on first sign-in (`fizz_oauth_sign_in`, for every provider, including email users created outside the app). Each step allows 10 an hour per network, 50 an hour per IPv6 /48, and 5,000 an hour across the service as a circuit breaker. A network is an IPv4 address or an IPv6 /64 block. IPs come from Vercel's `x-real-ip` header and are stored only as SHA-256 hashes in `fizz_rate_limits`; every IP-based limit in the API groups IPv6 by /64 the same way.

A self-hosted instance can stop new accounts with `update public.fizz_instance_settings set sign_up_open = false;`. Sign-up and first sign-ins then answer `403 sign_up_closed`; existing accounts still sign in.

Businesses use the Enterprise form on the landing page, which posts to `POST /api/contact` with an email, a company name (up to 120 characters), and an optional note (up to 500). Entries go to `fizz_business_interest`, one row per email; submitting again updates the company and note. That form allows 10 submissions per client IP per hour and 1,000 overall per hour.

Sign-up used to need an invite code, and the landing page collected a waitlist. Both are retired: `fizz_waitlist` and `fizz_invite_codes` are kept for their existing rows (to email the people on the list, and to keep redemption history), but nothing writes to them. `POST /api/waitlist` is rewritten to `/api/contact`, which answers a waitlist sign-up with `410 waitlist_closed` so cached pages and agents get a clear answer. The invite-era functions (the 4-argument `fizz_oauth_sign_in`, `fizz_check_invite`, `fizz_join_waitlist`, `fizz_create_invites`, `fizz_normalize_invite`) stay in the database so the old code keeps working while a deploy rolls out; drop them in a later migration once every deployment runs the new code. Apply the migration before deploying the code, since the new code calls functions it adds.

### Sign-in through Supabase Auth

Every customer is a Supabase Auth user (`fizz_customers.auth_user_id`, required). Customers sign in with **email and password**, **Google**, **GitHub**, or a **passkey**. Supabase verifies who they are, then Fizzlayer issues its own session: a random token stored only as a hash and sent in a 12 hour HttpOnly, Secure, SameSite=Lax `fizz_session` cookie. Authenticated web app endpoints use that cookie; ingestion, MCP, and paired devices use their own scoped credentials. All Supabase Auth calls run in `src/auth.rs`, so the browser never receives a Supabase key.

`fizz_oauth_sign_in` links a verified Supabase user to its customer. A new customer is created on first sign-in and gets a username derived from the email address, such as `janedoe` or `janedoe_4821`. Deleting the Supabase user (for example from the Supabase dashboard, to honor a deletion request) deletes the customer and everything it owns.

**Email and password.** `POST /api/auth` takes a JSON `action`:

| Action | What it does |
| --- | --- |
| `sign_up` | Checks the per-network sign-up limit with `fizz_sign_up_allowed`, then calls Supabase `signup`. Supabase emails a confirmation link to `/app.html`. Replies the same way for new and existing addresses. |
| `sign_in` | Supabase password grant. Unconfirmed addresses get `email_not_confirmed`, and the page offers to resend. |
| `resend`, `recover` | Resend the confirmation, or send a password reset link to `/app.html`. Always reply `ok`. |
| `link` | Finishes an email link. Supabase puts an access token in the URL fragment; the page sends it here once and clears it. With `password`, it sets a new password first (reset links). |

New and reset passwords require at least 12 characters and at most 72 bytes; Supabase may also reject breached passwords.

**Passkeys.** Supabase only lets an existing, signed-in user register a passkey, so passkeys are a way back in rather than a way to sign up. After any sign-in, the Supabase access token is kept for up to an hour in an HttpOnly `fizz_supabase` cookie (`Path=/api`). The **+** button on the Settings page (`/settings.html`) uses it: `passkey_add_options` → `navigator.credentials.create()` → `passkey_add`, which also labels the passkey with the browser and device, such as "Chrome on Mac". Settings lists passkeys and removes them through `GET` and `DELETE /api/account`, which use Supabase's admin API, so they work for the whole session. **Sign in with a passkey** runs `passkey_options` → `navigator.credentials.get()` → `passkey_sign_in`, with no email needed. WebAuthn JSON passes through unchanged. Signing out revokes the Supabase session and clears both cookies.

**Google and GitHub.** The sign-in page asks `GET /api/auth?providers` which of them are turned on in Supabase (from `/auth/v1/settings`) and hides the other buttons. **Continue with Google** opens `GET /api/auth?provider=google`, and **Continue with GitHub** opens `GET /api/auth?provider=github`. Any other provider gets a 400, and a provider turned off in Supabase goes back with `auth_error=unavailable` instead of reaching Supabase's error page. The function stores a PKCE verifier in a 10 minute HttpOnly `fizz_oauth` cookie, then redirects to Supabase's `/auth/v1/authorize`. Supabase returns to `GET /api/auth?code=...`, where the code is exchanged using the verifier, so a code minted for a different browser fails. Failures come back as `/app.html#auth_error=<code>`: `rate_limited`, `cancelled`, `expired`, `failed`, `unavailable`, `no_email` (the provider gave no verified email, for example a GitHub account with none, so retrying will not help), or `verify_email` (Supabase emailed a confirmation link for an unverified provider address). A Google or GitHub account with no Fizzlayer account yet gets one on its first sign-in.

Supabase sees every Auth request coming from Vercel. The client IP is forwarded in `X-Forwarded-For`, but if Supabase ignores it, its per-IP Auth rate limits apply to all customers together.

The following Supabase Auth settings describe the hosted service. For your own deployment, replace `fizzlayer.com` with your domain and follow the [self-hosting guide](SELF_HOSTING.md):

1. **Email:** under **Authentication → Sign In / Providers → Email**, keep email sign-ups and **Confirm email** on. Configure custom SMTP under **Authentication → Emails → SMTP Settings**. Supabase's built-in sender only delivers to project team members, about 2 emails an hour.
2. **Google:** create a Google Cloud OAuth client ID of type **Web application** with `https://<project-ref>.supabase.co/auth/v1/callback` as an authorized redirect URI, then turn on **Google** under **Sign In / Providers** with that client ID and secret.
3. **GitHub:** create a GitHub OAuth App with `https://<project-ref>.supabase.co/auth/v1/callback` as its authorization callback URL, then turn on **GitHub** under **Sign In / Providers** with that client ID and secret. A GitHub OAuth App allows one callback URL, so local development needs a second app pointing at `http://127.0.0.1:54321/auth/v1/callback`.
4. **Passkeys:** turn on passkeys and set the relying party ID to `fizzlayer.com`, the origin to `https://fizzlayer.com`, and the display name to `Fizzlayer`. Changing the relying party ID later invalidates every existing passkey. Passkeys only work on that domain, not on Vercel preview URLs.
5. **URL configuration:** set **Site URL** to `https://fizzlayer.com`, and add `https://fizzlayer.com/api/auth` and `https://fizzlayer.com/app.html` to **Redirect URLs**. For local development, also add `http://localhost:3000/api/auth` and `http://localhost:3000/app.html`.

The core account flows require `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`. See [self-hosting](SELF_HOSTING.md) for deployment settings and optional integrations.

Link the project with `supabase link --project-ref <project-ref>`, then apply migrations with `supabase db push --linked` and set `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` in Vercel. The browser calls only Fizzlayer's `/api/contact`, `/api/auth`, `/api/session` (sign out), and `/api/me` endpoints for accounts; it never receives a Supabase key.

Customer-owned tables have RLS policies for the `authenticated` role. Most have separate SELECT, INSERT, UPDATE, and DELETE policies. `fizz_verified_phones` has SELECT and DELETE only, so a future table grant cannot mark a number verified without the pairing code; a BEFORE DELETE trigger skips queued calls to that number. `fizz_call_verifications` and `fizz_call_code_pepper` have RLS and no client policies, because they hold code hashes and the pepper. Ownership resolves `auth.uid()` through `fizz_customers.auth_user_id`; Supabase anonymous sign-ins are rejected. Writes must preserve ownership and reference the same customer's sensors, readings, rules, devices, and agents. Invite ownership uses `fizz_invite_codes.created_by`; unowned invites and unclaimed device pairings are inaccessible to clients. Waitlist submissions, business leads, and rate limits remain server-only.

Table grants and server-only RPC permissions remain unchanged: clients still cannot access tables directly. The server's `service_role` bypasses RLS, so its existing session and ownership checks remain necessary. To verify the policies, run `supabase db query --linked --file supabase/tests/authenticated_owner_rls.sql`. The test uses isolated fixtures and temporary client grants to exercise RLS, then rolls back every change.

The [security audit](SECURITY_AUDIT.md) records deployed database/Auth protections, source changes, test results, and remaining operations. Password/email changes invalidate Fizz sessions; banning or deleting an Auth user also revokes their agents and devices. New and reset passwords require at least 12 characters (72-byte maximum); existing passwords still work at sign-in. Session and device credentials stay hashed in the database.

Run `supabase db query --linked --file supabase/tests/security_hardening.sql` to verify session revocation, credential checks, budgets, and default grants. All SQL test files roll back their fixtures; run linked CLI commands sequentially because they refresh a shared temporary login credential. Production Auth and database SSL settings are recorded separately in `supabase/config.production-security.toml`; keep the local-development configuration separate from production.

After sign-in, new accounts choose sensor types and press **Start with sample data**. Fizz creates simulated sensors and opens the dashboard. Existing choices migrate into sensor instances. Simulated values advance when an authenticated dashboard or Sensors page requests data, at most once per 15 seconds per sensor; the browser polls while open.

## Plans and limits

Each account has a plan that caps its connected devices and its monthly Fizz credits:

| Plan | Price | Connected devices | Fizz credits per month | Phone calls |
| --- | --- | --- | --- | --- |
| Hobbyist | Free | 3 | 10 | No. Dashboard alerts only |
| Tinkerer | $10/month | 10 | 100 | Yes |
| Pro | $25/month | 50 | 1,000 | Yes |
| Enterprise | Custom | Unlimited | Unlimited | Yes |

- **Connected devices** are API sensors (including CLI-paired devices) and phone sensors that have not been deleted. Sample sensors are free and unlimited. The limit is checked when a sensor is created as, or switched to, API or phone mode; when a phone link is created for a sample Phone sensor; when a pairing code is claimed from the dashboard, chat, or MCP; and again when the device approves. Over the limit, the API returns `403` with code `device_limit`. Existing devices keep working after a downgrade, but no more can be added until the count is below the limit.
- **Fizz credits** pay for the workspace chat. Each `POST /api/chat` spends one credit after the rate limits pass, so a spoken turn costs one credit too. Speech requests (`/api/voice`) don't spend credits but stop when none remain. Credits reset at the start of each UTC calendar month. When they run out, chat returns `402` with code `credits_exhausted`. If a chat request fails before Fizz's model is asked (the database or chat configuration is unavailable), its credit is given back (`fizz_refund_credit`). Once the model request is sent, the credit stays spent whatever comes back.
- **Phone calls** are included when `fizz_plans.calls_enabled` is true (Tinkerer, Pro, and Enterprise) and the subscription status is null, `active`, `trialing`, or `past_due`. `canceled`, `unpaid`, and `incomplete` do not place calls even if the plan column is still a paid plan. Hobbyist can create dashboard-only alerts (`notify_channel` `none`). A call alert returns `402` `calls_not_included` when calls are not included and `400` `phone_not_paired` until that number is in `fizz_verified_phones`. The same checks run when the event is queued and again in `fizz_alert_call_still_due`. Dispatch calls that check once more immediately before contacting AgentPhone, so a removal or downgrade that lands after the first check is visible. `fizz_billing_sync` skips pending and sending calls when the plan loses calls. Paired numbers are kept across a downgrade.

Pairing is owner-session only (`GET`/`POST /api/phones`). The database returns a 6-digit code to the API, which speaks it digit by digit and does not return it to the browser. The code is stored as a SHA-256 of a per-row salt, the code, and a pepper clients cannot read. It expires after 10 minutes, allows 5 attempts, and works once. Rows older than a day are deleted when the next pairing call starts. A new call waits 60 seconds for the same account and number; the lock is the per-workspace advisory lock taken before that check. Call budgets are consumed when the pairing call is reserved, before AgentPhone is contacted, and a provider failure does not refund the slot. The limits are 5 an hour and 10 a day per account, 3 an hour and 5 a day per number across all accounts, 8 an hour per network (one IPv4 address or one IPv6 /64), 20 an hour per IPv6 /48, and 100 an hour for the whole service. `retry_after_seconds` is the time left in the window that was exceeded. A workspace can hold 10 paired numbers; confirm recounts under the same lock, so two in-flight codes cannot both insert. Toll-free, premium (900 and the 976 exchange), personal-communication, and fictional 555 numbers are rejected. Agent tokens and WebMCP have no pairing tool. Fizz chat receives `paired_phones` in its sensor context.

Limits live in `fizz_plans`, read through `fizz_monthly_credits`, which is the single source for enforcement. When the allowances were cut (November 2026), existing customers kept their previous allowance in `fizz_credit_grandfather`: paid subscribers until the end of the billing period they had paid for, everyone else until the next monthly reset. A grandfathered allowance applies only while the customer stays on the plan it was recorded for; the landing page's pricing table repeats the numbers. Accounts without a `fizz_subscriptions` row are on Hobbyist. Usage is stored in `fizz_credit_usage`, and `GET /api/account` returns the plan and current usage, which Settings displays.

Run `supabase db query --linked --file supabase/tests/plan_limits.sql` to verify device limits, credit spending, monthly resets, and client grants.

### Billing with Stripe

Sign-up itself does not ask for a plan. New accounts start on Hobbyist. When the Stripe variables are set, the next screen offers Hobbyist, Tinkerer, Pro, and an Enterprise contact link, and the dashboard has **Choose plan**. Settings offers **Upgrade** buttons for Tinkerer and Pro plus **Manage billing** once an account has a Stripe customer. A visit to `/app.html?plan=tinkerer` or `?plan=pro` opens Checkout as soon as the session exists, including after GitHub returns. Without the Stripe variables, that screen and **Choose plan** stay hidden, checkout is skipped, and the new account opens the dashboard. Plans change only in the database until the webhook records a paid subscription.

| Variable | Value |
| --- | --- |
| `STRIPE_SECRET_KEY` | Secret key (`sk_...`), or a restricted key with write access to Customers, Checkout Sessions, Customer portal, and read access to Subscriptions |
| `STRIPE_WEBHOOK_SECRET` | Signing secret (`whsec_...`) of the webhook endpoint below |
| `STRIPE_PRICE_TINKERER` | Price ID (`price_...`) of the monthly Tinkerer price |
| `STRIPE_PRICE_PRO` | Price ID of the monthly Pro price |

- `GET /api/billing` returns `{"available":true}` when the four Stripe variables are set, and `{"available":false}` otherwise. It does not require a session.
- `POST /api/billing` with `{"action":"checkout","plan":"tinkerer"}` (or `"pro"`) creates a Stripe Checkout session; `{"action":"portal"}` opens the Stripe customer portal. Both return `{"url": ...}` for the browser to open and allow 20 requests per account per hour. Checkout creates one Stripe customer per account and refuses (`409 already_subscribed`) while a subscription is active, since plan changes go through the portal. Optional `"return_to":"app"` sends Stripe back to `/app.html`; omitted or `"settings"` sends it to `/settings.html`. Any other value is `400 invalid_return`. Success and cancel add `?billing=success` or `?billing=cancelled`. Cancelling does not change the plan.
- `POST /api/stripe-webhook` receives Stripe events. Subscribe the endpoint to `checkout.session.completed`, `customer.subscription.created`, `customer.subscription.updated`, and `customer.subscription.deleted`. Each event's signature and timestamp (5-minute tolerance) are verified; the handler then fetches the subscription from Stripe and stores its current state, so retried and out-of-order events are harmless. A failure answers `500` so Stripe retries.
- `active`, `trialing`, and `past_due` subscriptions keep their plan; `past_due` keeps it while Stripe retries the payment. Any other status, or a price that matches neither variable, returns the account to Hobbyist. Enterprise accounts are never changed by webhooks.
- In the Stripe customer portal settings, allow switching between the Tinkerer and Pro prices and cancelling. For local testing, use test-mode keys and prices with a local database so no real account or card is involved:

  ```sh
  stripe listen --forward-to localhost:3000/api/stripe-webhook   # in one terminal
  STRIPE_SECRET_KEY=sk_test_... STRIPE_WEBHOOK_SECRET=whsec_... \
  STRIPE_PRICE_TINKERER=price_... STRIPE_PRICE_PRO=price_... \
  scripts/dev.sh --local-db                                      # in another
  ```

  `stripe listen --print-secret` prints the forwarding secret, which stays the same between runs. The script passes `STRIPE_*` variables to the app and refuses live keys. Pay with the test card `4242 4242 4242 4242`; the `stripe listen` terminal shows each event and the app's response.

To set a plan by hand, such as Enterprise, use the SQL editor:

```sql
insert into public.fizz_subscriptions(customer_id, plan)
select id, 'enterprise' from public.fizz_customers where username = 'USERNAME'
on conflict (customer_id) do update set plan = excluded.plan, updated_at = now();
```

Run `supabase db query --linked --file supabase/tests/billing.sql` to verify how subscription states map to plans.

## Sensor API

The Sensors page can create additional sensors, switch a sensor to API mode, rotate its key, create a phone link, and remove a sensor. API keys are scoped to one sensor, stored only as hashes, and shown once. The main routes are:

| Route | Purpose |
| --- | --- |
| `GET`, `POST`, `PATCH`, `DELETE /api/sensors` | List, create, update, remove customer sensors (session cookie) |
| `GET /api/readings?sensor_id=<uuid>&limit=100` | Recent readings for an owned sensor |
| `POST /api/ingest` | Send readings using a sensor API key |
| `GET /api/stream` | Whether live streaming is configured, and the WebSocket and MQTT URLs |
| `POST /api/stream` | Mint a 15-minute stream token for the signed-in workspace or an agent token |
| `GET`, `POST`, `DELETE /api/phone` | Pair and revoke phone devices; phone posts motion, voice, and location data |
| `GET`, `POST`, `PATCH`, `DELETE /api/alerts` | View and manage threshold and silence rules. A call alert is rejected unless the number is paired and the plan includes calls |
| `GET`, `POST /api/phones` | List, pair, confirm, and remove workspace phone numbers. Owner session only; agent tokens cannot call it |
| `GET`, `POST /api/cron` | Scan silence alerts and send queued calls for up to about 36 seconds. Requires `Authorization: Bearer $CRON_SECRET`. A blank secret is treated as unset and the route returns 503 |
| `POST /api/chat` | Ask Fizz about readings, add sensors, claim device pairing codes, and create alerts |
| `GET`, `POST /api/voice` | Check voice availability, transcribe microphone audio, and speak agent replies (session cookie) |

For API ingestion, use a unique `event_id` for each sample; retries with the same ID are idempotent. A WebSocket or MQTT publish uses that same rule and the same per-sensor and per-account rate limits, because the worker calls `fizz_ingest_event`. Metrics are validated against the sensor type. For example, a Temperature sensor accepts `temperature_c`:

```sh
curl -X POST https://fizzlayer.com/api/ingest \
  -H 'Authorization: Bearer YOUR_SENSOR_API_KEY' \
  -H 'Content-Type: application/json' \
  -d '{"sensor_id":"YOUR_SENSOR_ID","event_id":"sample-001","metrics":{"temperature_c":27.4}}'
```

### Live socket and MQTT

Call `GET /api/stream` for the addresses. Do not hardcode the host. Until `FIZZ_STREAM_URL` is set, the body is `{"enabled": false}`. Production currently returns:

```json
{
  "enabled": true,
  "websocket_url": "wss://bbmdkpzzzalkvthwgsek.supabase.co/compute/v1/fizz-worker/v1/stream",
  "live_url": "wss://bbmdkpzzzalkvthwgsek.supabase.co/compute/v1/fizz-worker/v1/live",
  "mqtt_ws_url": "wss://bbmdkpzzzalkvthwgsek.supabase.co/compute/v1/fizz-worker/mqtt",
  "mqtt_tcp_url": null
}
```

The gateway prefix is `/compute/v1/fizz-worker`, not `/workers/v1/`. `POST /api/stream` with the session cookie, or `Authorization: Bearer fizz_agent_...`, returns a `fizz_stream_` token that lasts 15 minutes. The body may be `{}` or `{"sensor_id": "<uuid>"}`. A token without a sensor id can subscribe to every sensor in that workspace. A token with a sensor id can subscribe only to that sensor. Issuing is limited to 60 tokens an hour per workspace and 30 an hour per agent. The token cannot publish.

Devices publish with the sensor API key, not the stream token. On the WebSocket at `websocket_url`, the first text frame is `{"op":"auth","key":"fizz_..."}` (or the same key in `Authorization: Bearer` on the upgrade). Each reading is `{"op":"reading","sensor_id","event_id","metrics","observed_at"?}`. The server answers `{"op":"ack","event_id"}` or `{"op":"error","error","event_id"}`. `live_url` is the subscribe socket: after auth, send `{"op":"subscribe","sensor_id"?}`. Readings arrive as `{"op":"reading",...}` without a customer id.

MQTT uses protocol 3.1.1, QoS 0 or 1, and no wildcards, on the WebSocket URL from `GET /api/stream` with subprotocol `mqtt`. Connect with username set to the sensor id and password set to the sensor key. Publish JSON `{"event_id","metrics","observed_at"?}` to `fizz/v1/<sensor-id>/readings`. Subscribe to `fizz/v1/<sensor-id>/live`. A stream token or agent token connects with that token as the password and may only subscribe. Production `mqtt_tcp_url` is null: there is no plain TCP port 1883. Arduino PubSubClient and Home Assistant's MQTT integration should use `POST /api/ingest` or the Fizzlayer Home Assistant integration. ESP-IDF can use `MQTT_TRANSPORT_OVER_WSS` against `mqtt_ws_url`.

The dashboard mints a workspace token and subscribes in the browser. `fizz tail` does the same with the device key. Threshold alerts still run in the database trigger. A call queued by a streamed reading is placed by `/api/cron`, which already scans about once a minute, rather than inside the worker.

### Request size limits

Every limit below is checked before any database or model call. Request bodies are capped while they are read, so an oversized body is rejected without being buffered.

| Request | Limits |
| --- | --- |
| `POST /api/ingest` | Body up to 16 KB (`413` beyond). One reading has 1 to 16 metrics, or a Home Assistant connection key sends `{"readings": [ ... ]}` with 1 to 40 readings. Metric names up to 40 characters (lowercase letters, digits, underscores), text values up to 512 bytes, `event_id` up to 128 characters. Numbers, booleans, and text only; objects and arrays are rejected inside a metric value. The database enforces the metric count and text length again. |
| WebSocket and MQTT frames | One frame or MQTT packet up to 16 KB, with the same metric, event id, and text limits as ingest. The database checks the sensor type and the 1,200-per-sensor and 5,000-per-account minute limits again. |
| Phone readings and transcripts | Body up to 360 KB. Audio clips up to about 256 KB, transcripts up to 500 bytes, event IDs up to 100 characters. |
| `POST /api/chat` | Body up to 64 KB. The new message is up to 1,000 characters. Up to 12 earlier messages of up to 3,000 characters each. The new message and history together are capped at 12,000 characters: the server keeps the newest earlier messages that fit, starting from a user message, and drops the rest. The dashboard sends only the newest messages that fit. Fizz's replies are at most 3,000 characters. |
| `POST /api/voice` | Recordings up to 2 MB and 30 seconds; transcripts up to 1,000 characters; text to speak up to 3,000 characters. |
| `POST /api/mcp` | Body up to 64 KB. |

Home Assistant uses the same ingest path. Install `custom_components/fizzlayer` first (HACS custom repository `fizzlayer/fizzlayer`, category Integration, then restart), or Add integration reports that the integration does not support configuration via the UI. The Sensors page and the docs then open My Home Assistant (`config_flow_start?domain=fizzlayer`). The integration polls `POST /api/devices` with `action: "ha_exchange"`, including the 6-digit code it is showing and the install name and version. `ha_authorize` accepts the signed-in owner only when they send that same code; `ha_preview` returns the name and version and never the code. Apply `supabase/migrations/20261108000000_ha_confirm_and_alert_restore.sql` with the earlier Home Assistant migration. The device key is returned once. `ha_sync` maps each chosen `sensor` or `binary_sensor` entity to an API-mode sensor labeled `source: "homeassistant"`. `ha_revoke` is owner-only and also accepts the connection key when the integration is removed. Readings from that key are stored with source `homeassistant`. A batch body is `{"readings":[{sensor_id, event_id, metrics, observed_at}, ...]}` with at most 40 items. There are no new environment variables. Apply `supabase/migrations/20261107000000_home_assistant.sql` with `supabase db push` before using the endpoints.

Phone pairing links expire after 15 minutes and can be claimed once. A claimed phone can share motion and orientation while its page is open, and can optionally share location, a short audio clip, or a transcript after separate consent. Browser support and permissions vary by phone. Owners can revoke paired phones from the Sensors page.

Threshold alerts are evaluated in Supabase whenever a numeric reading is inserted. A silence alert fires when a sensor sends no reading for a number of minutes (default 10, minimum 1, maximum 10080). One minute is the minimum because devices can report every 15 seconds, and the scheduler runs about once a minute. Silence is measured from `received_at`, the time the server stored the newest reading, so a backdated timestamp cannot hide a quiet sensor. The rule fires once for that quiet period, then arms again when a reading arrives. A paused, removed, or never-reported sensor does not fire. Resuming a paused sensor gives it a full window to report before silence can fire. Sample sensors cannot have silence alerts, because they only produce readings while someone is viewing them. The dashboard warns on silence alerts when no scan has run in the last 5 minutes (`silence_scheduler_active` in `GET /api/alerts`). Optional recovery records that readings resumed; a recovery call uses the same rate limits, so it is skipped when the silence call was placed in the last 5 minutes, and the event is still saved.

An alert can also call a US phone number when it triggers. Voice calls are the only enabled phone notification. The database queues the notification on the alert event. Repeating the same rule from the dashboard, chat, WebMCP, or MCP returns the existing rule. The request that stored a reading still sends up to three queued calls, so a threshold crossing can ring during that request. `GET /api/cron` scans for silence and then sends queued calls one at a time, including retries, until the queue is empty or about 36 seconds have passed. A retryable rejection ends that run so the call is not repeated straight away. `vercel.json` registers it as `* * * * *` and gives the function a 60-second max duration, so the last agent lookup and 8-second call can finish. That needs Vercel Pro: an every-minute cron is rejected on Hobby and fails the deploy, so on Hobby remove the `crons` entry and call the route yourself once a minute. Before each dial the server checks that the rule is still enabled, the sensor is still active, and a silence call is not for a sensor that has already reported again. Pausing or deleting the rule, or pausing or removing the sensor, cancels a call that is still pending. Claiming a call sets it to `sending` with `for update skip locked`, so an ingest request and the cron job cannot place the same call. Each rule notifies at most once per 5 minutes, each account at most 20 times per hour, and transient connection or rate-limit rejections are retried up to three times within an hour. Sends with an uncertain outcome (timeouts or provider server errors) stop for review because AgentPhone does not support idempotency keys.

| Variable | Value |
| --- | --- |
| `AGENTPHONE_API_KEY` | AgentPhone API key, stored as a Vercel Production Secret |
| `AGENTPHONE_AGENT_ID` | Optional agent ID; required when the AgentPhone account has multiple agents. With exactly one agent, Fizz selects it automatically. |
| `CRON_SECRET` | Shared secret for `/api/cron`. Vercel sends it as `Authorization: Bearer <CRON_SECRET>` when the variable is set. A missing or blank value makes the route return 503 and place nothing. Required for silence alerts and for retries that have no later reading to ride on. |

Create an AgentPhone agent and attach a voice-enabled phone number to it. Calls use the agent's first attached number. Existing SMS rules are kept as dashboard alerts, and queued texts are skipped. Calls speak the alert as their greeting and use a short hosted conversation to repeat it if needed; Fizz disables audio recording for these calls. The delivery status means the provider accepted the send, rather than confirming receipt on the recipient's device.

Notifications are only sent where the AgentPhone key is set, so preview deployments sharing the database leave queued alerts for production. Chat uses Vercel AI Gateway to answer from stored customer readings and creates alerts directly when the customer clearly asks. It asks for missing details, validates the owned sensor and, for a threshold, the reported numeric metric and unit, and reports success only after the database saves the rule. A silence alert needs only the sensor and a whole number of minutes. Identical active alerts are reused. Phone calls are enabled only when requested with a US number supplied in the conversation. The browser includes up to 12 recent messages so follow-up instructions work; history is cleared at sign-out. An AI outage does not stop ingestion or alert evaluation.

## Add sensors and pair devices in chat

Ask Fizz to add a sensor, for example, “Add a sample Temperature sensor named Cold room” or “Add an API Humidity sensor named Greenhouse.” Fizz asks for a type, name, and source when they are missing. API sensors return a one-time credential card; the key is kept outside reply text and the conversation history sent to the model. Phone sensors appear in Sensors, where you can create a phone link. Repeated requests for the same owned name, type, and mode reuse the existing sensor.

New accounts can choose **Set up with Fizz in chat** to add their first sensor without loading sample data.

Ask “Help me pair my Raspberry Pi” for installation commands, then send “Pair my device with code 7K3P-Q9DM.” The server accepts only a code supplied in a user message, uses the signed-in customer's session to claim it, and requires approval in the device terminal. Claiming a code does not yet connect the device. After approval, run `fizz run --every 60`; the device appears as a Custom sensor. Expired or used codes require a new `fizz pair` run. The same chat actions are available through voice chat.

## Talk to Fizz

The dashboard's **Talk to Fizz** button records one spoken turn (up to 30 seconds). Tap **Send recording** to submit it. ElevenLabs transcribes it, the same Fizz chat agent answers or creates an alert, and ElevenLabs speaks the reply. Replies remain visible in chat, and audio controls provide playback if the browser blocks autoplay. The microphone stops after each recording and on sign-out. Fizz does not save these microphone recordings; audio is sent to ElevenLabs for transcription, subject to the provider's retention policy.

| Variable | Value |
| --- | --- |
| `ELEVENLABS_API_KEY` | Server-only ElevenLabs API key with speech-to-text and text-to-speech permissions; store it as a Vercel Production Secret |
| `ELEVENLABS_VOICE_ID` | Optional voice ID; defaults to George (`JBFqnCBsd6RMkjVDRZzb`) |

Speech uses ElevenLabs `scribe_v2` transcription and `eleven_multilingual_v2` synthesis. This is voice chat inside Fizz; outbound threshold-alert calls continue to use AgentPhone. Typed chat stays available when speech or microphone access is unavailable.

## Agent connections (MCP)

AI agents reach a customer's data through Fizz's MCP server at `POST /api/mcp`. On the **Agents** page (`/agents.html`), the customer creates a token for each agent. The token looks like `fizz_agent_…`, is shown once, and is stored only as a hash. Tokens can read sensor data and claim device pairing requests, which still require approval at the device. Creating dashboard alerts requires an additional permission. Tokens can be revoked at any time. Agents never receive device keys, phone numbers, or the session cookie.

The server is stateless and speaks both MCP eras on the same endpoint. Clients on 2026-07-28 send the protocol version in `_meta` along with the `MCP-Protocol-Version`, `Mcp-Method`, and `Mcp-Name` headers. The server validates these headers and implements `server/discover`. Older clients (2025-03-26 through 2025-11-25) open with `initialize`. Every request needs `Authorization: Bearer <token>`. Tool calls are limited to 120 per minute per token. A request carrying a foreign `Origin` header is rejected.

| Tool | What it does |
| --- | --- |
| `list_sensors` | Sensors and paired devices with their latest reading |
| `get_readings` | Recent readings for one sensor, optionally one metric (up to 100) |
| `list_alerts` | Threshold and silence rules (kind, window, whether each is triggered) and the 20 most recent triggers |
| `create_alert` | Threshold or silence alert. A silence alert takes `kind: "silence"` and optional `silence_minutes` (default 10). Optional `call_phone` must already be paired by the owner in the dashboard, and the plan must be Tinkerer, Pro, or Enterprise. The token cannot pair a number. Repeats return the existing rule (only for tokens allowed to create alerts) |
| `pair_device` | Claim a pairing code shown by `fizz pair` |

Hermes Agent (`config.yaml`):

```yaml
mcp_servers:
  fizz:
    url: "https://fizzlayer.com/api/mcp"
    headers:
      Authorization: "Bearer fizz_agent_..."
```

Claude Code: `claude mcp add --transport http fizz https://fizzlayer.com/api/mcp --header "Authorization: Bearer fizz_agent_..."`


## WebMCP (browser agents)

Every main page (`/`, `/app.html`, `/sensors.html`, `/agents.html`, `/settings.html`, `/privacy.html`, `/terms.html`) loads `public/webmcp.js`, which registers [WebMCP](https://developer.chrome.com/docs/ai/webmcp) tools with `document.modelContext.registerTool()`. Browsers without WebMCP skip the script. A browser agent pointed at `https://fizzlayer.com` and asked to onboard can call `get_started`, which reports the sign-in state and the next calls, then complete onboarding and use the whole site without touching the UI. `/llms.txt` describes the same flow for agents that read the site first, and the landing and legal page footers link to it.

Two discovery cards describe the tools without loading a page: `/.well-known/webmcp` lists every WebMCP tool with its description, input schema, and hints, plus the pages that register them, and `/.well-known/mcp/server-card.json` describes the remote MCP server (an [MCP Server Card](https://github.com/modelcontextprotocol/modelcontextprotocol/issues/1649), still a draft proposal). Both are generated from `public/webmcp.js` and `src/mcp.rs`; after changing a tool, run `node scripts/agent-cards.mjs`, which also regenerates the WebMCP tool table in `public/docs.html`. CI runs it with `--check` and fails if a card or the table is out of date. The same script writes `/.well-known/mcp.json` (a compact MCP manifest) and `/.well-known/ai-plugin.json` (a plugin manifest pointing at the hand-written OpenAPI 3.1 description in `public/openapi.json`, which `--check` validates). Vercel serves them all as JSON with `Access-Control-Allow-Origin: *`. `robots.txt` welcomes AI crawlers and links `sitemap.xml`, and the landing and docs pages carry Schema.org JSON-LD. Together these cover the signals agent indexes such as [Not Human Search](https://nothumansearch.ai) score.

The tools call the same same-origin JSON endpoints as the pages, with the browser's `fizz_session` cookie, so they have exactly the signed-in person's access and nothing more. When a tool changes data it dispatches a `fizz:changed` event; the dashboard, Sensors, Agents, and Settings pages redraw, and tools that change the session reload session-dependent pages. Failures are returned as `{"ok": false, "error": "..."}` results rather than thrown, because browsers hide thrown messages from the agent.

| Area | Tools |
| --- | --- |
| Onboarding | `get_started`, `list_plans`, `contact_sales`, `create_account`, `resend_confirmation`, `send_password_reset`, `sign_in`, `sign_out`, `start_with_sample_data` |
| Sensors and devices | `list_sensor_types`, `list_sensors`, `get_readings`, `add_sensor`, `update_sensor`, `remove_sensor`, `create_phone_link`, `disconnect_phones`, `get_device_setup`, `pair_device` |
| Alerts and Fizz | `list_alerts`, `create_alert`, `set_alert_enabled`, `delete_alert`, `ask_fizz` |
| Agent connections | `list_agent_connections`, `create_agent_connection` (returns an MCP token and client configuration once), `revoke_agent_connection` |
| Account and billing | `get_account`, `start_checkout`, `open_billing_portal` |
| Navigation | `open_page` |

Tools that change accounts, credentials, money, or data that can't be recovered carry `consequentialHint`, so browsers and agents can ask the person to confirm; read-only tools carry `readOnlyHint`; tools that return text written by people or devices carry `untrustedContentHint`. Some steps stay with the person by design:

- **Accounts:** anyone can sign up, but email confirmation is still required. `create_account` asks the agent to use a password the person chose.
- **Payments:** `start_checkout` creates a Stripe Checkout session for Tinkerer or Pro and opens it in the same tab. The person enters payment details on Stripe's page; the webhook updates the plan as usual. `open_billing_portal` opens the Stripe portal the same way.
- **Device presence:** passkeys, Google and GitHub sign-in, voice, and phone sensor permissions need the person at the device.

WebMCP is in a Chrome origin trial. To test locally, enable `chrome://flags/#enable-webmcp-testing`, or launch Chromium with `--enable-features=WebMCP`, then list and run the tools from DevTools:

```js
const tools = await document.modelContext.getTools();
await document.modelContext.executeTool(tools.find((t) => t.name === 'get_started'), '{}');
```

Visitors on stable Chrome get WebMCP through the [origin trial](https://developer.chrome.com/origintrials/#/register_trial/4163014905550602241): each of those pages carries a `<meta http-equiv="origin-trial">` token for `https://fizzlayer.com` that expires on March 30, 2027. Renew it in the origin trial console before then and replace the token on every page. Self-hosted deployments need their own token for their origin. The `Permissions-Policy` header allows `tools=(self)`.
