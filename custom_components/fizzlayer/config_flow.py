"""Config flow for linking a Home Assistant install to Fizzlayer.

My Home Assistant can only start the flow (`domain=fizzlayer`). The flow then opens
Fizzlayer with a random state. The signed-in owner allows it there, and this flow
polls until the device key is ready. The key is stored on the config entry and is
not shown.
"""

from __future__ import annotations

import asyncio
import logging
import secrets
from typing import Any

import voluptuous as vol

from homeassistant.config_entries import SOURCE_REAUTH, ConfigEntry, ConfigFlow, OptionsFlow
from homeassistant.data_entry_flow import FlowResultType
from homeassistant.core import HomeAssistant, callback
from homeassistant.helpers import config_validation as cv

from .client import FizzlayerConnectionError, error_code, post_json
from .const import DEFAULT_BASE_URL, DEFAULT_DEVICE_CLASSES, DOMAIN, POLL_ATTEMPTS, POLL_INTERVAL
from .mapping import normalize_base_url, plan_entity

_LOGGER = logging.getLogger(__name__)


def shareable_states(hass: HomeAssistant) -> list[dict[str, Any]]:
    """sensor and binary_sensor entities the user can choose from."""
    found = []
    for state in hass.states.async_all(("sensor", "binary_sensor")):
        found.append(
            {
                "entity_id": state.entity_id,
                "name": state.name or state.entity_id,
                "device_class": state.attributes.get("device_class"),
                "unit": state.attributes.get("unit_of_measurement"),
            }
        )
    found.sort(key=lambda item: item["name"].lower())
    return found


def default_selection(entities: list[dict[str, Any]], remaining: int | None) -> list[str]:
    """Pre-check closet and homelab sensors, without exceeding the plan."""
    chosen = [
        item["entity_id"]
        for item in entities
        if (item.get("device_class") or "") in DEFAULT_DEVICE_CLASSES
    ]
    if remaining is None:
        return chosen
    return chosen[: max(remaining, 0)]


def _remaining(devices_used: Any, device_limit: Any) -> int | None:
    if device_limit is None:
        return None
    try:
        return max(int(device_limit) - int(devices_used or 0), 0)
    except (TypeError, ValueError):
        return None


