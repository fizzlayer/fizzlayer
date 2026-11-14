# Frontend

The pages under `public/` are static HTML and CSS. Some of their scripts are Gleam compiled to JavaScript. The rest are still the original JavaScript files. Both are loaded by the same `<script src>` tags.

The six Gleam bundles are not in git. `scripts/build-frontend.sh` installs Gleam 1.19.2 and writes them into `public/` before a server starts.

## Stack

[Lustre](https://hexdocs.pm/lustre/) is the Gleam frontend framework. It fits the status page, because that page already replaces its own list from API data. The status view is a Lustre application mounted on `#status-app`. The wrapper uses `display: contents`, so it does not change the layout.

The shared modules are ordinary Gleam, not a second framework. Sensor categories, analytics URLs, the mobile menu, and the contact forms are pure functions with a thin JavaScript edge that talks to the DOM. That keeps `window.fizzKinds` the same object the remaining JavaScript already calls, and it keeps the Enterprise and gateway forms as the HTML they already are.

Gleam's conventions are the style for this package: `gleam format`, qualified function imports, `Result` for failures, and no panics in the library functions.

## Build

From the repository root:

```sh
scripts/build-frontend.sh
```

The script picks the pinned Gleam 1.19.2 binary for the machine (`x86_64` or `aarch64`), compiles `frontend/`, and bundles six classic scripts:

| Script | Gleam module | What it does |
| --- | --- | --- |
| `public/sensor-kinds.js` | `kind` | Sensor names, icons, scales, and reading text. Exposes `window.fizzKinds`. |
| `public/analytics.js` | `analytics` | Strips query strings and fragments from cookieless page views. |
| `public/nav.js` | `nav` | Opens and closes the marketing menu. |
| `public/status.js` | `status` | Lustre status page. |
| `public/enterprise.js` | `contact` | Enterprise contact form. |
| `public/gateway-beta.js` | `contact` | Gateway beta list form. |

Those paths are gitignored. Vercel runs `bash scripts/build-frontend.sh` as the project `buildCommand` in `vercel.json`, for preview and production, then serves `public/` as before. The API image (`deploy/Dockerfile.api`) runs the same script and copies the resulting `public/` into the container. `scripts/dev.sh` runs the build when any of the six files is missing.

Check formatting, then run the tests:

```sh
cd frontend
gleam format --check
gleam test
```

`gleam.toml` sets the JavaScript target, so `gleam build` and `gleam test` use Node. The tests cover kind formatting and ordering, relative-time buckets, menu transitions, contact validation, and the status rows and view. CI builds the bundles and runs `node --check` on them.

## Still JavaScript

These stay as they are until a later change. Each one should move with the page that owns it, keeping `window.fizzKinds` as the boundary.

- Account and dashboard: `app.js`, `dashboard.js`, `sensor-detail.js`, `live.js`, `voice-chat.js`, `voice-clips.js`, `passkey.js`, `settings.js`
- Sensors and devices: `sensors.js`, `home-assistant.js`, `device-pairing.js`, `ha.js`, `agents.js`
- Demo: `demo.js`
- Docs and marketing leftovers: `docs.js`, `webmcp.js`, `phone.js`
- `landing.js` and `auth-redirect.js` are not referenced by any page

Suggested order for the rest:

1. `docs.js` (copy buttons and the section highlight) and `phone.js`.
2. `sensors.js` with `device-pairing.js` and `home-assistant.js`, then `ha.js`.
3. `agents.js`.
4. `demo.js`, which already depends only on `window.fizzKinds` and the page.
5. The signed-in workspace (`app.js`, `dashboard.js`, `sensor-detail.js`, `live.js`, voice, passkeys, settings). This is the large piece. `src/agent.rs` checks that `public/dashboard.js` still contains its WebMCP strings, so that file has to keep those sentences.
6. `webmcp.js` last. Discovery cards are generated from it by `scripts/agent-cards.mjs`.
