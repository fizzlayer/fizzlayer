# Self-host Fizzlayer with Docker

This guide is for running Fizzlayer on a machine you control. You do not need to have used the repository before. Docker pulls the API and the live worker. Postgres, sign-in, and the website run on the same machine.

A second path, [Deploy on Vercel and Supabase](#deploy-on-vercel-and-supabase), keeps the API on Vercel. Use that when you already operate those accounts. The [technical reference](REFERENCE.md) lists every API.

Images:

- [fizzlayer/fizzlayer-api](https://hub.docker.com/r/fizzlayer/fizzlayer-api) serves the website and the API
- [fizzlayer/fizzlayer-worker](https://hub.docker.com/r/fizzlayer/fizzlayer-worker) accepts live WebSockets and MQTT

The same tags are also pushed to `ghcr.io/fizzlayer/fizzlayer-api` and `ghcr.io/fizzlayer/fizzlayer-worker`. `latest` tracks `main`. `sha-<commit>` pins one build. A `v*` git tag is published under that version name.

## What you need

- A computer that can run containers. Docker Engine 24 or newer, with the Compose plugin 2.24 or newer (`docker compose version`). The no-clone file uses Compose configs. Docker Desktop on macOS or Windows is fine.
- `openssl` and `python3`. The init script uses both. It does not install them. `git` is only needed if you clone the repository to build from source.
- Free TCP ports **8080** (website and API), **8081** (live WebSocket and MQTT-over-WebSocket), and **1883** (plain MQTT). The optional HTTPS proxy also needs **80** and **443**.
- About **1 GB of free RAM**. An idle stack used about 140 MB. Give it **4 GB of free disk**. The images are a little over 1 GB, and Postgres grows with readings.
- A browser on the same machine for the first account, or another computer that can reach port 8080.

Nothing else is required to sign up, create a sensor, and store readings. Chat, voice, phone calls, and card checkout stay off until you add those keys.

## Quick start with published images

You do not clone the repository. Create an empty directory and download three files. `deploy/compose.yml` pulls `fizzlayer/fizzlayer-api` and `fizzlayer/fizzlayer-worker` from Docker Hub, plus Postgres, GoTrue, PostgREST, and Caddy. The API image already contains the SQL migrations and applies them on first start. Nothing is built or mounted from a checkout.

```sh
mkdir fizzlayer && cd fizzlayer
curl -fsSL https://raw.githubusercontent.com/fizzlayer/fizzlayer/main/deploy/compose.yml -o compose.yml
curl -fsSL https://raw.githubusercontent.com/fizzlayer/fizzlayer/main/deploy/compose.env.example -o .env.example
curl -fsSL https://raw.githubusercontent.com/fizzlayer/fizzlayer/main/scripts/selfhost-init.sh -o selfhost-init.sh
sh selfhost-init.sh
docker compose up -d
```

`selfhost-init.sh` writes `.env` in this directory (mode 600) with a database password, a JWT secret, a service-role key, and `CRON_SECRET`. `.env.example` is the same list with placeholders, so you can read it before generating secrets. `docker compose up -d` pulls any image that is not already local and starts the stack. The migrate container exits 0 after it applies SQL. That is expected.

Open <http://localhost:8080>. Create an account. The password must be at least 12 characters. No confirmation email is sent: `MAILER_AUTOCONFIRM=true` is the default, so the account is usable immediately.

Check the API:

```sh
curl -fsS http://localhost:8080/api/status
```

You want `"status":"ok"` and `"database":"connected"`. HTTP 200 with `"database":"unavailable"` still means the database is not ready. Wait a few seconds and try again, then see [Troubleshooting](#troubleshooting). The worker answers on port 8081: `curl -fsS http://localhost:8081/health`.

Stop the stack with `docker compose down`. The database volume remains. `down -v` deletes it.

## Build the images yourself

Clone the repository when you want to change the server or you cannot pull from Docker Hub. From the checkout, `./scripts/selfhost-init.sh` writes `deploy/.env` (not the current directory). Then:

```sh
git clone https://github.com/fizzlayer/fizzlayer.git
cd fizzlayer
./scripts/selfhost-init.sh
docker compose -f deploy/docker-compose.yml up -d --build
```

`--build` compiles `fizzlayer/fizzlayer-api` and `fizzlayer/fizzlayer-worker` from this tree and tags them with those names. The next `up` without `--build` reuses the local images. Use this when you are changing the server, or when you cannot pull from Docker Hub. A release build of both images takes several minutes.

To pin a published build instead of `latest`:

```sh
# in deploy/.env
FIZZ_API_IMAGE=fizzlayer/fizzlayer-api:sha-FULL_COMMIT
FIZZ_WORKER_IMAGE=fizzlayer/fizzlayer-worker:sha-FULL_COMMIT
```

`sha-` is followed by the full 40-character git commit. The same tags exist under `ghcr.io/fizzlayer/`. If that registry asks you to log in, `docker login ghcr.io` with a GitHub token that can read packages, then set `FIZZ_API_IMAGE` and `FIZZ_WORKER_IMAGE` to the `ghcr.io` names.

## What `selfhost-init.sh` writes

From the no-clone directory:

```sh
sh selfhost-init.sh
```

From a checkout:

```sh
./scripts/selfhost-init.sh
```

The same script writes `.env` in the current directory when it is not inside this repository, and `deploy/.env` when it is. It refuses to overwrite that file. `--force` replaces it. Do that only when you mean to throw away the old passwords. A database that was already initialized keeps the old Postgres password in its volume, so a new `.env` will not log in until you also delete the volume (`down -v`) or change the password inside Postgres.

The script needs `openssl` and `python3`. It writes the file with mode `600` and prints nothing except the path. It generates:

- `POSTGRES_PASSWORD` and `AUTHENTICATOR_PASSWORD`, 24 random bytes each, hex
- `JWT_SECRET`, 32 random bytes, hex. GoTrue and PostgREST both use it
- `SUPABASE_SERVICE_ROLE_KEY` and `ANON_KEY`, HS256 JWTs signed with that secret, role `service_role` and `anon`, valid for about 10 years
- `CRON_SECRET`, 32 random bytes, hex

It also writes the local defaults below (public URL, ports, autoconfirm, empty provider keys). The service-role key can read and write every row. Leave it in `.env`. Do not commit that file, and do not put it in the browser.

## Environment variables

Set these in `.env` next to `compose.yml`, or in `deploy/.env` when you use the checkout. Empty values use the default in the compose file. Restart after a change: `docker compose up -d`.

### Required for the local stack

| Variable | Default if omitted | What it does |
| --- | --- | --- |
| `COMPOSE_PROFILES` | `local` | `local` starts Postgres, GoTrue, and PostgREST. Add `,tls` for HTTPS. Empty means "do not start the database"; see [Supabase Cloud](#use-supabase-cloud-instead-of-local-postgres) |
| `POSTGRES_PASSWORD` | none | Password for the `postgres` user. The init script sets it |
| `AUTHENTICATOR_PASSWORD` | none | Password for the PostgREST login role. Set only on the first boot of the database volume |
| `JWT_SECRET` | none | Shared HMAC secret for Auth tokens and PostgREST |
| `SUPABASE_SERVICE_ROLE_KEY` | none | Service-role JWT. The API and the worker send it to PostgREST |
| `PUBLIC_URL` | `http://localhost:8080` | Origin browsers use. Auth email links and OAuth redirects use it |

`ANON_KEY` is generated and not sent to the browser. The API does not read it. Keep it if you later put a gateway in front of PostgREST.

### Ports and addresses

| Variable | Default | What it does |
| --- | --- | --- |
| `API_PORT` | `8080` | Host port for the website and API |
| `WORKER_PORT` | `8081` | Host port for the worker's HTTP and WebSocket listener |
| `MQTT_PORT` | `1883` | Host port for plain MQTT |
| `MQTT_TCP_PORT` | `1883` | Port inside the worker container. Leave this at 1883 |
| `SUPABASE_URL` | `http://gateway:8000` | Where the API and worker call PostgREST and GoTrue. The Docker network name, not a browser URL |
| `SUPABASE_PUBLIC_URL` | `http://localhost:8080` | Where a browser starts GitHub or Google sign-in. The API proxies `/auth/v1` to GoTrue |
| `FIZZ_AUTH_UPSTREAM` | empty in Compose, `http://auth:9999` in the generated file | GoTrue address for that proxy. Leave it empty when Auth is Supabase Cloud |
| `FIZZ_ALLOW_INSECURE_HTTP` | `1` | Allows `http://` to the Docker gateway and to an OpenAI-compatible server on another host. Set `0` when `SUPABASE_URL` is `https://` |
| `FIZZ_PUBLIC_HOST` | `localhost:8080` | Extra `Host` values the API accepts, comma-separated. `localhost` is already allowed |
| `FIZZ_PUBLIC_SCHEME` | `http` | `http` or `https` for hosts in `FIZZ_PUBLIC_HOST`. Loopback stays `http` unless this is `https` |
| `FIZZ_STREAM_URL` | `http://localhost:8081` | Public base of the worker, no trailing slash. `GET /api/stream` turns it into WebSocket URLs |
| `FIZZ_MQTT_TCP_URL` | `mqtt://localhost:1883` | Advertised plain-MQTT URL. Set it only when clients can open that port |
| `FIZZ_STREAM_ORIGINS` | `http://localhost:8080` | Browser `Origin` values the worker accepts, comma-separated. Loopback is always allowed |
| `FIZZ_API_IMAGE` | `fizzlayer/fizzlayer-api:latest` | API image to pull or build |
| `FIZZ_WORKER_IMAGE` | `fizzlayer/fizzlayer-worker:latest` | Worker image to pull or build |
| `FIZZ_CRON_SECONDS` | `60` | How often the API scans for silence alerts. Minimum 15 |
| `CRON_SECRET` | generated | Bearer token for `GET /api/cron`. The in-process scan does not need a caller. The HTTP route still checks this secret |

### Email, OAuth, and HTTPS

| Variable | Default | What it does |
| --- | --- | --- |
| `MAILER_AUTOCONFIRM` | `true` | `true` creates the account without a confirmation link. Set `false` only after SMTP works |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS` | empty, port `587` | SMTP for confirmation and password reset |
| `SMTP_ADMIN_EMAIL` | `admin@localhost` | From address GoTrue uses |
| `SMTP_SENDER_NAME` | `Fizzlayer` | From name |
| `GITHUB_ENABLED` | `false` | `true` turns on GitHub sign-in. Set `GITHUB_CLIENT_ID` and `GITHUB_CLIENT_SECRET` |
| `GOOGLE_ENABLED` | `false` | `true` turns on Google sign-in. Set `GOOGLE_CLIENT_ID` and `GOOGLE_SECRET` |
| `FIZZ_DOMAIN` | `localhost` | Name the HTTPS proxy serves. Used only with the `tls` profile |
| `FIZZ_ACME_EMAIL` | `internal` | `internal` is a local certificate. Any other value is the email Let's Encrypt associates with `FIZZ_DOMAIN` |

The GitHub or Google callback URL is `${PUBLIC_URL}/auth/v1/callback`.

### Optional product features

Leave these empty. The website still runs.

| Variable | When set |
| --- | --- |
| `OPENAI_BASE_URL` | OpenAI-compatible `/v1` root, such as `http://host.docker.internal:11434/v1` for Ollama on the host. `AI_GATEWAY_BASE_URL` is the same setting. Unset uses `https://ai-gateway.vercel.sh/v1` |
| `OPENAI_API_KEY` | Bearer token for that server. If the base URL is custom and this is empty, the API sends a placeholder bearer for servers that ignore it |
| `OPENAI_MODEL` | Model name. `AI_GATEWAY_MODEL` is the same setting. Default `openai/gpt-5-mini`, which an Ollama server does not have. Set this to the model you pulled |
| `AI_GATEWAY_API_KEY` | Vercel AI Gateway key. Used when no custom base URL is set. `VERCEL_OIDC_TOKEN` is also accepted there |
| `ELEVENLABS_API_KEY` | Voice chat. `ELEVENLABS_VOICE_ID` optional; default George (`JBFqnCBsd6RMkjVDRZzb`) |
| `AGENTPHONE_API_KEY` | Outbound US voice calls. `AGENTPHONE_AGENT_ID` when the account has more than one agent |
| `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `STRIPE_PRICE_TINKERER`, `STRIPE_PRICE_PRO` | Paid checkout. Set all four or none |

The model behind `OPENAI_BASE_URL` must accept JSON mode (`response_format: json_object`). A model that only returns plain text makes chat answer 503.

## Create an account and sign in

In a browser, open <http://localhost:8080/app.html>. Choose **Create account**, enter an email and a password of at least 12 characters, and submit. You land in the dashboard. **Sign in** on the same page uses that email and password later.

The same calls from a terminal, which is what you want when you are checking the install:

```sh
curl -fsS -c cookies.txt -H 'Content-Type: application/json' \
  -d '{"action":"sign_up","email":"you@example.com","password":"choose-a-long-pass"}' \
  http://localhost:8080/api/auth

curl -fsS -c cookies.txt -b cookies.txt -H 'Content-Type: application/json' \
  -d '{"action":"sign_in","email":"you@example.com","password":"choose-a-long-pass"}' \
  http://localhost:8080/api/auth

curl -fsS -b cookies.txt http://localhost:8080/api/me
```

`sign_up` returns `{"ok":true,...}` and sets a `fizz_session` cookie. `"confirm_email":true` means autoconfirm is off and the person must open the email link before `sign_in` works. `sign_in` with a wrong password returns 401 and does not say which field was wrong.

Anyone who can reach the site can create an account. After you have yours, close sign-up in Postgres:

```sh
docker compose -f deploy/docker-compose.yml exec db \
  psql -U postgres -d postgres \
  -c "update public.fizz_instance_settings set sign_up_open = false;"
```

Existing accounts can still sign in.

## Add a sensor and send readings

### From the dashboard

Open **Sensors**, add a sensor, choose a type, and choose **API** (real readings, not a sample stream). The page shows a key once. It starts with `fizz_` and is 69 characters. Copy it. The sensor id is a UUID on the same screen.

### With curl

Use the cookie from sign-up:

```sh
curl -fsS -b cookies.txt -H 'Content-Type: application/json' \
  -d '{"kind":"temperature","name":"Bench","mode":"api"}' \
  http://localhost:8080/api/sensors
```

The JSON has `sensor.id` and `api_key`. Send one reading. `event_id` is your own id; sending the same id again does not create a second row.

```sh
curl -fsS -H "Authorization: Bearer fizz_YOUR_KEY" -H 'Content-Type: application/json' \
  -d '{"sensor_id":"SENSOR_UUID","event_id":"reading-1","metrics":{"temperature_c":21.5}}' \
  http://localhost:8080/api/ingest
```

A 202 response with `"accepted"` is success. Read it back:

```sh
curl -fsS -b cookies.txt \
  "http://localhost:8080/api/readings?sensor_id=SENSOR_UUID&limit=20"
```

`temperature_c` on a temperature sensor is stored with the unit °C. A Custom sensor accepts your own metric names: lowercase letters, digits, and underscores, starting with a letter.

### WebSocket and MQTT

Ask the API where to connect:

```sh
curl -fsS http://localhost:8080/api/stream
```

On this stack that is `"enabled":true`, `websocket_url` `ws://localhost:8081/v1/stream`, `mqtt_ws_url` `ws://localhost:8081/mqtt`, and `mqtt_tcp_url` `mqtt://localhost:1883`.

Plain MQTT uses MQTT 3.1.1. The username is the sensor id. The password is the sensor key. The topic is `fizz/v1/<sensor-id>/readings`. Install the Mosquitto clients (`mosquitto-clients` on Debian and Ubuntu) and publish:

```sh
mosquitto_pub -h 127.0.0.1 -p 1883 \
  -u SENSOR_UUID -P 'fizz_YOUR_KEY' \
  -t 'fizz/v1/SENSOR_UUID/readings' \
  -m '{"event_id":"mqtt-1","metrics":{"temperature_c":23.5}}'
```

There is no output when the broker accepts a QoS 0 publish. Read the sensor again with the readings curl above. `mqtt-1` should be in the JSON.

The device WebSocket is the same pipeline. The first text frame is `{"op":"auth","key":"fizz_YOUR_KEY"}`. The next is `{"op":"reading","sensor_id":"SENSOR_UUID","event_id":"ws-1","metrics":{"temperature_c":22.5}}`. The `fizz` CLI does that for you. Install it, then point it at this machine:

```sh
curl -fsSL http://localhost:8080/install.sh | sh
FIZZ_API=http://localhost:8080 fizz pair
```

`fizz pair` prints a short code and waits. On the **Agents** page (`http://localhost:8080/agents.html`), enter that code. The terminal then asks you to approve. Answer `y` only if the account name it prints is yours. After that:

```sh
fizz send temperature_c 21.5
fizz send --stream temperature_c 22.5
fizz send --mqtt temperature_c 23.5
fizz tail
```

`fizz send` posts to `/api/ingest`. `--stream` uses the WebSocket. `--mqtt` publishes to port 1883. Do not pass both flags. `fizz tail` prints live readings for this device. `fizz run --once` sends CPU temperature, load, memory, and disk where the OS exposes them. The CLI remembers `FIZZ_API` after pairing. Set it again only to override that saved origin.

Subscribe to one sensor's live topic, `fizz/v1/<sensor-id>/live`, with the same username and password. Wildcards are rejected.

## HTTPS with your own domain

The `tls` profile is a Caddy proxy on ports 80 and 443. It forwards the site to the API and `/live` to the worker. Point DNS for the name at this machine, and open both ports. Let's Encrypt completes HTTP-01 on port 80.

In `deploy/.env`:

```sh
COMPOSE_PROFILES=local,tls
FIZZ_DOMAIN=sensors.example.com
FIZZ_ACME_EMAIL=you@example.com
PUBLIC_URL=https://sensors.example.com
SUPABASE_PUBLIC_URL=https://sensors.example.com
FIZZ_PUBLIC_HOST=sensors.example.com
FIZZ_PUBLIC_SCHEME=https
FIZZ_STREAM_URL=https://sensors.example.com/live
FIZZ_STREAM_ORIGINS=https://sensors.example.com
FIZZ_MQTT_TCP_URL=mqtt://sensors.example.com:1883
```

`FIZZ_ACME_EMAIL=internal` (the default) issues a certificate this machine trusts only after you install Caddy's local CA. Use that for a private trial. A real address asks Let's Encrypt for a certificate for `FIZZ_DOMAIN`. Then:

```sh
docker compose -f deploy/docker-compose.yml up -d
curl -fsS https://sensors.example.com/api/status
```

The API on port 8080 is still published for the machine itself. The public site is `https://sensors.example.com`. MQTT stays on 1883. It is not inside TLS. Clients that cannot open 1883 keep using `/api/ingest` or MQTT over the WebSocket from `GET /api/stream`.

For a local look at the proxy without a domain:

```sh
# COMPOSE_PROFILES=local,tls and FIZZ_ACME_EMAIL=internal
docker compose -f deploy/docker-compose.yml up -d
curl -kfsS https://localhost/api/status
```

Browsers should keep using <http://localhost:8080> unless you also set `FIZZ_PUBLIC_SCHEME=https`. The local certificate is not the one a public browser trusts.

## Use Supabase Cloud instead of local Postgres

Create a Supabase project and apply this repo's migrations before the API starts:

```sh
supabase login
supabase link --project-ref YOUR_PROJECT_REF
supabase db push --linked
```

In `deploy/.env`, point the API at that project and do not start the local database:

```sh
COMPOSE_PROFILES=
SUPABASE_URL=https://YOUR_PROJECT_REF.supabase.co
SUPABASE_PUBLIC_URL=https://YOUR_PROJECT_REF.supabase.co
SUPABASE_SERVICE_ROLE_KEY=YOUR_SERVICE_ROLE_KEY
FIZZ_ALLOW_INSECURE_HTTP=0
FIZZ_AUTH_UPSTREAM=
```

Keep `FIZZ_STREAM_URL` on the worker you run (`http://localhost:8081`, or the HTTPS `/live` URL). The worker calls `SUPABASE_URL` itself. Then start only the two app containers:

```sh
docker compose -f deploy/docker-compose.yml up -d api worker
```

Configure Auth (site URL, redirect URLs, SMTP, Google, GitHub) in the Supabase dashboard. The Docker `GITHUB_*` and `SMTP_*` variables are not used in this mode. They configure the bundled GoTrue only.

New migrations are not applied on boot in this mode. Run `supabase db push --linked` when you pull a checkout that adds SQL files.

## Optional features

Restart with `docker compose -f deploy/docker-compose.yml up -d` after editing `deploy/.env`.

**Chat.** With nothing set, a signed-in `POST /api/chat` returns 503 and tells you to set `AI_GATEWAY_API_KEY` or `OPENAI_BASE_URL`. For Ollama on the same machine as Docker:

```sh
OPENAI_BASE_URL=http://host.docker.internal:11434/v1
OPENAI_MODEL=llama3.1
```

The Compose file maps `host.docker.internal` to the host. Pull a model that supports JSON mode, then ask Fizz from the dashboard. `OPENAI_API_KEY` can stay empty for Ollama.

**Voice.** `GET /api/voice` returns `{"available":false}` until `ELEVENLABS_API_KEY` is set. A voice request then returns 503: "Voice chat isn't available yet. You can still type to Fizz."

**Phone calls.** Leave `AGENTPHONE_API_KEY` empty and alerts stay on the dashboard. Nothing is dialed. There is no self-hosted dialer. Calls are US voice only, and the account's plan must include them (Tinkerer, Pro, or Enterprise). Hobbyist does not place calls.

**Stripe.** Leave the four `STRIPE_*` variables empty. `POST /api/billing` returns 503: "Paid plans aren't available on this server." Plans in the database are unchanged.

**SMTP.** Keep `MAILER_AUTOCONFIRM=true` until a message actually arrives. Then set `MAILER_AUTOCONFIRM=false` and the `SMTP_*` variables. Password reset and the confirmation link use `PUBLIC_URL`.

**GitHub and Google.** Create an OAuth app whose callback is `http://localhost:8080/auth/v1/callback` (or your `https://` origin). Set `GITHUB_ENABLED=true` plus the client id and secret, or the `GOOGLE_*` pair. The buttons on the sign-in page use that.

## Upgrade, back up, and read logs

Pull new images and start them. The migrate container runs again. SQL is inside `fizzlayer/fizzlayer-api`, so a new API image is what brings new migrations. The container records applied filenames in `public.fizz_schema_migrations` and skips them next time. An image rollback does not roll back SQL.

```sh
docker compose pull
docker compose up -d
```

From a checkout that uses `deploy/docker-compose.yml`, the same two commands need `-f deploy/docker-compose.yml`, and `git pull` updates the SQL mounted into the migrate container.

Dump the database:

```sh
docker compose -f deploy/docker-compose.yml exec -T db \
  pg_dump -U postgres -d postgres --format=custom > fizzlayer.dump
```

Restore into a stopped API so writers are idle. `--clean` drops objects before recreating them. Try it on a copy before you need it.

```sh
docker compose -f deploy/docker-compose.yml stop api worker rest
docker compose -f deploy/docker-compose.yml exec -T db \
  pg_restore -U postgres -d postgres --clean --if-exists < fizzlayer.dump
docker compose -f deploy/docker-compose.yml up -d
```

Logs:

```sh
docker compose -f deploy/docker-compose.yml logs --tail 100 api
docker compose -f deploy/docker-compose.yml logs --tail 100 worker
docker compose -f deploy/docker-compose.yml ps -a
```

`migrate` showing `Exited (0)` is a finished migration, not a crash. `Exited (1)` is a failed migration. `docker compose -f deploy/docker-compose.yml logs migrate` prints the SQL error.

## Troubleshooting

**`/api/status` says `database` `unavailable` or `unconfigured`.** `unconfigured` means `SUPABASE_URL` or `SUPABASE_SERVICE_ROLE_KEY` is missing. `unavailable` means PostgREST refused the key or the gateway is down. Check `logs rest`, `logs gateway`, and `logs auth`. On a first boot, wait until `logs migrate` says `migrations applied`.

**Migrate prints `auth.uid() did not appear`.** GoTrue did not finish. `logs auth` shows the reason. A fresh volume creates the `auth` schema before GoTrue starts. If you replaced `deploy/.env` without deleting the volume, the passwords no longer match.

**The browser says the host is not configured, or the API returns `invalid_host`.** The `Host` header is not localhost and not in `FIZZ_PUBLIC_HOST`. Set `FIZZ_PUBLIC_HOST` to the host:port you type in the browser, and set `FIZZ_PUBLIC_SCHEME` to `http` or `https` to match.

**Sign-up returns `confirm_email`.** `MAILER_AUTOCONFIRM` is not `true`, or SMTP is required and not set. Turn autoconfirm back on, or finish SMTP.

**Ingest returns 401.** The `Authorization` header must be `Bearer` plus the sensor key from sensor creation. The key is shown once.

**MQTT connection refused.** Port 1883 is the worker. `docker compose ps` should show `0.0.0.0:1883->1883`. `curl -fsS http://localhost:8081/health` should include `"mqtt_tcp":true`.

**`fizz send --stream` and `fizz send --mqtt` both fail.** Pass only one of them. `GET /api/stream` must say `"enabled":true`. If it says `false`, `FIZZ_STREAM_URL` is empty.

**Chat, voice, or billing returns 503.** That feature's key is unset. The message names what to set. Readings and the dashboard do not need it.

**Port already in use.** Change `API_PORT`, `WORKER_PORT`, or `MQTT_PORT`, and change `FIZZ_STREAM_URL`, `FIZZ_MQTT_TCP_URL`, `PUBLIC_URL`, and `FIZZ_PUBLIC_HOST` to the same numbers. `PUBLIC_URL` is what the browser uses.

**Ollama from inside the API container cannot connect.** The URL is `http://host.docker.internal:11434/v1`, and `FIZZ_ALLOW_INSECURE_HTTP` must stay `1`. Ollama must listen on the host, not only on a container network the API cannot see.

## Deploy on Vercel and Supabase

This path keeps the API as Vercel functions. Supabase provides Postgres and Auth. Live sockets still need the Compute worker described at the end of this document. The Docker path above does not use this section.

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
| `FIZZ_STREAM_URL` | For live sockets and MQTT | Public base URL of the `fizz-worker` Compute service, including the gateway path and no trailing slash. Production is `https://bbmdkpzzzalkvthwgsek.supabase.co/compute/v1/fizz-worker`. The path is `/compute/v1/fizz-worker`, not `/workers/v1/`. Empty leaves streaming off; HTTPS ingest is unchanged. Devices should read `GET /api/stream` instead of hardcoding this host |
| `FIZZ_MQTT_TCP_URL` | No | Leave unset on Vercel. Production `GET /api/stream` returns `mqtt_tcp_url: null`. The hosted worker has no plain TCP port 1883. The Docker Compose stack sets `mqtt://localhost:1883` |
| `OPENAI_BASE_URL` | No | OpenAI-compatible `/v1` root, such as `http://127.0.0.1:11434/v1` for Ollama. `AI_GATEWAY_BASE_URL` is the same setting. Unset uses `https://ai-gateway.vercel.sh/v1`. Set `OPENAI_MODEL` or `AI_GATEWAY_MODEL` to a model that accepts JSON mode. `OPENAI_API_KEY` is accepted; a custom base with no key sends a placeholder bearer for servers that ignore it |
| `FIZZ_PUBLIC_HOST` | For a custom Docker hostname | Comma-separated `Host` values the API accepts besides localhost and the Vercel hosts. `FIZZ_PUBLIC_SCHEME=http` serves that host over HTTP |
| `FIZZ_ALLOW_INSECURE_HTTP` | For the Docker gateway | Set to `1` to allow an `http://` Supabase URL that is not loopback, and an `http://` chat base on another host. Leave unset in production |
| `SUPABASE_PUBLIC_URL` | When the browser cannot open `SUPABASE_URL` | Browser OAuth origin. The Docker stack sets this to `http://localhost:8080` while the API calls GoTrue at `http://gateway:8000` |

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

The local `supabase/config.toml` disables Google and GitHub sign-in and seeding, and uses `http://localhost:3000` for Auth redirects. To test Google sign-in locally, set `SUPABASE_AUTH_EXTERNAL_GOOGLE_CLIENT_ID` and `SUPABASE_AUTH_EXTERNAL_GOOGLE_SECRET`, then enable `[auth.external.google]`. GitHub works the same way with `SUPABASE_AUTH_EXTERNAL_GITHUB_CLIENT_ID`, `SUPABASE_AUTH_EXTERNAL_GITHUB_SECRET`, and `[auth.external.github]`, using a separate GitHub OAuth App whose callback URL is `http://127.0.0.1:54321/auth/v1/callback`. The app accepts HTTP Supabase URLs on loopback. Set `FIZZ_ALLOW_INSECURE_HTTP=1` to allow HTTP to another host, which the Docker Compose gateway uses. Production Supabase connections leave that unset and use HTTPS.

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
| Region | Supabase's alpha announcement listed us-west-2 only. The Fizz project (`bbmdkpzzzalkvthwgsek`) is in us-east-1 and already has Compute enabled, so that announcement does not block this deploy |
| Price | The alpha is free and is for evaluation, not production. It may change or end. No general price has been published for this service. That is separate from Postgres [compute hours](https://supabase.com/docs/guides/platform/manage-your-usage/compute), which bill the database instance |
| Lifetime | No wall-clock limit of the kind Edge Functions have (400 seconds). A service can still be restarted at any time, so readings live in Postgres |
| Idle | A public service suspends when idle and is described as resuming in under a second. Open sockets keep it awake; clients reconnect after a suspend |
| Missing | No autoscaling, GPU, or persistent disk. Agent sandboxes are not in the alpha. Every service receives all of the project's secrets |
| URL | Production is served at `https://bbmdkpzzzalkvthwgsek.supabase.co/compute/v1/fizz-worker`. Confirm the base with `GET /api/stream` (strip `wss://` back to `https://` and remove `/v1/stream`). Do not use `/workers/v1/` |

The public URL is HTTPS. It does not publish TCP port 1883, and production `mqtt_tcp_url` is null. MQTT clients use WebSocket (`wss://…/compute/v1/fizz-worker/mqtt`, subprotocol `mqtt`). ESP-IDF can do that with `MQTT_TRANSPORT_OVER_WSS`. Arduino `PubSubClient` and Home Assistant's MQTT integration speak TCP, so on the hosted service they should use `POST /api/ingest` or the Fizzlayer Home Assistant integration. A self-hosted copy of this image can set `MQTT_TCP_PORT=1883`. Advertise that address as `FIZZ_MQTT_TCP_URL` only when clients can reach it. The Docker Compose stack publishes port 1883 and sets `FIZZ_MQTT_TCP_URL=mqtt://localhost:1883`.

### Deploy the worker

Do this in the Supabase project you mean to use. Nothing in this repository deploys it for you.

1. Apply `supabase/migrations/20261111000000_live_stream.sql` with the other migrations (`supabase db push`).
2. On Fizz (`bbmdkpzzzalkvthwgsek`) Compute is already enabled, including from us-east-1. On another project, confirm Compute is enabled before pushing. The alpha announcement listed us-west-2 only; that list is not the gate for Fizz.
3. Put `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` in the project's secrets. Compute injects project secrets into the service. The worker will not store readings without them. Add `FIZZ_STREAM_ORIGINS` only if the browser origin is not `https://fizzlayer.com` or `https://www.fizzlayer.com` (comma-separated). Loopback origins are always allowed.
4. From the repo root, with Supabase CLI 2.120.0 or later:

   ```sh
   supabase compute push --project-ref YOUR_PROJECT_REF
   ```

   The image is `supabase/compute/fizz-worker`. It listens on `PORT` (the platform sets this; locally it defaults to 8080). `GET /health` returns `{"service":"fizz-worker","status":"ok"}`.
5. Copy the public URL from the Compute page. On Vercel, set `FIZZ_STREAM_URL` to that base with no trailing slash. Production is `https://bbmdkpzzzalkvthwgsek.supabase.co/compute/v1/fizz-worker`. Redeploy the API. `GET /api/stream` should then return `"enabled": true` and `wss://` URLs under `/compute/v1/fizz-worker`.
6. The site's Content-Security-Policy allows `https://*.supabase.co` and `wss://*.supabase.co`. If the public URL is on another host, add that host to `connect-src` in `vercel.json`.

A streamed reading still creates alert rows in the database. The worker does not dial AgentPhone. `/api/cron` places queued calls, so a call that follows a socket or MQTT reading can wait until the next cron run instead of leaving on the ingest request itself.

Locally, without Compute:

```sh
SUPABASE_URL=http://127.0.0.1:54321 SUPABASE_SERVICE_ROLE_KEY=... \
  cargo run --manifest-path supabase/compute/fizz-worker/Cargo.toml
FIZZ_STREAM_URL=http://127.0.0.1:8080 scripts/dev.sh --local-db
```

`MQTT_TCP_PORT=1883` also opens a plain MQTT listener on that port. The image runs as uid 65532 and needs outbound HTTPS to the Supabase API.