class FizzlayerConfigFlow(ConfigFlow, domain=DOMAIN):
    """Link Fizzlayer, then choose which entities to share."""

    VERSION = 1

    def __init__(self) -> None:
        self._base_url = DEFAULT_BASE_URL
        self._state: str | None = None
        self._link: dict[str, Any] | None = None
        self._poll_task: asyncio.Task | None = None

    @staticmethod
    @callback
    def async_get_options_flow(config_entry: ConfigEntry) -> FizzlayerOptionsFlow:
        return FizzlayerOptionsFlow(config_entry)

    async def async_step_user(self, user_input: dict[str, Any] | None = None) -> dict[str, Any]:
        """Cloud installs start immediately. Advanced Mode asks for a self-hosted URL."""
        if self.show_advanced_options:
            return await self.async_step_advanced()
        self._base_url = DEFAULT_BASE_URL
        return await self.async_step_link()

    async def async_step_reauth(self, entry_data: dict[str, Any]) -> dict[str, Any]:
        self._base_url = entry_data.get("base_url") or DEFAULT_BASE_URL
        return await self.async_step_reauth_confirm()

    async def async_step_reauth_confirm(self, user_input: dict[str, Any] | None = None) -> dict[str, Any]:
        if user_input is None:
            return self.async_show_form(step_id="reauth_confirm", data_schema=vol.Schema({}))
        return await self.async_step_link()

    async def async_step_advanced(self, user_input: dict[str, Any] | None = None) -> dict[str, Any]:
        errors: dict[str, str] = {}
        if user_input is not None:
            try:
                self._base_url = normalize_base_url(user_input["base_url"])
            except ValueError:
                errors["base_url"] = "invalid_url"
            else:
                code = (user_input.get("code") or "").strip()
                if code:
                    return await self._exchange_code(code)
                return await self.async_step_link()
        return self.async_show_form(
            step_id="advanced",
            data_schema=vol.Schema(
                {
                    vol.Required("base_url", default=DEFAULT_BASE_URL): str,
                    vol.Optional("code"): str,
                }
            ),
            errors=errors,
        )

    async def async_step_link(self, user_input: dict[str, Any] | None = None) -> dict[str, Any]:
        if user_input is None:
            self._state = secrets.token_hex(32)
            self._confirm_code = f"{secrets.randbelow(1_000_000):06d}"
            url = f"{self._base_url}/ha.html?state={self._state}"
            self._poll_task = self.hass.async_create_task(self._poll())
            return self.async_external_step(
                step_id="link",
                url=url,
                description_placeholders={"url": url, "code": self._confirm_code},
            )
        # Home Assistant only allows an external step to move to "external step done".
        # The following step (the entity picker, or an abort) runs after that.
        failed = user_input.get("error")
        if not failed:
            self._link = user_input
        else:
            self._abort_reason = str(failed)
        if self.cur_step and self.cur_step.get("type") == FlowResultType.EXTERNAL_STEP:
            return self.async_external_step_done(
                next_step_id="link_failed" if failed else "entities"
            )
        if failed:
            return self.async_abort(reason=self._abort_reason)
        return await self.async_step_entities()

    async def async_step_link_failed(self, user_input: dict[str, Any] | None = None) -> dict[str, Any]:
        return self.async_abort(reason=getattr(self, "_abort_reason", "timeout"))

    async def _poll(self) -> None:
        assert self._state is not None
        flow_id = self.flow_id
        for _ in range(POLL_ATTEMPTS):
            await asyncio.sleep(POLL_INTERVAL)
            try:
                current = self.hass.config_entries.flow.async_get(flow_id)
            except (KeyError, AttributeError, LookupError):
                return
            if current is None:
                return
            try:
                data = await post_json(
                    self.hass,
                    f"{self._base_url}/api/devices",
                    {
                        "action": "ha_exchange",
                        "state": self._state,
                        "confirm_code": self._confirm_code,
                        "name": getattr(self.hass.config, "location_name", None) or "Home Assistant",
                        "ha_version": getattr(self.hass.config, "version", None),
                    },
                )
            except FizzlayerConnectionError:
                continue
            if data.get("api_key") and data.get("connection_id"):
                self.hass.async_create_task(
                    self.hass.config_entries.flow.async_configure(
                        flow_id,
                        {
                            "api_key": data["api_key"],
                            "connection_id": data["connection_id"],
                            "devices_used": data.get("devices_used"),
                            "device_limit": data.get("device_limit"),
                        },
                    )
                )
                return
            code = error_code(data)
            if code in {"expired", "already_linked", "rate_limited"}:
                self.hass.async_create_task(
                    self.hass.config_entries.flow.async_configure(flow_id, {"error": code})
                )
                return
        self.hass.async_create_task(
            self.hass.config_entries.flow.async_configure(flow_id, {"error": "timeout"})
        )

    async def _exchange_code(self, code: str) -> dict[str, Any]:
        try:
            data = await post_json(
                self.hass,
                f"{self._base_url}/api/devices",
                {"action": "ha_exchange_code", "code": code},
            )
        except FizzlayerConnectionError:
            return self.async_abort(reason="cannot_connect")
        if not data.get("api_key"):
            return self.async_show_form(
                step_id="advanced",
                data_schema=vol.Schema(
                    {
                        vol.Required("base_url", default=self._base_url): str,
                        vol.Optional("code", default=code): str,
                    }
                ),
                errors={"code": "invalid_code"},
            )
        return await self.async_step_link(
            {
                "api_key": data["api_key"],
                "connection_id": data["connection_id"],
                "devices_used": data.get("devices_used"),
                "device_limit": data.get("device_limit"),
            }
        )

    async def async_step_entities(self, user_input: dict[str, Any] | None = None) -> dict[str, Any]:
        entities = shareable_states(self.hass)
        if not entities:
            return self.async_abort(reason="no_entities")
        assert self._link is not None
        await self.async_set_unique_id(str(self._link["connection_id"]))
        self._abort_if_unique_id_configured()
        remaining = _remaining(self._link.get("devices_used"), self._link.get("device_limit"))
        errors: dict[str, str] = {}
        if user_input is not None:
            selected = list(user_input.get("entities") or [])
            try:
                synced = await _sync(self.hass, self._base_url, self._link["api_key"], entities, selected, True)
            except FizzlayerConnectionError:
                errors["base"] = "cannot_connect"
            else:
                code = error_code(synced)
                if code == "unauthorized":
                    return self.async_abort(reason="invalid_auth")
                if code:
                    errors["base"] = "cannot_connect"
                elif not synced.get("sensors") and any(
                    item.get("error") == "device_limit" for item in synced.get("skipped") or []
                ):
                    errors["base"] = "device_limit"
                else:
                    return self._finish(selected, synced)
        options = {item["entity_id"]: _label(item) for item in entities}
        return self.async_show_form(
            step_id="entities",
            data_schema=vol.Schema(
                {
                    vol.Required(
                        "entities",
                        default=default_selection(entities, remaining),
                    ): cv.multi_select(options)
                }
            ),
            description_placeholders={
                "remaining": "unlimited" if remaining is None else str(remaining),
            },
            errors=errors,
        )

    def _finish(self, selected: list[str], synced: dict) -> dict[str, Any]:
        sensors = {
            item["entity_id"]: {
                "sensor_id": item["sensor_id"],
                "metric": item["metric"],
                "boolean": bool(item.get("boolean")),
                "device_class": item.get("device_class"),
                "unit": item.get("unit"),
            }
            for item in synced.get("sensors") or []
        }
        shared_ids = list(sensors)
        data = {
            "base_url": self._base_url,
            "api_key": self._link["api_key"],
            "connection_id": self._link["connection_id"],
        }
        options = {"entities": shared_ids, "sensors": sensors}
        if self.source == SOURCE_REAUTH:
            return self.async_update_reload_and_abort(
                self._get_reauth_entry(),
                data_updates=data,
                options=options,
            )
        title = "Home Assistant"
        skipped = [item for item in synced.get("skipped") or [] if item.get("error") == "device_limit"]
        if skipped:
            _LOGGER.info(
                "Fizzlayer stored %s entities; %s were over the plan limit",
                len(sensors),
                len(skipped),
            )
        return self.async_create_entry(title=title, data=data, options=options)


