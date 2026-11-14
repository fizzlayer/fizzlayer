# Fizzlayer for Home Assistant

Push Home Assistant `sensor` and `binary_sensor` entities to [Fizzlayer](https://fizzlayer.com). Home Assistant sends the readings out, so the install does not need to be reachable from the internet.

Install this integration before adding it. Without the custom component, Home Assistant shows "This integration does not support configuration via the UI."

## 1. Install via HACS

[![Install via HACS](https://my.home-assistant.io/badges/hacs_repository.svg)](https://my.home-assistant.io/redirect/hacs_repository/?owner=fizzlayer&repository=fizzlayer&category=integration)

This integration lives in the Fizzlayer repository under `custom_components/fizzlayer`. A separate repository is not required. HACS allows one integration in `custom_components/`, and this repository has only `fizzlayer`.

`hacs.json` is at the repository root:

- `content_in_root` is `false` because the integration files are in `custom_components/fizzlayer`, not the repository root. Setting it to `true` would make HACS look in the wrong place.
- `zip_release` is not set. HACS then downloads the repository archive and copies `custom_components/fizzlayer`. A zip release would need a zip of the integration files attached to every GitHub release, which this repository does not publish from CI.
- `render_readme` is `true`, so HACS shows the repository README.

HACS versions the integration from a GitHub **release**, not from a git tag alone. Until a release is published, HACS installs the default branch, or an older release if one is already marked latest. Publish a release whose tag matches `manifest.json` (currently `1.2.0`, for example `v1.2.0`) when you want HACS to offer that version. The version on the code screen and under Settings, Devices & services is the installed copy.

**Restart Home Assistant** after HACS finishes installing.

You can also add the repository by hand in HACS: Integrations, then the menu, then Custom repositories, `https://github.com/fizzlayer/fizzlayer`, category Integration.

## 2. Add the integration

[![Add integration](https://my.home-assistant.io/badges/config_flow_start.svg)](https://my.home-assistant.io/redirect/config_flow_start?domain=fizzlayer)

Do this only after the restart. Home Assistant shows a 6-digit code in the dialog title and in the pairing-code field. Open the Allow page from the link in that dialog and type the code there. The page also shows this install's name and version. You do not copy a device token, and a code from a message is not accepted unless it is the one on this screen.

The first time, My Home Assistant asks you to confirm your instance URL. If the browser blocks the window, use the link in the Home Assistant dialog.

Temperature, humidity, power, energy, battery, door, and leak sensors start selected. Each entity counts toward the Fizzlayer device limit.

Add integration shows the 6-digit code in the dialog title and in the pairing-code field, including when Advanced Mode is on. The link in that dialog opens the Allow page. The server on that screen is fizzlayer.com. The same screen shows the integration version from `manifest.json`.

## Install without HACS

Copy `custom_components/fizzlayer` into the Home Assistant config `custom_components` directory, then restart. `/config` is that directory's parent on Home Assistant OS, Supervised, and the official container.

```sh
git clone --depth 1 https://github.com/fizzlayer/fizzlayer.git
mkdir -p /config/custom_components
cp -a fizzlayer/custom_components/fizzlayer /config/custom_components/
```

Docker, with the container named `homeassistant`:

```sh
git clone --depth 1 https://github.com/fizzlayer/fizzlayer.git
docker exec homeassistant mkdir -p /config/custom_components
docker cp fizzlayer/custom_components/fizzlayer homeassistant:/config/custom_components/fizzlayer
docker restart homeassistant
```

If the config directory is not `/config`, copy the folder into that directory's `custom_components` instead. Then use Add integration above.

## What it sends

State changes are batched and throttled (at most one change per entity every 10 seconds, flushed together). About every 30 seconds it sends the last value again so a Fizzlayer silence alert can tell a quiet sensor from one that stopped reporting. If Fizzlayer cannot be reached, readings stay queued and are retried. If the connection is revoked, the integration stops and asks to be linked again.

Remove the integration, or choose **Revoke** on the Fizzlayer Sensors page, to invalidate the key.

## Tests

From the repository root, with `pytest` and `pytest-homeassistant-custom-component` installed:

```sh
pytest tests/homeassistant
```
