# Fizzlayer for Home Assistant

Push Home Assistant `sensor` and `binary_sensor` entities to [Fizzlayer](https://fizzlayer.com). Home Assistant sends the readings out, so the install does not need to be reachable from the internet.

## Install with HACS

This integration lives in the Fizzlayer repository under `custom_components/fizzlayer`. A separate repository is not required.

1. In HACS, choose **Integrations**, then the menu, then **Custom repositories**.
2. Add this repository (`https://github.com/fizzlayer/fizzlayer`) as category **Integration**.
3. Install **Fizzlayer** and restart Home Assistant.

HACS downloads the whole repository. That is the tradeoff of shipping the integration beside the Fizzlayer app.

You can also copy `custom_components/fizzlayer` into your Home Assistant `config/custom_components` directory and restart.

## Connect

On the Fizzlayer Sensors page, choose **Connect Home Assistant**. That opens My Home Assistant, which starts this integration. Home Assistant shows a 6-digit code. Type that code on the Fizzlayer page. The page also shows this install's name and version. You do not copy a device token, and a code from a message is not accepted unless it is the one on this screen.

The first time, My Home Assistant asks you to confirm your instance URL. If the browser blocks the window, use the link in the Home Assistant dialog.

Temperature, humidity, power, energy, battery, door, and leak sensors start selected. Each entity counts toward the Fizzlayer device limit.

Self-hosted Fizzlayer: enable **Advanced Mode** in your Home Assistant profile before adding the integration, and enter your server URL. `http://` is accepted only for localhost.

## What it sends

State changes are batched and throttled (at most one change per entity every 10 seconds, flushed together). About every 30 seconds it sends the last value again so a Fizzlayer silence alert can tell a quiet sensor from one that stopped reporting. If Fizzlayer cannot be reached, readings stay queued and are retried. If the connection is revoked, the integration stops and asks to be linked again.

Remove the integration, or choose **Revoke** on the Fizzlayer Sensors page, to invalidate the key.

## Tests

From the repository root, with `pytest` and `pytest-homeassistant-custom-component` installed:

```sh
pytest tests/homeassistant
```