class FizzlayerOptionsFlow(OptionsFlow):
    """Change which entities an existing connection shares."""

    def __init__(self, config_entry: ConfigEntry) -> None:
        self._config_entry = config_entry

    async def async_step_init(self, user_input: dict[str, Any] | None = None) -> dict[str, Any]:
        entry = self._config_entry
        entities = shareable_states(self.hass)
        if not entities:
            return self.async_abort(reason="no_entities")
        current = list(entry.options.get("entities") or [])
        errors: dict[str, str] = {}
        if user_input is not None:
            selected = list(user_input.get("entities") or [])
            try:
                synced = await _sync(
                    self.hass,
                    entry.data["base_url"],
                    entry.data["api_key"],
                    entities,
                    selected,
                    True,
                )
            except FizzlayerConnectionError:
                errors["base"] = "cannot_connect"
            else:
                if error_code(synced) == "unauthorized":
                    return self.async_abort(reason="invalid_auth")
                if error_code(synced):
                    errors["base"] = "cannot_connect"
                else:
                    sensors = {
                        item["entity_id"]: {
                            "sensor_id": item["sensor_id"],
                            "metric": item["metric"],
                            "boolean": bool(item.get("boolean")),
                            "device_class": item.get("device_class"),
                            "unit": item.get("unit"),
                        }
                        for item in synced.get("sensors") or []
                    }
                    return self.async_create_entry(
                        title="",
                        data={"entities": list(sensors), "sensors": sensors},
                    )
        options = {item["entity_id"]: _label(item) for item in entities}
        return self.async_show_form(
            step_id="init",
            data_schema=vol.Schema(
                {vol.Required("entities", default=current): cv.multi_select(options)}
            ),
            errors=errors,
        )


def _label(item: dict[str, Any]) -> str:
    device = item.get("device_class")
    suffix = f" ({device})" if device else ""
    return f"{item['name']}{suffix}"


async def _sync(
    hass: HomeAssistant,
    base_url: str,
    api_key: str,
    entities: list[dict[str, Any]],
    selected: list[str],
    replace: bool,
) -> dict:
    by_id = {item["entity_id"]: item for item in entities}
    payload = []
    for entity_id in selected:
        item = by_id.get(entity_id)
        if item is None:
            continue
        plan = plan_entity(entity_id, item.get("device_class"), item.get("unit"))
        if plan is None:
            continue
        # The server maps a device class to a canonical unit. Omit the class when
        # this install could not convert into that unit, so the value is not mislabeled.
        payload.append(
            {
                "entity_id": entity_id,
                "name": item["name"][:80],
                "device_class": plan.device_class if plan.canonical else None,
                "unit": None if plan.canonical else plan.unit,
            }
        )
    version = getattr(getattr(hass, "config", None), "version", None)
    body: dict[str, Any] = {
        "action": "ha_sync",
        "entities": payload,
        "replace": replace,
        "name": "Home Assistant",
    }
    if isinstance(version, str) and version:
        body["ha_version"] = version[:40]
    return await post_json(hass, f"{base_url}/api/devices", body, api_key=api_key)


async def sync_selected(
    hass: HomeAssistant,
    base_url: str,
    api_key: str,
    entity_ids: list[str],
    replace: bool,
) -> dict:
    """Sync the entities currently selected, using their live device class and unit."""
    entities = [item for item in shareable_states(hass) if item["entity_id"] in set(entity_ids)]
    # Keep ids that are not loaded right now out of a replace, so a restart
    # does not delete a sensor whose entity has not been set up yet.
    if replace:
        entities = shareable_states(hass)
        entity_ids = [item["entity_id"] for item in entities if item["entity_id"] in set(entity_ids)]
    version = getattr(hass.config, "version", None)
    by_id = {item["entity_id"]: item for item in entities}
    payload = []
    for entity_id in entity_ids:
        item = by_id.get(entity_id)
        if item is None:
            continue
        plan = plan_entity(entity_id, item.get("device_class"), item.get("unit"))
        if plan is None:
            continue
        payload.append(
            {
                "entity_id": entity_id,
                "name": str(item["name"])[:80],
                "device_class": plan.device_class if plan.canonical else None,
                "unit": None if plan.canonical else plan.unit,
            }
        )
    body = {
        "action": "ha_sync",
        "entities": payload,
        "replace": replace,
        "name": "Home Assistant",
    }
    if isinstance(version, str) and version:
        body["ha_version"] = version[:40]
    return await post_json(hass, f"{base_url}/api/devices", body, api_key=api_key)
