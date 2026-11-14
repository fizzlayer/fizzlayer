# Fizzlayer Gleam app

A Lustre single-page app served at `/app`. It does not replace the current site. `/app.html`, the marketing pages, and the Rust API stay where they are.

Versions locked for this skeleton: **Gleam 1.19.2**, **Lustre 5.7.1**, **modem 2.1.3**, **lustre_dev_tools 2.4.0**, **@supabase/supabase-js 2.119.0**.

## What it does

- **Email magic link** and **GitHub** sign-in go through a thin `supabase-js` wrapper (`src/supabase_ffi.mjs`). Magic links only sign in an existing account (`shouldCreateUser: false`), so they do not skip the API's sign-up limits. GitHub uses the same Supabase provider as the current site.
- After Supabase returns an access token, the app `POST`s it to `/api/auth` with `{"action":"link"}`. The Rust API verifies that token and sets the HttpOnly `fizz_session` cookie. The browser never had a Supabase key before this app; the current pages still sign in only through `/api/auth`.
- **Workspace** (`/app/workspace`) calls `GET /api/me` with `credentials: "same-origin"` and renders the JSON. That route only reads the signed-in customer. `GET /api/sensors` is not used here because it also ticks simulated sensors.
- **Sign out** clears the supabase-js session in this browser (`scope: "local"`) and then `DELETE /api/session`. That cookie is shared with `/app.html`, so signing out here signs out of the current app too.
- An existing `fizz_session` cookie (from `/app.html`) is enough to open the workspace. You do not have to sign in again.

Passkeys and Google are still only on `/app.html`. A verified passkey factor can make the link exchange return `mfa_required`; use the current app in that case.

## Routes

| URL | Page |
| --- | --- |
| `/app` | Sign in |
| `/app/workspace` | `GET /api/me` |
| anything else under `/app` | Not found, inside the SPA |

Links to the existing site (`/index.html`, `/app.html`, `/docs.html`, …) are full page loads. modem intercepts same-origin links, and those paths are handed back to the browser.

## Develop

From the repo root, with the API on port 3000 (`scripts/dev.sh`):

```sh
# writes app/assets/config.json from SUPABASE_URL and SUPABASE_ANON_KEY
python3 scripts/write_spa_config.py app/assets/config.json
cd app
npm ci
gleam run -m lustre/dev start
```

The dev server is `http://127.0.0.1:1234`. `/` is the sign-in screen there. `/api/*` is proxied to `http://localhost:3000/api`. Add `http://127.0.0.1:1234/app` to the Supabase redirect allow list (already listed in `supabase/config.toml` for local).

Production-shaped files:

```sh
bash scripts/build-spa.sh
node scripts/preview-spa.mjs
```

Open `http://127.0.0.1:4173/app`. The preview server uses the same rule as Vercel: a real file is served, and only a missing `/app/...` path falls back to the SPA shell.

## Build

`scripts/build-spa.sh` installs Gleam, OTP, and rebar3 when they are not on `PATH`, runs `gleam run -m lustre/dev build --minify`, and copies `app/dist` to `public/app`. `vercel.json` sets that script as the build command. It does not compile the Rust functions; Vercel still builds `api/*.rs` itself.

The generated script tag is rewritten to `/app/fizz_spa.js` so it does not replace `/app.js`.

Public config is `public/app/config.json`:

```json
{ "supabaseUrl": "https://PROJECT.supabase.co", "supabaseAnonKey": "…" }
```

The anon key and the `sb_publishable_…` key are public. The service-role key is refused at build time and again in the client. Leave both values empty and the shell still builds; sign-in stays disabled until they are set.

## Vercel rewrites

Only these were added, plus `Cache-Control: no-store` on `/app/config.json`:

- `/app` → `/app/index.html`
- `/app/` → `/app/index.html`
- `/app/:path*` → `/app/index.html`

On Vercel, a file that exists is served before rewrites, so `/app/fizz_spa.js`, `/app/spa.css`, and `/app/config.json` are files. The fallback does not match `/api/*`, `/install.sh`, `/.well-known/*`, `/ha.html`, `/app.html`, `/app.js`, or the other pages in `public/`. Redirects in `vercel.json` were not changed.

## Checks

```sh
cd app && gleam format --check && gleam test
bash scripts/build-spa.sh
```

`gleam test` includes the rewrite check against `vercel.json`.

## Before this works on fizzlayer.com

1. Set `SUPABASE_URL` and `SUPABASE_ANON_KEY` (or `SUPABASE_PUBLISHABLE_KEY`) on the Vercel project for Production, Preview, and Development. They are read at **build** time. Do not put the service-role key in either variable.
2. In Supabase Auth → URL configuration, allow `https://fizzlayer.com/app` and the same path on each preview origin you use. The GitHub provider callback stays Supabase's `/auth/v1/callback`.
3. Email magic links use the existing email provider. GitHub has to be enabled, which the current site already checks via `GET /api/auth?providers`. The button is hidden when GitHub is off.
4. Restart local Supabase after pulling so `additional_redirect_urls` picks up `/app`.
