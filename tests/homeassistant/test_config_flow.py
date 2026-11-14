"""Config flow: My Home Assistant starts the link, then the owner picks entities."""

from unittest.mock import patch

import pytest

pytest.importorskip("homeassistant")
pytest.importorskip("pytest_homeassistant_custom_component")

from homeassistant.data_entry_flow import FlowResultType

from custom_components.fizzlayer.const import DOMAIN
from custom_components.fizzlayer.mapping import plan_entity


def _linked(limit=3, used=0):
    return {
        "api_key": "fizz_" + "ab" * 32,
        "connection_id": "4f1c7e2a-9b3d-4c5e-8f6a-1b2c3d4e5f60",
        "devices_used": used,
        "device_limit": limit,
        "_status": 200,
    }


async def test_cloud_link_polls_then_preselects_closet_sensors(hass, enable_custom_integrations):
    hass.states.async_set(
        "sensor.rack_temp",
        "21",
        {
            "device_class": "temperature",
            "unit_of_measurement": "°C",
            "friendly_name": "Rack temperature",
        },
    )
    hass.states.async_set(
        "binary_sensor.closet_door",
        "off",
        {"device_class": "door", "friendly_name": "Closet door"},
    )
    hass.states.async_set(
        "sensor.lounge_lux",
        "10",
        {"device_class": "illuminance", "friendly_name": "Lounge light"},
    )
    synced = {
        "_status": 200,
        "sensors": [
            {
                "entity_id": "sensor.rack_temp",
                "sensor_id": "11111111-1111-4111-8111-111111111111",
                "metric": "temperature_c",
                "boolean": False,
                "device_class": "temperature",
                "unit": "°C",
            },
            {
                "entity_id": "binary_sensor.closet_door",
                "sensor_id": "22222222-2222-4222-8222-222222222222",
                "metric": "open",
                "boolean": True,
                "device_class": "door",
                "unit": None,
            },
        ],
        "skipped": [],
    }

    expected = {}

    async def fake_post(_hass, url, payload, api_key=None, timeout=30):
        if payload.get("action") == "ha_exchange":
            assert payload["state"] and len(payload["state"]) == 64
            assert payload["confirm_code"] == expected["code"]
            assert payload["confirm_code"].isdigit() and len(payload["confirm_code"]) == 6
            assert payload.get("name")
            assert url.endswith("/api/devices")
            return _linked()
        assert payload.get("action") == "ha_sync"
        assert api_key.startswith("fizz_")
        sent = {item["entity_id"] for item in payload["entities"]}
        assert "sensor.rack_temp" in sent
        assert "binary_sensor.closet_door" in sent
        assert "sensor.lounge_lux" not in sent
        return synced

    with (
        patch("custom_components.fizzlayer.config_flow.POLL_INTERVAL", 0),
        patch("custom_components.fizzlayer.config_flow.post_json", side_effect=fake_post),
    ):
        result = await hass.config_entries.flow.async_init(DOMAIN, context={"source": "user"})
        assert result["type"] is FlowResultType.EXTERNAL_STEP
        assert "ha.html?state=" in result["url"]
        assert "code=" not in result["url"]
        assert "fizzlayer.com" in result["url"]
        expected["code"] = result["description_placeholders"]["code"]
        assert expected["code"].isdigit() and len(expected["code"]) == 6
        assert result["description_placeholders"]["version"] == "1.1.0"
        assert result["step_id"] == "link"
        flow_id = result["flow_id"]
        await hass.async_block_till_done()
        result = await hass.config_entries.flow.async_configure(flow_id)
        assert result["type"] is FlowResultType.FORM
        assert result["step_id"] == "entities"
        result = await hass.config_entries.flow.async_configure(
            flow_id,
            {"entities": ["sensor.rack_temp", "binary_sensor.closet_door"]},
        )
    assert result["type"] is FlowResultType.CREATE_ENTRY
    assert result["data"]["api_key"].startswith("fizz_")
    assert set(result["options"]["entities"]) == {"sensor.rack_temp", "binary_sensor.closet_door"}
    assert plan_entity("sensor.rack_temp", "temperature", "°C").metric == "temperature_c"


async def test_advanced_mode_shows_the_code_instead_of_a_url_form(hass, enable_custom_integrations):
    """Advanced Mode used to ask for base_url and code and never displayed a code."""
    from custom_components.fizzlayer.config_flow import FizzlayerConfigFlow

    FizzlayerConfigFlow.show_advanced_options = property(lambda self: True)
    try:
        result = await hass.config_entries.flow.async_init(DOMAIN, context={"source": "user"})
    finally:
        del FizzlayerConfigFlow.show_advanced_options
    assert result["type"] is FlowResultType.EXTERNAL_STEP
    assert result["step_id"] == "link"
    placeholders = result["description_placeholders"]
    assert placeholders["code"].isdigit() and len(placeholders["code"]) == 6
    assert placeholders["version"] == "1.1.0"
    assert placeholders["url"].startswith("https://fizzlayer.com/ha.html?state=")
    assert "base_url" not in result
